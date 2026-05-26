<#
.SYNOPSIS
  One-shot batch wrapper: refresh state diff, then run only the steps each
  pending source still needs. Credentials prompted ONCE up front.

.DESCRIPTION
  Pipeline:
    1. (default) Re-runs 00-build-config\Compare-MigrationState.ps1 to get a
       fresh state\todo.json. Pass -SkipCompare to reuse the existing file.
    2. Caches vCenter + VCD credentials once and overrides Get-Credential
       globally so the child step scripts never re-prompt. Override is torn
       down on exit (in a finally block) so it doesn't leak into the session.
    3. For each source in todo.pending[], synthesises a temp config (clones
       config-batch.json, sets portGroup.source = $src.name) and invokes
       only the steps listed in src.needs[]:
         step1 -> 01-create-portgroup\New-DistributedPortGroup-v1.1.ps1
         step2 -> 02-import-network\Import-OrgVdcNetwork-AutoDetect.ps1
         step3 -> 03-switch-nics\Switch-TenantVmNics.ps1
       Wrapped in try/catch - a single source failing does NOT abort the
       batch.
    4. Writes per-source results to state\batch-result.json.

  Idempotent: re-run after a partial failure and only the still-pending
  sources get touched (Compare re-detects what's done).

.PARAMETER ConfigPath
  Default: .\config\config-batch.json. Must have portGroup.sources[].

.PARAMETER SkipCompare
  Use existing state\todo.json without refreshing it.

.PARAMETER CheckVms
  Pass-through to Compare-MigrationState (per-source VCD VM count query).

.PARAMETER OrgVdcUrn
  Pass-through to Compare-MigrationState (skip name-based VDC lookup).

.PARAMETER Limit
  Only process the first N pending sources. 0 = no limit.

.PARAMETER WhatIf
  Don't invoke step scripts; print intended actions.

.PARAMETER SeparateCredentials
  Default behaviour is ONE Get-Credential prompt shared by both vCenter and
  VCD (assumes the same user/password works for both - e.g. an SSO admin).
  Pass -SeparateCredentials to prompt twice, once per system.

.PARAMETER SkipNicSwitch
  Do NOT run step 3 (Switch-TenantVmNics.ps1). Build the destination
  portgroups and import them as Org VDC Networks, but leave VMs on the
  source network. Use this for staged migrations - import first, switch
  later. Run the wrapper again without -SkipNicSwitch when ready, or run
  step 3 manually per source.

.PARAMETER Interactive
  Per-source confirmation. Before running each source the script prints its
  details (name, VLAN, needs[], dest portgroup name preview) and asks:
    [Y]es do it / [N]o skip this one / [A]ll remaining without asking /
    [Q]uit batch
  Y is the default (empty input = Y). N marks the source as 'user-skipped'
  and continues; Q breaks the loop and writes batch-result.json with
  partial results.

.EXAMPLE
  pwsh ./Invoke-MigrationBatch.ps1 -WhatIf -Limit 3
  # Dry-run, only first 3 pending sources

.EXAMPLE
  pwsh ./Invoke-MigrationBatch.ps1
  # Refresh todo, run everything pending - one credential prompt only
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath,
    [switch] $SkipCompare,
    [switch] $CheckVms,
    [string] $OrgVdcUrn,
    [int]    $Limit = 0,
    [switch] $SeparateCredentials,
    [switch] $Interactive,
    [switch] $SkipNicSwitch
)

$ErrorActionPreference = 'Stop'

# --- Paths --------------------------------------------------------------
$baseDir = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $baseDir 'config\config-batch.json' }
$todoPath      = Join-Path $baseDir 'state\todo.json'
$resultPath    = Join-Path $baseDir 'state\batch-result.json'
$step1Path     = Join-Path $baseDir '01-create-portgroup\New-DistributedPortGroup-v1.3.ps1'
$step2Path     = Join-Path $baseDir '02-import-network\Import-OrgVdcNetwork-AutoDetect.ps1'
$step3Path     = Join-Path $baseDir '03-switch-nics\Switch-TenantVmNics.ps1'
$comparePath   = Join-Path $baseDir '00-build-config\Compare-MigrationState.ps1'
$pgHandoff     = Join-Path $baseDir 'state\portgroup-handoff.json'
$netHandoff    = Join-Path $baseDir 'state\network-handoff.json'

foreach ($p in @($step1Path, $step2Path, $step3Path, $comparePath)) {
    if (-not (Test-Path $p)) { throw "Required script missing: $p" }
}

# config.local.json overrides config.json (consistent with step 1 / 2 / 3)
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "Config: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# --- Prompt ONCE for credentials, then global override ------------------
Write-Host "Credentials will be cached for this batch run." -ForegroundColor Yellow
if ($SeparateCredentials) {
    $script:vcCred  = Microsoft.PowerShell.Security\Get-Credential -Message "vCenter credentials ($($cfg.vCenter.server))"
    $script:vcdCred = Microsoft.PowerShell.Security\Get-Credential -Message "VCD System administrator credentials ($($cfg.vcd.server))"
}
else {
    $shared = Microsoft.PowerShell.Security\Get-Credential -Message "Credentials for vCenter ($($cfg.vCenter.server)) AND VCD ($($cfg.vcd.server)) - one prompt, used for both. Pass -SeparateCredentials if they differ."
    $script:vcCred  = $shared
    $script:vcdCred = $shared
}

# Defining a function with this name shadows the cmdlet in any scope that
# can see this function (global: makes it visible to child scripts).
function global:Get-Credential {
    param(
        [Parameter(Position = 0)] $UserName,
        [string] $Message
    )
    # Step 2/3/Compare prompt with 'VCD System administrator credentials'.
    # Step 1/Compare prompt with 'vCenter credentials'.
    if ($Message -match 'VCD' -or $Message -match 'vcd') { return $script:vcdCred }
    return $script:vcCred
}

try {
    # --- 1. Refresh todo.json -------------------------------------------
    if (-not $SkipCompare) {
        Write-Host ""
        Write-Host "=== Refreshing todo.json ===" -ForegroundColor Cyan
        $cArgs = @{ ConfigPath = $ConfigPath; OutFile = $todoPath }
        if ($CheckVms)  { $cArgs.CheckVms  = $true }
        if ($OrgVdcUrn) { $cArgs.OrgVdcUrn = $OrgVdcUrn }
        & $comparePath @cArgs
    }
    if (-not (Test-Path $todoPath)) {
        throw "todo.json not found at $todoPath. Run without -SkipCompare to generate it."
    }

    $todo    = Get-Content $todoPath -Raw | ConvertFrom-Json
    $pending = @($todo.pending)
    if ($Limit -gt 0) { $pending = $pending | Select-Object -First $Limit }

    Write-Host ""
    Write-Host "=== BATCH START ===" -ForegroundColor Green
    Write-Host ("  Total pending in todo : {0}" -f $todo.pendingCount)
    Write-Host ("  Already done          : {0}" -f $todo.alreadyDone)
    Write-Host ("  Processing this run   : {0}{1}" -f $pending.Count, $(if ($Limit -gt 0 -and $todo.pendingCount -gt $Limit) { " (limited to $Limit)" } else { '' }))
    if ($todo.anomalies -and $todo.anomalies.Count -gt 0) {
        Write-Host ("  Anomalies in todo     : {0} - REVIEW BEFORE RUNNING" -f $todo.anomalies.Count) -ForegroundColor Magenta
    }
    Write-Host ""

    # --- 2. Main loop ---------------------------------------------------
    $results    = New-Object System.Collections.Generic.List[object]
    $autoYes    = $false
    $userAbort  = $false
    $i = 0
    foreach ($src in $pending) {
        if ($userAbort) { break }
        $i++
        $startedAt = Get-Date
        $needsStr  = ($src.needs -join ',')
        $destPg    = $src.name + $cfg.portGroup.destinationSuffix
        Write-Host ("[{0}/{1}] {2,-30} needs=[{3}]" -f $i, $pending.Count, $src.name, $needsStr) -ForegroundColor Cyan

        # Interactive per-source confirmation (-Interactive switch)
        if ($Interactive -and -not $autoYes) {
            Write-Host ("  Source PG       : {0}" -f $src.name)
            Write-Host ("  VLAN            : {0}" -f $src.vlan)
            Write-Host ("  Source vDS      : {0}" -f $cfg.vCenter.sourceVdsName)
            Write-Host ("  Destination vDS : {0}" -f $cfg.vCenter.destinationVdsName)
            Write-Host ("  Will create     : {0}" -f $destPg)
            $choice = (Read-Host "  Proceed?  [Y]es / [N]o skip / [A]ll remaining / [Q]uit  (default Y)").Trim().ToLower()
            switch -Regex ($choice) {
                '^q'    { Write-Host "  User quit batch." -ForegroundColor Yellow; $userAbort = $true; continue }
                '^a'    { Write-Host "  Auto-yes for remaining $($pending.Count - $i + 1) source(s)." -ForegroundColor Yellow; $autoYes = $true }
                '^n|^s' {
                    Write-Host "  User skipped." -ForegroundColor Yellow
                    $results.Add([ordered]@{
                        source = $src.name; needs = $src.needs; status = 'user-skipped'
                    })
                    continue
                }
                default { } # empty or 'y*' -> proceed
            }
        }

        if (-not $PSCmdlet.ShouldProcess($src.name, "Run [$needsStr]")) {
            $results.Add([ordered]@{
                source = $src.name; needs = $src.needs; status = 'whatif'
            })
            continue
        }

        # Synthesise a per-source temp config with portGroup.source overridden.
        $tmpCfg = $cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $tmpCfg.portGroup.source = $src.name
        $tmpPath = Join-Path $env:TEMP ("cfg-batch-{0}-{1}.json" -f $PID, $src.name)
        $tmpCfg | ConvertTo-Json -Depth 20 | Set-Content $tmpPath -Encoding UTF8

        # Wipe prior hand-offs so we can detect which steps succeeded.
        Remove-Item $pgHandoff  -ErrorAction SilentlyContinue
        Remove-Item $netHandoff -ErrorAction SilentlyContinue

        # Auto-escalate: step 3 needs network-handoff which only exists if
        # step 2 ran this iteration (we just wiped it). So if step 3 is in
        # needs but step 1 / 2 aren't, force them to run (they reuse the
        # already-existing portgroup / network and just re-emit handoffs).
        $effectiveNeeds = @($src.needs)
        if ('step3' -in $effectiveNeeds -and -not $SkipNicSwitch) {
            if ('step2' -notin $effectiveNeeds) { $effectiveNeeds = @($effectiveNeeds | Where-Object { $_ -ne 'step3' }) + 'step2' + 'step3' }
            if ('step1' -notin $effectiveNeeds) { $effectiveNeeds = @('step1') + $effectiveNeeds }
        }

        $stepResults = [ordered]@{}
        $status      = 'ok'
        $errMsg      = $null
        try {
            if ('step1' -in $effectiveNeeds) {
                Write-Host "  -> step1 (portgroup)..." -ForegroundColor DarkGray
                & $step1Path -ConfigPath $tmpPath
                $stepResults['step1'] = (Test-Path $pgHandoff) ? 'ok' : 'no-handoff'
                if ($stepResults['step1'] -eq 'no-handoff') {
                    Write-Warning "  step1 produced no handoff (likely source already ends with -new) - skipping step2/step3"
                    $status = 'skipped-after-step1'
                    throw [System.Exception]::new("step1 early-return")
                }
            }
            if ('step2' -in $effectiveNeeds) {
                Write-Host "  -> step2 (org vdc network)..." -ForegroundColor DarkGray
                & $step2Path -ConfigPath $tmpPath
                $stepResults['step2'] = (Test-Path $netHandoff) ? 'ok' : 'no-handoff'
                if ($stepResults['step2'] -eq 'no-handoff') {
                    Write-Warning "  step2 produced no handoff - skipping step3"
                    $status = 'skipped-after-step2'
                    throw [System.Exception]::new("step2 early-return")
                }
            }
            if ('step3' -in $effectiveNeeds) {
                if ($SkipNicSwitch) {
                    Write-Host "  -> step3 SKIPPED (-SkipNicSwitch)" -ForegroundColor DarkYellow
                    $stepResults['step3'] = 'skipped-by-flag'
                }
                else {
                    Write-Host "  -> step3 (switch NICs)..." -ForegroundColor DarkGray
                    & $step3Path -ConfigPath $tmpPath
                    $stepResults['step3'] = 'ok'   # step 3 writes migration-result, not a handoff
                }
            }
            $elapsed = ((Get-Date) - $startedAt).TotalSeconds
            Write-Host ("  [OK] {0:F1}s" -f $elapsed) -ForegroundColor Green
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($status -eq 'ok') { $status = 'failed' }
            $elapsed = ((Get-Date) - $startedAt).TotalSeconds
            Write-Warning ("  [{0}] {1:F1}s : {2}" -f $status.ToUpper(), $elapsed, $errMsg)
        }
        finally {
            Remove-Item $tmpPath -ErrorAction SilentlyContinue
        }

        $results.Add([ordered]@{
            source     = $src.name
            needs      = $src.needs
            status     = $status
            steps      = $stepResults
            durationSec = [math]::Round($elapsed, 2)
            error      = $errMsg
        })
    }

    # --- 3. Write batch-result.json --------------------------------------
    $batchOut = [ordered]@{
        runAt          = (Get-Date).ToString('o')
        config         = $ConfigPath
        todo           = $todoPath
        totalPending   = $todo.pendingCount
        processed      = $results.Count
        ok             = ($results | Where-Object { $_.status -eq 'ok' }).Count
        failed         = ($results | Where-Object { $_.status -eq 'failed' }).Count
        skipped        = ($results | Where-Object { $_.status -like 'skipped-*' }).Count
        whatif         = ($results | Where-Object { $_.status -eq 'whatif' }).Count
        results        = $results
    }
    $outDir = Split-Path $resultPath
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $batchOut | ConvertTo-Json -Depth 12 | Set-Content $resultPath -Encoding UTF8

    Write-Host ""
    Write-Host "=== BATCH DONE ===" -ForegroundColor Green
    Write-Host ("  OK      : {0}" -f $batchOut.ok)
    Write-Host ("  Failed  : {0}" -f $batchOut.failed) -ForegroundColor $(if ($batchOut.failed) { 'Red' }     else { 'Green' })
    Write-Host ("  Skipped : {0}" -f $batchOut.skipped) -ForegroundColor $(if ($batchOut.skipped) { 'Yellow' } else { 'Green' })
    Write-Host ("  WhatIf  : {0}" -f $batchOut.whatif)
    Write-Host ("  Result  : {0}" -f $resultPath)
    if ($batchOut.failed -gt 0) {
        Write-Host ""
        Write-Host "Failed sources:" -ForegroundColor Red
        $results | Where-Object { $_.status -eq 'failed' } | ForEach-Object {
            "  - {0}: {1}" -f $_.source, $_.error
        }
    }
}
finally {
    # Tear down the Get-Credential override.
    if (Test-Path Function:\global:Get-Credential) {
        Remove-Item Function:\global:Get-Credential -ErrorAction SilentlyContinue
    }
}
