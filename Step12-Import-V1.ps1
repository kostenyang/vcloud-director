<#
.SYNOPSIS
  Phase 1 - Build dest portgroups + import as Org VDC Networks. Does NOT
  touch VM NICs. Safe to run anytime - VMs stay on the source network.

.DESCRIPTION
  Thin wrapper around Invoke-MigrationBatch.ps1 with -SkipNicSwitch fixed
  on. For each source in cfg.portGroup.sources[]:
    step 1 -> clone source portgroup to dest vDS as <name>-new
    step 2 -> create Org VDC Network <name>-new in the tenant
    step 3 -> SKIPPED (no NIC change)

  When ready to cut over, run Step3-Switch.ps1 with the same -ConfigPath.

.PARAMETER ConfigPath
  Required for per-tenant configs. Defaults to config\configorg.json so
  the typical viqa.qa flow just needs -ConfigPath skipped.

.PARAMETER Limit
  Only process the first N sources (testing).

.PARAMETER WhatIf
  Dry-run.

.EXAMPLE
  pwsh ./Step12-Import.ps1
  # Defaults to config\configorg.json (produced by Build-SourcesFromOrg.ps1)

.EXAMPLE
  pwsh ./Step12-Import.ps1 -ConfigPath .\config\configorg.json -WhatIf

.EXAMPLE
  pwsh ./Step12-Import.ps1 -ConfigPath .\config\configorg.json -Limit 1
  # First source only - one tenant, one network, no NIC change
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath,
    [int]    $Limit = 0
)

$baseDir = $PSScriptRoot
$wrapper = Join-Path $baseDir 'Invoke-MigrationBatch.ps1'
if (-not (Test-Path $wrapper)) { throw "Wrapper not found: $wrapper" }
if (-not $ConfigPath) { $ConfigPath = Join-Path $baseDir 'config\configorg.json' }

$wrapperArgs = @{
    ConfigPath    = $ConfigPath
    SkipNicSwitch = $true
    SkipCompare   = $true     # phase 1 builds from scratch; no need for Compare
}
if ($Limit -gt 0) { $wrapperArgs.Limit = $Limit }
if ($WhatIfPreference) { $wrapperArgs.WhatIf = $true }

# Synthesise todo.json from the config if it doesn't exist yet, so wrapper
# has something to iterate without re-running Compare.
$todoPath = Join-Path $baseDir 'state\todo.json'
$todoDir  = Split-Path $todoPath
if (-not (Test-Path $todoDir)) { New-Item -ItemType Directory -Path $todoDir -Force | Out-Null }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.portGroup.sources) {
    throw "config has no portGroup.sources[]. Generate with Build-SourcesFromOrg.ps1 (per-tenant) or Build-SourcesFromVdsBackup.ps1 (vDS export)."
}
$pending = @($cfg.portGroup.sources | ForEach-Object {
    [ordered]@{
        name  = $_.name
        vlan  = $_.vlan
        needs = @('step1','step2','step3')   # wrapper will skip step3 via -SkipNicSwitch
    }
})
[ordered]@{
    checkedAt        = (Get-Date).ToString('o')
    config           = $ConfigPath
    totalCandidates  = $pending.Count
    alreadyDone      = 0
    pendingCount     = $pending.Count
    anomalies        = @()
    pending          = $pending
} | ConvertTo-Json -Depth 12 | Set-Content $todoPath -Encoding UTF8

Write-Host "=== Phase 1: build portgroup + import Org VDC Network ===" -ForegroundColor Cyan
Write-Host "  Config: $ConfigPath"
Write-Host "  Sources: $($pending.Count)"
Write-Host "  NIC switch: SKIPPED" -ForegroundColor Yellow
Write-Host ""

& $wrapper @wrapperArgs
