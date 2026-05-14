<#
.SYNOPSIS
  Step 2 / 2 - Import the portgroup created by script 1 as a tenant Org VDC
  Network, and reconnect the NICs of VMs in that tenant that are currently
  attached to the "source network".

.DESCRIPTION
  Flow:
    1. Log in to VCD (10.6.1 / API 40.0) as a System administrator
    2. Use the query service to find the moref of the new portgroup
    3. Use the OpenAPI to create an "imported (OPAQUE)" Org VDC Network in the
       target Org VDC. The destination network name = source network name + suffix (-new)
    4. Find every VM in the Org whose NIC is attached to the "source network"
    5. Use the legacy API to rewrite each VM's networkConnectionSection,
       reconnecting the NIC to the new network

  Run with -WhatIf first to review the affected VM list before applying.

.PARAMETER ConfigPath
  Path to config.json. Defaults to ..\config\config.json
  (config.local.json is used in preference if present).

.PARAMETER SourceNetworkName
  The tenant-side "source" Org VDC Network name. Defaults to config portGroup.source.

.EXAMPLE
  pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1 -WhatIf   # dry run
  pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1           # apply
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = "$PSScriptRoot\..\config\config.json",
    [string] $SourceNetworkName
)

$ErrorActionPreference = 'Stop'

# --- Load configuration and shared functions ---------------------------
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "Loading config file: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

. "$PSScriptRoot\..\lib\VcdRest.ps1"

$orgName  = $cfg.tenant.orgName
$vdcName  = $cfg.tenant.orgVdcName
$destPg   = $cfg.portGroup.source + $cfg.portGroup.destinationSuffix
if (-not $SourceNetworkName) { $SourceNetworkName = $cfg.portGroup.source }
$destNetworkName = $SourceNetworkName + $cfg.portGroup.destinationSuffix

Write-Host "Org                    : $orgName"
Write-Host "Org VDC                : $vdcName"
Write-Host "Source network (VCD)   : $SourceNetworkName"
Write-Host "Dest network (VCD)     : $destNetworkName"
Write-Host "Dest portgroup         : $destPg"
Write-Host ""

# --- Log in to VCD ------------------------------------------------------
$vcdCred = Get-Credential -Message "VCD System administrator credentials ($($cfg.vcd.server))"
$session = Connect-VcdApi -Server $cfg.vcd.server -Credential $vcdCred `
    -Org $cfg.vcd.org -ApiVersion $cfg.vcd.apiVersion `
    -SkipCertificateCheck:$cfg.vcd.skipCertificateCheck
Write-Host "Logged in to VCD: $($cfg.vcd.server)" -ForegroundColor Green

# --- 1. Resolve Org / Org VDC ------------------------------------------
$orgList = Invoke-VcdLegacyApi -Session $session -Uri '/api/org'
$org = $orgList.OrgList.Org | Where-Object { $_.name -eq $orgName }
if (-not $org) { throw "Org not found: $orgName" }
$orgHref = $org.href

$vdcRec = Get-VcdQuery -Session $session -Type 'orgVdc' -Filter "name==$vdcName"
if (-not $vdcRec) { throw "Org VDC not found: $vdcName" }
if ($vdcRec.Count -gt 1) { throw "Org VDC name is ambiguous: $vdcName; use a more specific config" }
$vdcUuid = ($vdcRec.href -split '/')[-1]
$vdcUrn  = "urn:vcloud:vdc:$vdcUuid"
Write-Host "Org VDC URN: $vdcUrn"

# --- 2. Find the moref of the new portgroup ----------------------------
$pgRec = Get-VcdQuery -Session $session -Type 'portgroup' -Filter "name==$destPg" |
    Where-Object { $_.portgroupType -eq 'DV_PORTGROUP' }
if (-not $pgRec) { throw "DV portgroup not found: $destPg (run script 1 first)" }
if (@($pgRec).Count -gt 1) { throw "Portgroup name is ambiguous: $destPg; cannot decide which one to import" }
$pgMoref = $pgRec.moref
Write-Host "portgroup moref: $pgMoref"

# --- 3. Create the imported Org VDC Network ----------------------------
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

# --- 4. Find VMs attached to the source network ------------------------
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

# --- 5. Reconnect the NICs ---------------------------------------------
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
