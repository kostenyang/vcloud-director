<#
.SYNOPSIS
  Phase 2 - Switch VM NICs from source networks to the -new networks built
  by Phase 1 (Step12-Import.ps1). Cut-over step.

.DESCRIPTION
  Thin wrapper around Invoke-MigrationBatch.ps1 with no -SkipNicSwitch.
  For each source in cfg.portGroup.sources[]:
    step 1 -> reuse existing portgroup (already built by Step12-Import)
    step 2 -> reuse existing Org VDC Network (already imported)
    step 3 -> SWITCH VM NICs from <name> to <name>-new

  step 1 and step 2 are re-invoked just to regenerate the per-source
  hand-off files that step 3 needs. They are idempotent reuses (do not
  rebuild anything), so each source takes ~1-2 extra seconds.

.PARAMETER ConfigPath
  Defaults to config\configorg.json.

.PARAMETER Limit
  Only process the first N sources (testing).

.PARAMETER WhatIf
  Dry-run.

.EXAMPLE
  pwsh ./Step3-Switch.ps1 -WhatIf
  # See which VMs would be switched (no NIC changes)

.EXAMPLE
  pwsh ./Step3-Switch.ps1
  # Actually switch all VMs to the -new networks

.EXAMPLE
  pwsh ./Step3-Switch.ps1 -Limit 1
  # Switch only the first source's VMs (toe in the water)
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath,
    [int]    $Limit = 0
)

$baseDir = $PSScriptRoot
$wrapper = Join-Path $baseDir 'Invoke-MigrationBatch.ps1'
if (-not (Test-Path $wrapper)) { throw "Wrapper not found: $wrapper" }
if (-not $ConfigPath) { $ConfigPath = Join-Path $baseDir 'config\configorg.json' }

$wrapperArgs = @{
    ConfigPath  = $ConfigPath
    SkipCompare = $true
}
if ($Limit -gt 0) { $wrapperArgs.Limit = $Limit }
if ($WhatIfPreference) { $wrapperArgs.WhatIf = $true }

# Synthesise a todo.json with needs = [step3] only. The wrapper's auto-
# escalation will pull step1/step2 back in (idempotent reuse) so the
# hand-offs are fresh before step 3 reads them.
$todoPath = Join-Path $baseDir 'state\todo.json'
$todoDir  = Split-Path $todoPath
if (-not (Test-Path $todoDir)) { New-Item -ItemType Directory -Path $todoDir -Force | Out-Null }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.portGroup.sources) {
    throw "config has no portGroup.sources[]. Run Step12-Import.ps1 first (and ensure the config has sources[])."
}
$pending = @($cfg.portGroup.sources | ForEach-Object {
    [ordered]@{
        name  = $_.name
        vlan  = $_.vlan
        needs = @('step3')   # wrapper auto-escalates step3 -> [step1, step2, step3]
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

Write-Host "=== Phase 2: switch VM NICs ===" -ForegroundColor Magenta
Write-Host "  Config: $ConfigPath"
Write-Host "  Sources: $($pending.Count)"
Write-Host "  NIC switch: ON - VMs will move from source -> *-new" -ForegroundColor Yellow
Write-Host ""

& $wrapper @wrapperArgs
