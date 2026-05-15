<#
.SYNOPSIS
  Step 2 / 2 - Based on the hand-off file produced by step 1, import the new
  portgroup as a tenant Org VDC Network and migrate the tenant VM NICs onto it.

.DESCRIPTION
  This script does NOT re-discover the portgroup itself - it is driven by the
  hand-off file written by step 1 (state\portgroup-handoff.json), which carries
  the portgroup name, moref, suffix and tenant info.

  Flow:
    1. Read the hand-off file from step 1; read VCD connection info from config
    2. Log in to VCD (10.6.1 / API 40.0) as a System administrator
    3. Use the OpenAPI to create an "imported (OPAQUE)" Org VDC Network in the
       target Org VDC, backed by the portgroup moref from the hand-off file.
       Destination network name = source network name + suffix (-new)
    4. Find every VM in the Org whose NIC is attached to the "source network"
    5. Use the legacy API to rewrite each VM's networkConnectionSection,
       reconnecting the NIC to the new network

  Run with -WhatIf first to review the affected VM list before applying.

.PARAMETER ConfigPath
  Path to config.json (used for VCD connection settings only).
  Defaults to ..\config\config.json (config.local.json takes precedence).

.PARAMETER HandoffPath
  Path to the JSON hand-off file produced by step 1.
  Defaults to ..\state\portgroup-handoff.json.

.PARAMETER SourceNetworkName
  The tenant-side "source" Org VDC Network name. Defaults to the
  sourcePortgroup value from the hand-off file. Override when the VCD network
  name differs from the vCenter portgroup name.

.EXAMPLE
  pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1 -WhatIf   # dry run
  pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1           # apply
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath,
    [string] $HandoffPath,
    [string] $SourceNetworkName
)

$ErrorActionPreference = 'Stop'

# --- Auto-detect repo layout (flat vs nested) ---------------------------
# - Nested (default repo layout):   <repo>\02-import-switch-nic\this.ps1 + <repo>\lib\ + <repo>\config\
# - Flat (single working folder):   <dir>\this.ps1 + <dir>\lib\ + <dir>\config\
$baseDir = if (Test-Path (Join-Path $PSScriptRoot 'lib')) { $PSScriptRoot }
           else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $ConfigPath)  { $ConfigPath  = Join-Path $baseDir 'config\config.json' }
if (-not $HandoffPath) { $HandoffPath = Join-Path $baseDir 'state\portgroup-handoff.json' }

# --- Load shared functions, config (VCD connection) and hand-off file ---
. (Join-Path $baseDir 'lib\VcdRest.ps1')

$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "Loading config file: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not (Test-Path $HandoffPath)) {
    throw "Hand-off file not found: $HandoffPath - run step 1 (01-create-portgroup) first."
}
Write-Host "Loading hand-off file: $HandoffPath" -ForegroundColor Cyan
$handoff = Get-Content $HandoffPath -Raw | ConvertFrom-Json

# --- Resolve everything from the hand-off file --------------------------
$orgName  = $handoff.tenant.orgName
$vdcName  = $handoff.tenant.orgVdcName
$destPg   = $handoff.destinationPortgroup
$pgMoref  = $handoff.destinationPortgroupMoref
if (-not $SourceNetworkName) { $SourceNetworkName = $handoff.sourcePortgroup }
$destNetworkName = $SourceNetworkName + $handoff.destinationSuffix

if ([string]::IsNullOrWhiteSpace($pgMoref)) {
    throw "Hand-off file has no destinationPortgroupMoref - re-run step 1."
}

Write-Host "Hand-off created at    : $($handoff.createdAt)"
Write-Host "Org                    : $orgName"
Write-Host "Org VDC                : $vdcName"
Write-Host "Source network (VCD)   : $SourceNetworkName"
Write-Host "Dest network (VCD)     : $destNetworkName"
Write-Host "Dest portgroup / moref : $destPg / $pgMoref"
Write-Host ""

# --- Log in to VCD ------------------------------------------------------
$vcdCred = Get-Credential -Message "VCD System administrator credentials ($($cfg.vcd.server))"
$session = Connect-VcdApi -Server $cfg.vcd.server -Credential $vcdCred `
    -Org $cfg.vcd.org -ApiVersion $cfg.vcd.apiVersion `
    -SkipCertificateCheck:$cfg.vcd.skipCertificateCheck
Write-Host "Logged in to VCD: $($cfg.vcd.server)" -ForegroundColor Green

# --- 1. Resolve Org / Org VDC ------------------------------------------
$orgList   = Invoke-VcdLegacyApi -Session $session -Uri '/api/org'
$orgMatch  = @($orgList.OrgList.Org | Where-Object { $_.name -eq $orgName })
if (-not $orgMatch) { throw "Org not found: $orgName" }
if ($orgMatch.Count -gt 1) {
    Write-Warning "Multiple orgs named '$orgName' exist:"
    $orgMatch | ForEach-Object { [pscustomobject]@{ Name = $_.name; Href = $_.href } } | Format-Table -AutoSize
    throw "Org name '$orgName' is ambiguous; use a more specific name in config."
}
$orgHref = $orgMatch[0].href

# Optional bypass: if config has tenant.orgVdcId (a VCD URN like
# 'urn:vcloud:vdc:<uuid>'), use it directly and skip the name-based lookup.
# Useful when many tenants share the same name pattern.
$cfgVdcId = $null
if ($handoff.tenant.PSObject.Properties.Name -contains 'orgVdcId') { $cfgVdcId = $handoff.tenant.orgVdcId }

if ($cfgVdcId) {
    $vdcUrn  = $cfgVdcId
    $vdcUuid = ($vdcUrn -split ':')[-1]
    Write-Host "Org VDC URN (from config override): $vdcUrn"
}
else {
    # Use adminOrgVdc (provider query type) - the user-facing 'orgVdc' query
    # does NOT expose 'org'/'orgName' as filterable fields, only adminOrgVdc does.
    $vdcRec = @(Get-VcdQuery -Session $session -Type 'adminOrgVdc' -Filter "name==$vdcName;orgName==$orgName")
    if ($vdcRec.Count -eq 0) { throw "Org VDC not found in org '$orgName': $vdcName" }
    if ($vdcRec.Count -gt 1) {
        Write-Warning "Multiple Org VDCs named '$vdcName' exist in org '$orgName':"
        $vdcRec | ForEach-Object {
            $u = ($_.href -split '/')[-1]
            [pscustomobject]@{
                Name      = $_.name
                Urn       = "urn:vcloud:vdc:$u"
                IsEnabled = $_.isEnabled
                Href      = $_.href
            }
        } | Format-Table -AutoSize
        throw "Org VDC '$vdcName' is ambiguous; pick the right URN above and set it as tenant.orgVdcId in config (then re-run step 1)."
    }
    $vdcUuid = ($vdcRec[0].href -split '/')[-1]
    $vdcUrn  = "urn:vcloud:vdc:$vdcUuid"
    Write-Host "Org VDC URN: $vdcUrn"
}

# --- 2. Create the imported Org VDC Network ----------------------------
#   The portgroup moref comes straight from step 1's hand-off file.
$existingNet = Invoke-VcdOpenApi -Session $session `
    -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$destNetworkName"
if ($existingNet.values | Where-Object { $_.orgVdc.id -eq $vdcUrn }) {
    Write-Warning "Org VDC Network '$destNetworkName' already exists in $vdcName; skipping creation."
}
elseif ($PSCmdlet.ShouldProcess($destNetworkName, "Create imported Org VDC Network in $vdcName (backing: $pgMoref)")) {
    $body = @{
        name               = $destNetworkName
        description        = "Imported from DV portgroup $destPg (created by Import-And-Switch-TenantNic.ps1)"
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
        throw "Org VDC Network '$destNetworkName' did not reach REALIZED state after creation; check VCD."
    }
    Write-Host "Created Org VDC Network: $destNetworkName (REALIZED)" -ForegroundColor Green
}

# --- 3. Find VMs attached to the source network ------------------------
Write-Host ""
Write-Host "Scanning Org '$orgName' for VMs attached to '$SourceNetworkName' ..." -ForegroundColor Cyan
$vmRecords = Get-VcdQuery -Session $session -Type 'vm' `
    -Filter "isVAppTemplate==false;org==$orgHref"

$targets = New-Object System.Collections.Generic.List[object]
foreach ($vm in $vmRecords) {
    $ncsUri = "$($vm.href)/networkConnectionSection/"
    try {
        $ncs = Invoke-VcdLegacyApi -Session $session -Uri $ncsUri
    } catch {
        Write-Warning "  Failed to read NIC config, skipping: $($vm.name) - $($_.Exception.Message)"
        continue
    }
    $hit = $ncs.NetworkConnectionSection.NetworkConnection |
        Where-Object { $_.network -eq $SourceNetworkName }
    if ($hit) {
        $targets.Add([pscustomobject]@{
            Name       = $vm.name
            Href       = $vm.href
            Status     = $vm.status
            NicIndexes = ($hit.NetworkConnectionIndex -join ',')
            Section    = $ncs
        })
    }
}

if ($targets.Count -eq 0) {
    Write-Host "No VMs are attached to '$SourceNetworkName'; done." -ForegroundColor Yellow
    return
}

Write-Host "Found $($targets.Count) VM(s) to reconnect:" -ForegroundColor Yellow
$targets | Format-Table Name, Status, NicIndexes -AutoSize

# --- 4. Reconnect the NICs ---------------------------------------------
$report = New-Object System.Collections.Generic.List[object]
foreach ($t in $targets) {
    if (-not $PSCmdlet.ShouldProcess($t.Name, "Reconnect NIC(s) [$($t.NicIndexes)] from '$SourceNetworkName' to '$destNetworkName'")) {
        $report.Add([pscustomobject]@{ VM = $t.Name; Result = 'WhatIf - skipped' })
        continue
    }
    try {
        $section = $t.Section
        foreach ($nc in $section.NetworkConnectionSection.NetworkConnection) {
            if ($nc.network -eq $SourceNetworkName) { $nc.network = $destNetworkName }
        }
        $putUri = $section.NetworkConnectionSection.href
        $task = Invoke-VcdLegacyApi -Session $session -Uri $putUri -Method Put `
            -Body ([xml]$section.OuterXml) `
            -ContentType "application/vnd.vmware.vcloud.networkConnectionSection+xml;version=$($session.ApiVersion)"
        Wait-VcdTask -Session $session -TaskHref $task.Task.href | Out-Null
        Write-Host "  OK  $($t.Name)" -ForegroundColor Green
        $report.Add([pscustomobject]@{ VM = $t.Name; Result = 'Success' })
    }
    catch {
        Write-Warning "  FAIL $($t.Name): $($_.Exception.Message)"
        $report.Add([pscustomobject]@{ VM = $t.Name; Result = "Failed: $($_.Exception.Message)" })
    }
}

Write-Host ""
Write-Host "===== Result =====" -ForegroundColor Cyan
$report | Format-Table -AutoSize

# --- 5. Write the migration result next to the hand-off file -----------
if (-not $WhatIfPreference) {
    $resultPath = Join-Path (Split-Path $HandoffPath) 'migration-result.json'
    [ordered]@{
        completedAt      = (Get-Date).ToString('o')
        sourceNetwork    = $SourceNetworkName
        destNetwork      = $destNetworkName
        org              = $orgName
        orgVdc           = $vdcName
        results          = $report
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $resultPath -Encoding UTF8
    Write-Host "Migration result written: $resultPath" -ForegroundColor Green
}
