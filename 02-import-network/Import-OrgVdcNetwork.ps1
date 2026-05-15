<#
.SYNOPSIS
  Step 2 / 3 - Import the portgroup created by step 1 as a tenant Org VDC
  Network. Writes a network hand-off file consumed by step 3.

.DESCRIPTION
  Reads:  state\portgroup-handoff.json   (from step 1)
          config\config.json              (vcd connection info)

  Writes: state\network-handoff.json     (for step 3 - includes resolved URNs)

  This script does ONLY the network import. NIC reconnection lives in step 3
  (03-switch-nics\Switch-TenantVmNics.ps1).

  How the target Org VDC is identified (in priority order):
    1. -OrgVdcUrn parameter
    2. tenant.orgVdcId set in config.json (passed through portgroup hand-off
       by step 1)
    3. Lookup by name (orgName + orgVdcName). If multiple VDCs share the same
       name, the script aborts with a candidate list of URNs - pick one and
       re-run with -OrgVdcUrn.

.PARAMETER ConfigPath
  Path to config.json. Auto-detected; only the 'vcd' section is used.

.PARAMETER PortgroupHandoff
  Path to the portgroup hand-off file from step 1.
  Default: state\portgroup-handoff.json (auto-detected layout).

.PARAMETER NetworkHandoff
  Path to write the network hand-off file (consumed by step 3).
  Default: state\network-handoff.json (auto-detected layout).

.PARAMETER OrgVdcUrn
  Optional URN override (urn:vcloud:vdc:<uuid>) to bypass name-based VDC lookup.
  Useful when many tenants share the same org/VDC name pattern.

.EXAMPLE
  pwsh ./02-import-network/Import-OrgVdcNetwork.ps1 -WhatIf
  pwsh ./02-import-network/Import-OrgVdcNetwork.ps1
  pwsh ./02-import-network/Import-OrgVdcNetwork.ps1 -OrgVdcUrn 'urn:vcloud:vdc:27d913a4-...'
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
if (-not $ConfigPath)       { $ConfigPath       = Join-Path $baseDir 'config\config.json' }
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
$sourceNetworkName = $pgho.sourcePortgroup
$destNetworkName   = $sourceNetworkName + $pgho.destinationSuffix

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

# --- 3. Create the imported Org VDC Network ----------------------------
$existingNet = Invoke-VcdOpenApi -Session $session `
    -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$destNetworkName"
$existing = $existingNet.values | Where-Object { $_.orgVdc.id -eq $vdcUrn }

if ($existing) {
    Write-Warning "Org VDC Network '$destNetworkName' already exists in $vdcName; skipping creation."
    $netUrn = $existing.id
}
elseif ($PSCmdlet.ShouldProcess($destNetworkName, "Create imported Org VDC Network in $vdcName (backing: $pgMoref)")) {
    $body = @{
        name               = $destNetworkName
        description        = "Imported from DV portgroup $destPg (created by Import-OrgVdcNetwork.ps1)"
        orgVdc             = @{ id = $vdcUrn }
        networkType        = 'OPAQUE'
        backingNetworkId   = $pgMoref
        backingNetworkType = 'DV_PORTGROUP'
    }
    $null = Invoke-VcdOpenApi -Session $session -Path '/cloudapi/1.0.0/orgVdcNetworks' -Method Post -Body $body

    # Poll until the network appears and reaches status = REALIZED
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 4
        $check = Invoke-VcdOpenApi -Session $session `
            -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$destNetworkName"
        $net = $check.values | Where-Object { $_.orgVdc.id -eq $vdcUrn }
    } while (-not ($net -and $net.status -eq 'REALIZED') -and (Get-Date) -lt $deadline)

    if (-not ($net -and $net.status -eq 'REALIZED')) {
        throw "Org VDC Network '$destNetworkName' did not reach REALIZED state; check VCD."
    }
    $netUrn = $net.id
    Write-Host "Created Org VDC Network: $destNetworkName ($netUrn)" -ForegroundColor Green
}
else {
    return   # -WhatIf: nothing created, no hand-off file
}

# --- 4. Write the network hand-off for step 3 --------------------------
$nho = [ordered]@{
    schemaVersion       = 1
    createdAt           = (Get-Date).ToString('o')
    createdBy           = '02-import-network/Import-OrgVdcNetwork.ps1'
    tenant              = [ordered]@{
        orgName    = $orgName
        orgUrn     = $orgUrn
        orgHref    = $orgHref
        orgVdcName = $vdcName
        orgVdcUrn  = $vdcUrn
    }
    sourceNetworkName   = $sourceNetworkName
    destNetworkName     = $destNetworkName
    destNetworkUrn      = $netUrn
    destPortgroup       = $destPg
    destPortgroupMoref  = $pgMoref
}

$stateDir = Split-Path $NetworkHandoff
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$nho | ConvertTo-Json -Depth 10 | Set-Content -Path $NetworkHandoff -Encoding UTF8

Write-Host ""
Write-Host "Network hand-off written: $NetworkHandoff" -ForegroundColor Green
Write-Host "Next step: pwsh ./03-switch-nics/Switch-TenantVmNics.ps1 -WhatIf" -ForegroundColor Cyan
