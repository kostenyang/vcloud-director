<#
.SYNOPSIS
  Phase 1 V1 (standalone) - Build dest portgroups + import as Org VDC
  Networks for every source in cfg.portGroup.sources[]. Does NOT touch
  VM NICs. Self-contained: does not call Invoke-MigrationBatch.ps1.

.DESCRIPTION
  Independent batch driver for the per-tenant flow. Reads configorg.json,
  prompts for credentials ONCE, and for each source:
    1. Synthesises a per-source temp config (override portGroup.source).
    2. Wipes prior hand-off files so each source has clean state.
    3. Calls step 1 (01-create-portgroup\New-DistributedPortGroup-v1.3.ps1).
    4. Calls step 2 v2 (02-import-network\Import-OrgVdcNetwork-AutoDetect.ps1).
    5. Records per-source result.

  Step 3 (NIC switch) is NOT invoked. VMs stay on source networks.

  Credential reuse: the script prompts Get-Credential once at startup,
  caches both for vCenter and VCD, and globally overrides Get-Credential
  for the duration of the run so child step scripts inherit the cached
  cred (no re-prompt per source / per step). The override is torn down
  in a finally block.

  Result file: state\step12-batch-result.json

.PARAMETER ConfigPath
  Default config\configorg.json (matches Build-SourcesFromOrg.ps1 output
  and step 2 v2 default).

.PARAMETER Limit
  Only process the first N sources (testing).

.PARAMETER WhatIf
  Dry-run; passed through to the child step scripts.

.PARAMETER SeparateCredentials
  Default ONE credential prompt shared by vCenter + VCD. Pass this to
  prompt twice if accounts differ.

.EXAMPLE
  pwsh ./Step12-Import-V1.ps1
  # Uses config\configorg.json, single credential prompt, builds all sources.

.EXAMPLE
  pwsh ./Step12-Import-V1.ps1 -Limit 1
  # First source only, full run; useful first-time smoke test.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath,
    [int]    $Limit = 0,
    [switch] $SeparateCredentials
)

$ErrorActionPreference = 'Stop'

$baseDir = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $baseDir 'config\configorg.json' }

$step1Path  = Join-Path $baseDir '01-create-portgroup\New-DistributedPortGroup-v1.3.ps1'
$step2Path  = Join-Path $baseDir '02-import-network\Import-OrgVdcNetwork-AutoDetect.ps1'
$pgHandoff  = Join-Path $baseDir 'state\portgroup-handoff.json'
$netHandoff = Join-Path $baseDir 'state\network-handoff.json'
$resultPath = Join-Path $baseDir 'state\step12-batch-result.json'

# config.local.json overrides
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "Config: $ConfigPath" -ForegroundColor Cyan

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.portGroup.sources -or @($cfg.portGroup.sources).Count -eq 0) {
    throw "config.portGroup.sources[] is empty. Run Build-SourcesFromOrg.ps1 first."
}
$sources = @($cfg.portGroup.sources)
if ($Limit -gt 0) { $sources = $sources | Select-Object -First $Limit }

# --- Single credential prompt + global override ---------------------------
Write-Host "Credentials will be cached for this batch run." -ForegroundColor Yellow
if ($SeparateCredentials) {
    $script:vcCred  = Microsoft.PowerShell.Security\Get-Credential -Message "vCenter credentials ($($cfg.vCenter.server))"
    $script:vcdCred = Microsoft.PowerShell.Security\Get-Credential -Message "VCD System administrator credentials ($($cfg.vcd.server))"
}
else {
    $shared = Microsoft.PowerShell.Security\Get-Credential -Message "Credentials for vCenter ($($cfg.vCenter.server)) AND VCD ($($cfg.vcd.server)) - one prompt, used for both."
    $script:vcCred  = $shared
    $script:vcdCred = $shared
}
function global:Get-Credential {
    param(
        [Parameter(Position = 0)] $UserName,
        [string] $Message
    )
    if ($Message -match 'VCD' -or $Message -match 'vcd') { return $script:vcdCred }
    return $script:vcCred
}

Write-Host ""
Write-Host "=== Phase 1 V1 (standalone): build portgroup + import Org VDC Network ===" -ForegroundColor Cyan
Write-Host "  Sources: $($sources.Count)"
Write-Host "  NIC switch: NOT INVOKED (phase 1 only)" -ForegroundColor Yellow
Write-Host ""

try {
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($src in $sources) {
        $i++
        $started = Get-Date
        $sourceName = $src.name
        $destName   = $sourceName + $cfg.portGroup.destinationSuffix
        Write-Host ("[{0}/{1}] {2,-30} -> {3}" -f $i, $sources.Count, $sourceName, $destName) -ForegroundColor Cyan

        # Synthesise per-source temp config
        $tmp = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $tmp.portGroup.source = $sourceName
        $tmpPath = Join-Path $env:TEMP ("cfg-step12-{0}-{1}.json" -f $PID, $sourceName)
        $tmp | ConvertTo-Json -Depth 20 | Set-Content $tmpPath -Encoding UTF8

        # Wipe stale hand-offs
        Remove-Item $pgHandoff, $netHandoff -ErrorAction SilentlyContinue

        $status  = 'ok'
        $errMsg  = $null
        $steps   = [ordered]@{}
        $elapsed = 0
        try {
            Write-Host "  -> step1 (portgroup)..." -ForegroundColor DarkGray
            if ($PSCmdlet.ShouldProcess($sourceName, "step1 - create / reuse portgroup $destName")) {
                & $step1Path -ConfigPath $tmpPath
                $steps['step1'] = (Test-Path $pgHandoff) ? 'ok' : 'no-handoff'
                if ($steps['step1'] -eq 'no-handoff') {
                    Write-Warning "  step1 produced no handoff (source likely ends with -new) - skipping step2"
                    $status = 'skipped-after-step1'
                    throw [System.Exception]::new("step1 early-return")
                }
            }
            else {
                $steps['step1'] = 'whatif'
            }

            Write-Host "  -> step2 (org vdc network)..." -ForegroundColor DarkGray
            if ($PSCmdlet.ShouldProcess($sourceName, "step2 - import / reuse Org VDC Network $destName")) {
                & $step2Path -ConfigPath $tmpPath
                $steps['step2'] = (Test-Path $netHandoff) ? 'ok' : 'no-handoff'
                if ($steps['step2'] -eq 'no-handoff') {
                    Write-Warning "  step2 produced no handoff"
                    $status = 'skipped-after-step2'
                    throw [System.Exception]::new("step2 early-return")
                }
            }
            else {
                $steps['step2'] = 'whatif'
            }

            $elapsed = ((Get-Date) - $started).TotalSeconds
            Write-Host ("  [OK] {0:F1}s" -f $elapsed) -ForegroundColor Green
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($status -eq 'ok') { $status = 'failed' }
            $elapsed = ((Get-Date) - $started).TotalSeconds
            Write-Warning ("  [{0}] {1:F1}s : {2}" -f $status.ToUpper(), $elapsed, $errMsg)
        }
        finally {
            Remove-Item $tmpPath -ErrorAction SilentlyContinue
        }

        $results.Add([ordered]@{
            source      = $sourceName
            dest        = $destName
            status      = $status
            steps       = $steps
            durationSec = [math]::Round($elapsed, 2)
            error       = $errMsg
        })
    }

    # Write summary
    $summary = [ordered]@{
        runAt           = (Get-Date).ToString('o')
        createdBy       = 'Step12-Import-V1.ps1'
        config          = $ConfigPath
        totalCandidates = $sources.Count
        processed       = $results.Count
        ok              = ($results | Where-Object { $_.status -eq 'ok' }).Count
        failed          = ($results | Where-Object { $_.status -eq 'failed' }).Count
        skipped         = ($results | Where-Object { $_.status -like 'skipped*' }).Count
        results         = $results
    }
    $outDir = Split-Path $resultPath
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $summary | ConvertTo-Json -Depth 12 | Set-Content $resultPath -Encoding UTF8

    Write-Host ""
    Write-Host "=== PHASE 1 DONE ===" -ForegroundColor Green
    Write-Host ("  OK      : {0}" -f $summary.ok)
    Write-Host ("  Failed  : {0}" -f $summary.failed) -ForegroundColor $(if ($summary.failed) { 'Red' } else { 'Green' })
    Write-Host ("  Skipped : {0}" -f $summary.skipped) -ForegroundColor $(if ($summary.skipped) { 'Yellow' } else { 'Green' })
    Write-Host ("  Result  : {0}" -f $resultPath)
    if ($summary.failed -gt 0) {
        Write-Host ""
        Write-Host "Failed sources:" -ForegroundColor Red
        $results | Where-Object { $_.status -eq 'failed' } | ForEach-Object {
            "  - {0}: {1}" -f $_.source, $_.error
        }
    }
}
finally {
    if (Test-Path Function:\global:Get-Credential) {
        Remove-Item Function:\global:Get-Credential -ErrorAction SilentlyContinue
    }
}
