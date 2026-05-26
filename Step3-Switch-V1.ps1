<#
.SYNOPSIS
  Phase 2 V1 (standalone) - Switch VM NICs from each source network to
  its -new counterpart. Self-contained: does not call Invoke-MigrationBatch.ps1.

.DESCRIPTION
  Independent batch driver for the per-tenant cut-over. Reads configorg.json,
  prompts for credentials ONCE, and for each source:
    1. Synthesises a per-source temp config (override portGroup.source).
    2. Wipes prior network-handoff so step 3 will read this source's.
    3. Calls step 2 v2 (Import-OrgVdcNetwork-AutoDetect.ps1) - it sees the
       Org VDC Network already exists, reuses it, and writes a fresh
       network-handoff for step 3.
    4. Calls step 3 (Switch-TenantVmNics.ps1) which actually moves the
       VM NICs from the source network to <source>-new.
    5. Records per-source result.

  Step 1 is NOT invoked - this script assumes Step12-Import-V1.ps1 already
  built the portgroups.

  Credential reuse: prompts Get-Credential once, overrides globally so
  child step scripts use the cache, tears down in finally.

  Result file: state\step3-batch-result.json

.PARAMETER ConfigPath
  Default config\configorg.json.

.PARAMETER Limit
  Only process the first N sources.

.PARAMETER WhatIf
  Dry-run; passed through to step 3.

.PARAMETER SeparateCredentials
  Default ONE credential prompt shared by vCenter + VCD. Pass to prompt twice.

.EXAMPLE
  pwsh ./Step3-Switch-V1.ps1 -WhatIf
  # See which VMs would move (no NIC changes)

.EXAMPLE
  pwsh ./Step3-Switch-V1.ps1 -Limit 1
  # Cut over only the first source's VMs (toe in the water)

.EXAMPLE
  pwsh ./Step3-Switch-V1.ps1
  # Cut over every source's VMs to *-new
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath,
    [int]    $Limit = 0,
    [switch] $SeparateCredentials
)

$ErrorActionPreference = 'Stop'

$baseDir = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $baseDir 'config\configorg.json' }

$step2Path  = Join-Path $baseDir '02-import-network\Import-OrgVdcNetwork-AutoDetect.ps1'
$step3Path  = Join-Path $baseDir '03-switch-nics\Switch-TenantVmNics.ps1'
$pgHandoff  = Join-Path $baseDir 'state\portgroup-handoff.json'
$netHandoff = Join-Path $baseDir 'state\network-handoff.json'
$resultPath = Join-Path $baseDir 'state\step3-batch-result.json'

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
Write-Host "=== Phase 2 V1 (standalone): switch VM NICs to *-new ===" -ForegroundColor Magenta
Write-Host "  Sources: $($sources.Count)"
Write-Host "  NIC switch: ON - VMs will move from source -> *-new" -ForegroundColor Yellow
Write-Host ""

try {
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($src in $sources) {
        $i++
        $started    = Get-Date
        $sourceName = $src.name
        $destName   = $sourceName + $cfg.portGroup.destinationSuffix
        Write-Host ("[{0}/{1}] {2,-30} -> {3}" -f $i, $sources.Count, $sourceName, $destName) -ForegroundColor Cyan

        # Synthesise per-source temp config
        $tmp = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $tmp.portGroup.source = $sourceName
        $tmpPath = Join-Path $env:TEMP ("cfg-step3-{0}-{1}.json" -f $PID, $sourceName)
        $tmp | ConvertTo-Json -Depth 20 | Set-Content $tmpPath -Encoding UTF8

        # Wipe stale network-handoff so step 2 reuse writes a fresh one for this source.
        # Leave portgroup-handoff alone (step 2 reads it but if step 1 didn't run,
        # step 2 v2 also handles via VCD lookup of source network).
        Remove-Item $netHandoff -ErrorAction SilentlyContinue

        $status  = 'ok'
        $errMsg  = $null
        $steps   = [ordered]@{}
        $elapsed = 0
        try {
            # Re-invoke step 2 v2 just to regenerate network-handoff for THIS source.
            # It detects existing dest network and reuses (no creation).
            Write-Host "  -> step2 reuse (refresh handoff)..." -ForegroundColor DarkGray
            & $step2Path -ConfigPath $tmpPath
            $steps['step2'] = (Test-Path $netHandoff) ? 'ok' : 'no-handoff'
            if ($steps['step2'] -eq 'no-handoff') {
                throw "step2 did not produce network-handoff - was Phase 1 done for $sourceName?"
            }

            Write-Host "  -> step3 (switch NICs)..." -ForegroundColor DarkGray
            if ($PSCmdlet.ShouldProcess($sourceName, "step3 - switch VM NICs to $destName")) {
                & $step3Path -ConfigPath $tmpPath
                $steps['step3'] = 'ok'
            }
            else {
                $steps['step3'] = 'whatif'
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
        createdBy       = 'Step3-Switch-V1.ps1'
        config          = $ConfigPath
        totalCandidates = $sources.Count
        processed       = $results.Count
        ok              = ($results | Where-Object { $_.status -eq 'ok' }).Count
        failed          = ($results | Where-Object { $_.status -eq 'failed' }).Count
        results         = $results
    }
    $outDir = Split-Path $resultPath
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $summary | ConvertTo-Json -Depth 12 | Set-Content $resultPath -Encoding UTF8

    Write-Host ""
    Write-Host "=== PHASE 2 DONE ===" -ForegroundColor Green
    Write-Host ("  OK     : {0}" -f $summary.ok)
    Write-Host ("  Failed : {0}" -f $summary.failed) -ForegroundColor $(if ($summary.failed) { 'Red' } else { 'Green' })
    Write-Host ("  Result : {0}" -f $resultPath)
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
