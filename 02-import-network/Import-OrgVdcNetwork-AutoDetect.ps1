<#
.SYNOPSIS
  Step 2 / 3 (v2 - auto-detect by source type) - Import the portgroup created
  by step 1 as a tenant Org VDC Network, mirroring the SOURCE network's type.

.DESCRIPTION
  Same 3-step flow as v1; only step 2's behaviour differs.

  Branch on source Org VDC Network type:
    OPAQUE  -> create destination as OPAQUE (same as v1) using the DV portgroup
               moref from step 1's hand-off.
    DIRECT  -> create a Provider external network backed by the DV portgroup
               from step 1, mirroring the SOURCE external network's subnets and
               vCenter (networkProvider). Then create a DIRECT Org VDC Network
               referencing the new external network via parentNetworkId.
    other   -> throw (NAT_ROUTED / ISOLATED need NSX edge work; out of scope).

  The destination external network for DIRECT case is named
    <source external network name> + portgroup-handoff.destinationSuffix
  (so it mirrors the portgroup naming convention from step 1).

  Same network-handoff.json schema as v1; two extra fields:
    sourceNetworkType, destNetworkType, destExternalNetworkUrn
  (step 3 only reads pre-existing fields, so v2 hand-offs are backwards
  compatible).

.PARAMETER ConfigPath
  Path to config.json. Auto-detected; only the 'vcd' section is used.

.PARAMETER PortgroupHandoff
  Path to the portgroup hand-off file from step 1.
  Default: state\portgroup-handoff.json.

.PARAMETER NetworkHandoff
  Path to write the network hand-off file (consumed by step 3).
  Default: state\network-handoff.json.

.PARAMETER OrgVdcUrn
  Optional URN override (urn:vcloud:vdc:<uuid>) to bypass name-based VDC lookup.

.EXAMPLE
  pwsh ./02-import-network/Import-OrgVdcNetwork-AutoDetect.ps1 -WhatIf
  pwsh ./02-import-network/Import-OrgVdcNetwork-AutoDetect.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath,
    [string] $PortgroupHandoff,
    [string] $NetworkHandoff,
    [string] $OrgVdcUrn
)

$ErrorActionPreference = 'Stop'

# --- Auto-detect repo layout (flat vs nested) ---------------------------
$baseDir = if (Test-Path (Join-Path $PSScriptRoot 'lib')) { $PSScriptRoot }
           else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $ConfigPath)       { $ConfigPath       = Join-Path $baseDir 'config\configorg.json' }
if (-not $PortgroupHandoff) { $PortgroupHandoff = Join-Path $baseDir 'state\portgroup-handoff.json' }
if (-not $NetworkHandoff)   { $NetworkHandoff   = Join-Path $baseDir 'state\network-handoff.json' }

. (Join-Path $baseDir 'lib\VcdRest.ps1')

# --- Load config and the step-1 hand-off --------------------------------
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "Loading config file: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not (Test-Path $PortgroupHandoff)) {
    throw "Portgroup hand-off not found: $PortgroupHandoff - run step 1 (01-create-portgroup) first."
}
Write-Host "Loading portgroup hand-off: $PortgroupHandoff" -ForegroundColor Cyan
$pgho = Get-Content $PortgroupHandoff -Raw | ConvertFrom-Json

# Allow tenant.orgVdcId from hand-off (set via config) to override name lookup
if (-not $OrgVdcUrn) {
    if ($pgho.tenant.PSObject.Properties.Name -contains 'orgVdcId' -and $pgho.tenant.orgVdcId) {
        $OrgVdcUrn = $pgho.tenant.orgVdcId
    }
}

$orgName           = $pgho.tenant.orgName
$vdcName           = $pgho.tenant.orgVdcName
$destPg            = $pgho.destinationPortgroup
$pgMoref           = $pgho.destinationPortgroupMoref
$destSuffix        = $pgho.destinationSuffix
$sourceNetworkName = $pgho.sourcePortgroup
$destNetworkName   = $sourceNetworkName + $destSuffix

if ([string]::IsNullOrWhiteSpace($pgMoref)) {
    throw "Portgroup hand-off has no destinationPortgroupMoref - re-run step 1."
}

Write-Host "Hand-off created at    : $($pgho.createdAt)"
Write-Host "Org                    : $orgName"
Write-Host "Org VDC                : $vdcName$(if ($OrgVdcUrn) { ' (URN explicit)' })"
Write-Host "Source network         : $sourceNetworkName"
Write-Host "Dest network           : $destNetworkName"
Write-Host "Dest portgroup / moref : $destPg / $pgMoref"
Write-Host ""

# --- Log in to VCD ------------------------------------------------------
$vcdCred = Get-Credential -Message "VCD System administrator credentials ($($cfg.vcd.server))"
$session = Connect-VcdApi -Server $cfg.vcd.server -Credential $vcdCred `
    -Org $cfg.vcd.org -ApiVersion $cfg.vcd.apiVersion `
    -SkipCertificateCheck:$cfg.vcd.skipCertificateCheck
Write-Host "Logged in to VCD: $($cfg.vcd.server)" -ForegroundColor Green

# --- 1. Resolve Org -----------------------------------------------------
$orgList  = Invoke-VcdLegacyApi -Session $session -Uri '/api/org'
$orgMatch = @($orgList.OrgList.Org | Where-Object { $_.name -eq $orgName })
if (-not $orgMatch) { throw "Org not found: $orgName" }
if ($orgMatch.Count -gt 1) {
    Write-Warning "Multiple orgs named '$orgName' exist:"
    $orgMatch | ForEach-Object { [pscustomobject]@{ Name = $_.name; Href = $_.href } } | Format-Table -AutoSize
    throw "Org name '$orgName' is ambiguous; use a more specific name."
}
$org     = $orgMatch[0]
$orgHref = $org.href
$orgUuid = ($orgHref -split '/')[-1]
$orgUrn  = "urn:vcloud:org:$orgUuid"

# --- 2. Resolve Org VDC -------------------------------------------------
if ($OrgVdcUrn) {
    $vdcUrn  = $OrgVdcUrn
    $vdcUuid = ($vdcUrn -split ':')[-1]
    Write-Host "Org VDC URN (explicit): $vdcUrn"
}
else {
    $vdcRec = @(Get-VcdQuery -Session $session -Type 'adminOrgVdc' -Filter "name==$vdcName;orgName==$orgName")
    $vdcRec = @($vdcRec | Sort-Object -Property href -Unique)
    if ($vdcRec.Count -eq 0) { throw "Org VDC not found in '$orgName': $vdcName" }
    if ($vdcRec.Count -gt 1) {
        $candidates = $vdcRec | ForEach-Object {
            $u = ($_.href -split '/')[-1]
            [pscustomobject]@{
                Name      = $_.name
                Urn       = "urn:vcloud:vdc:$u"
                IsEnabled = $_.isEnabled
                Href      = $_.href
            }
        }
        $tableText = ($candidates | Format-Table -AutoSize | Out-String).Trim()
        throw @"
Org VDC '$vdcName' is ambiguous in '$orgName'. Found $($candidates.Count) match(es):

$tableText

Pick the right URN above and either:
  (a) re-run with -OrgVdcUrn 'urn:vcloud:vdc:...', or
  (b) set tenant.orgVdcId in config\config.json and re-run step 1 first.
"@
    }
    $vdcUuid = ($vdcRec[0].href -split '/')[-1]
    $vdcUrn  = "urn:vcloud:vdc:$vdcUuid"
    Write-Host "Org VDC URN: $vdcUrn"
}

# --- 3. Helper: find a network by name within the target VDC -----------
# Response sometimes carries 'ownerRef', sometimes legacy 'orgVdc' - check both.
function Find-VdcNetwork {
    param($Resp, $VdcUrn)
    $Resp.values | Where-Object {
        ($_.ownerRef -and $_.ownerRef.id -eq $VdcUrn) -or
        ($_.orgVdc   -and $_.orgVdc.id   -eq $VdcUrn)
    } | Select-Object -First 1
}

# Wait for an Org VDC Network (by name, scoped to $vdcUrn) to reach REALIZED.
function Wait-OrgVdcNetworkRealized {
    param([string] $Name, [int] $TimeoutMin = 5)
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    do {
        Start-Sleep -Seconds 4
        $check = Invoke-VcdOpenApi -Session $session `
            -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$Name"
        $net = Find-VdcNetwork -Resp $check -VdcUrn $vdcUrn
    } while (-not ($net -and $net.status -eq 'REALIZED') -and (Get-Date) -lt $deadline)
    if (-not ($net -and $net.status -eq 'REALIZED')) {
        throw "Org VDC Network '$Name' did not reach REALIZED state; check VCD."
    }
    $net
}

# --- 4. Look up source Org VDC Network and detect type -----------------
Write-Host "Looking up source Org VDC Network '$sourceNetworkName' in '$vdcName'..." -ForegroundColor Cyan
$srcResp = Invoke-VcdOpenApi -Session $session -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$sourceNetworkName"
$srcNet  = Find-VdcNetwork -Resp $srcResp -VdcUrn $vdcUrn
if (-not $srcNet) {
    throw "Source Org VDC Network '$sourceNetworkName' not found in '$vdcName'."
}
$srcType = $srcNet.networkType
$srcSubnetSummary = (@($srcNet.subnets.values) | ForEach-Object { "$($_.gateway)/$($_.prefixLength)" }) -join ', '
Write-Host "  Source network type : $srcType" -ForegroundColor Yellow
Write-Host "  Source subnets      : $srcSubnetSummary"

if ($srcType -notin @('OPAQUE', 'DIRECT')) {
    throw "v2 only supports source networkType OPAQUE or DIRECT, got '$srcType'."
}

# --- 5. Skip if destination Org VDC Network already exists -------------
$existingResp = Invoke-VcdOpenApi -Session $session `
    -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$destNetworkName"
$existing = Find-VdcNetwork -Resp $existingResp -VdcUrn $vdcUrn

# Initialise so the hand-off schema is uniform across all branches.
$netUrn                 = $null
$destNetworkType        = $null
$destExternalNetworkUrn = $null

if ($existing) {
    Write-Warning "Org VDC Network '$destNetworkName' already exists in $vdcName; skipping creation."
    $netUrn          = $existing.id
    $destNetworkType = $existing.networkType
    if ($destNetworkType -eq 'DIRECT' -and $existing.parentNetworkId) {
        $destExternalNetworkUrn = $existing.parentNetworkId.id
    }
}
elseif ($srcType -eq 'OPAQUE') {
    # === OPAQUE path (same body shape as v1) ============================
    if ($PSCmdlet.ShouldProcess($destNetworkName, "Create OPAQUE Org VDC Network in $vdcName (backing: $pgMoref)")) {
        $body = @{
            name               = $destNetworkName
            description        = "Imported from DV portgroup $destPg (created by Import-OrgVdcNetwork-AutoDetect.ps1)"
            ownerRef           = @{ id = $vdcUrn }
            networkType        = 'OPAQUE'
            backingNetworkId   = $pgMoref
            backingNetworkType = 'DV_PORTGROUP'
            subnets            = $srcNet.subnets
        }
        $null = Invoke-VcdOpenApi -Session $session -Path '/cloudapi/1.0.0/orgVdcNetworks' -Method Post -Body $body
        $net = Wait-OrgVdcNetworkRealized -Name $destNetworkName
        $netUrn          = $net.id
        $destNetworkType = 'OPAQUE'
        Write-Host "Created OPAQUE Org VDC Network: $destNetworkName ($netUrn)" -ForegroundColor Green
    }
    else { return }
}
elseif ($srcType -eq 'DIRECT') {
    # === DIRECT path ====================================================
    # 5a. Read the source external network to mirror subnets and pick up
    #     the vCenter (networkProvider) URN. The DV portgroup created by
    #     step 1 must live on the same vCenter for the backing to attach.
    $srcParentExtId = $srcNet.parentNetworkId.id
    if (-not $srcParentExtId) {
        throw "Source DIRECT network '$sourceNetworkName' has no parentNetworkId; cannot continue."
    }
    Write-Host "Source DIRECT parent external network URN: $srcParentExtId" -ForegroundColor Cyan
    $srcExt = Invoke-VcdOpenApi -Session $session -Path "/cloudapi/1.0.0/externalNetworks/$srcParentExtId"

    $srcBacking = @($srcExt.networkBackings.values) | Select-Object -First 1
    if (-not $srcBacking) { throw "Source external network '$($srcExt.name)' has no networkBackings entry." }
    $vimServerUrn = $srcBacking.networkProvider.id
    Write-Host "  vCenter (networkProvider) URN: $vimServerUrn"

    # 5b. Destination external network: mirror name with the portgroup suffix.
    $destExtName = $srcExt.name + $destSuffix
    Write-Host "Destination external network name: $destExtName" -ForegroundColor Cyan

    $extQuery = Invoke-VcdOpenApi -Session $session -Path "/cloudapi/1.0.0/externalNetworks?filter=name==$destExtName"
    $destExt  = @($extQuery.values) | Select-Object -First 1

    if ($destExt) {
        Write-Warning "Provider external network '$destExtName' already exists; reusing it."
    }
    elseif ($PSCmdlet.ShouldProcess($destExtName, "Create Provider external network (backing: $pgMoref on $vimServerUrn)")) {
        $extBody = @{
            name        = $destExtName
            description = "Created by Import-OrgVdcNetwork-AutoDetect.ps1 from '$($srcExt.name)'"
            subnets     = $srcExt.subnets
            networkBackings = @{
                values = @(
                    @{
                        backingId        = $pgMoref
                        backingTypeValue = 'DV_PORTGROUP'
                        networkProvider  = @{ id = $vimServerUrn }
                    }
                )
            }
        }
        $null = Invoke-VcdOpenApi -Session $session -Path '/cloudapi/1.0.0/externalNetworks' -Method Post -Body $extBody

        # Poll until the new external network is queryable by name.
        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 4
            $extCheck = Invoke-VcdOpenApi -Session $session -Path "/cloudapi/1.0.0/externalNetworks?filter=name==$destExtName"
            $destExt  = @($extCheck.values) | Select-Object -First 1
        } while (-not $destExt -and (Get-Date) -lt $deadline)
        if (-not $destExt) { throw "External network '$destExtName' did not appear in time; check VCD provider context." }
        Write-Host "Created external network: $destExtName ($($destExt.id))" -ForegroundColor Green
    }
    else { return }
    $destExternalNetworkUrn = $destExt.id

    # 5c. DIRECT Org VDC Network: parentNetworkId points at the new external
    #     network. Subnets are inherited from the parent, so we omit them.
    if ($PSCmdlet.ShouldProcess($destNetworkName, "Create DIRECT Org VDC Network in $vdcName (parent: $($destExt.id))")) {
        $body = @{
            name            = $destNetworkName
            description     = "Direct from external network '$destExtName' (created by Import-OrgVdcNetwork-AutoDetect.ps1)"
            ownerRef        = @{ id = $vdcUrn }
            networkType     = 'DIRECT'
            parentNetworkId = @{ id = $destExt.id }
        }
        $null = Invoke-VcdOpenApi -Session $session -Path '/cloudapi/1.0.0/orgVdcNetworks' -Method Post -Body $body
        $net = Wait-OrgVdcNetworkRealized -Name $destNetworkName
        $netUrn          = $net.id
        $destNetworkType = 'DIRECT'
        Write-Host "Created DIRECT Org VDC Network: $destNetworkName ($netUrn)" -ForegroundColor Green
    }
    else { return }
}

# --- 6. Write the network hand-off for step 3 --------------------------
$nho = [ordered]@{
    schemaVersion          = 1
    createdAt              = (Get-Date).ToString('o')
    createdBy              = '02-import-network/Import-OrgVdcNetwork-AutoDetect.ps1'
    tenant                 = [ordered]@{
        orgName    = $orgName
        orgUrn     = $orgUrn
        orgHref    = $orgHref
        orgVdcName = $vdcName
        orgVdcUrn  = $vdcUrn
    }
    sourceNetworkName      = $sourceNetworkName
    sourceNetworkType      = $srcType
    destNetworkName        = $destNetworkName
    destNetworkUrn         = $netUrn
    destNetworkType        = $destNetworkType
    destPortgroup          = $destPg
    destPortgroupMoref     = $pgMoref
    destExternalNetworkUrn = $destExternalNetworkUrn
}

$stateDir = Split-Path $NetworkHandoff
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$nho | ConvertTo-Json -Depth 10 | Set-Content -Path $NetworkHandoff -Encoding UTF8

Write-Host ""
Write-Host "Network hand-off written: $NetworkHandoff" -ForegroundColor Green
Write-Host "Next step: pwsh ./03-switch-nics/Switch-TenantVmNics.ps1 -WhatIf" -ForegroundColor Cyan
