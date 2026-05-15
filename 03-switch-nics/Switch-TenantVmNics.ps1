<#
.SYNOPSIS
  Step 3 / 3 - Reconnect tenant VM NICs from the source Org VDC Network to
  the destination network created by step 2.

.DESCRIPTION
  Reads:  state\network-handoff.json    (from step 2 - all URNs pre-resolved)
          config\config.json             (vcd connection info)

  Writes: state\migration-result.json   (per-VM result)

  This script does ONLY the NIC reconnection. The Org VDC Network must already
  have been imported by step 2.

  Because step 2 wrote the resolved Org URN, Org VDC URN, source/destination
  network names and the destination network URN into the hand-off, step 3
  performs NO name-based lookups - duplicate org/VDC names in the environment
  are not a problem here.

  The actual NIC reconnection preserves each NIC's IP, MAC and IP allocation
  mode; only the network name on the connection is changed.

.PARAMETER ConfigPath
  Path to config.json. Auto-detected; only the 'vcd' section is used.

.PARAMETER NetworkHandoff
  Path to the network hand-off file produced by step 2.
  Default: state\network-handoff.json (auto-detected layout).

.PARAMETER SourceNetworkName
  Override the source Org VDC Network name. Defaults to the value written by
  step 2. Use this when you want to swap in the opposite direction (rollback).

.EXAMPLE
  pwsh ./03-switch-nics/Switch-TenantVmNics.ps1 -WhatIf   # dry run
  pwsh ./03-switch-nics/Switch-TenantVmNics.ps1           # apply

.EXAMPLE
  # Rollback: reconnect VMs from the new network back to the original
  pwsh ./03-switch-nics/Switch-TenantVmNics.ps1 -SourceNetworkName 'PG-Tenant-VLAN100-new'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath,
    [string] $NetworkHandoff,
    [string] $SourceNetworkName
)

$ErrorActionPreference = 'Stop'

# --- Auto-detect repo layout (flat vs nested) ---------------------------
$baseDir = if (Test-Path (Join-Path $PSScriptRoot 'lib')) { $PSScriptRoot }
           else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $ConfigPath)     { $ConfigPath     = Join-Path $baseDir 'config\config.json' }
if (-not $NetworkHandoff) { $NetworkHandoff = Join-Path $baseDir 'state\network-handoff.json' }

. (Join-Path $baseDir 'lib\VcdRest.ps1')

# --- Load config and the step-2 hand-off --------------------------------
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "Loading config file: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not (Test-Path $NetworkHandoff)) {
    throw "Network hand-off not found: $NetworkHandoff - run step 2 (02-import-network) first."
}
Write-Host "Loading network hand-off: $NetworkHandoff" -ForegroundColor Cyan
$nho = Get-Content $NetworkHandoff -Raw | ConvertFrom-Json

if (-not $SourceNetworkName) { $SourceNetworkName = $nho.sourceNetworkName }
$destNetworkName = $nho.destNetworkName
$orgName         = $nho.tenant.orgName
$orgHref         = $nho.tenant.orgHref

Write-Host "Hand-off created at    : $($nho.createdAt)"
Write-Host "Org                    : $orgName"
Write-Host "Org VDC                : $($nho.tenant.orgVdcName) ($($nho.tenant.orgVdcUrn))"
Write-Host "Source network         : $SourceNetworkName"
Write-Host "Dest network           : $destNetworkName ($($nho.destNetworkUrn))"
Write-Host ""

# --- Log in to VCD ------------------------------------------------------
$vcdCred = Get-Credential -Message "VCD System administrator credentials ($($cfg.vcd.server))"
$session = Connect-VcdApi -Server $cfg.vcd.server -Credential $vcdCred `
    -Org $cfg.vcd.org -ApiVersion $cfg.vcd.apiVersion `
    -SkipCertificateCheck:$cfg.vcd.skipCertificateCheck
Write-Host "Logged in to VCD: $($cfg.vcd.server)" -ForegroundColor Green

# --- 1. Find VMs attached to the source network ------------------------
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

# --- 2. Reconnect the NICs ---------------------------------------------
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

# --- 3. Write the migration result -------------------------------------
if (-not $WhatIfPreference) {
    $resultPath = Join-Path (Split-Path $NetworkHandoff) 'migration-result.json'
    [ordered]@{
        completedAt   = (Get-Date).ToString('o')
        sourceNetwork = $SourceNetworkName
        destNetwork   = $destNetworkName
        org           = $orgName
        orgVdc        = $nho.tenant.orgVdcName
        orgVdcUrn     = $nho.tenant.orgVdcUrn
        results       = $report
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $resultPath -Encoding UTF8
    Write-Host "Migration result written: $resultPath" -ForegroundColor Green
}
