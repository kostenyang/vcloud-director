<#
.SYNOPSIS
  Step 1 / 2 - Target vCenter: create the "destination" distributed portgroup
  on a vDS, then write a JSON hand-off file for step 2.

.DESCRIPTION
  This script works entirely against vCenter (VC):
    1. Clone the settings (VLAN, binding, teaming, etc.) from the source
       portgroup and create a new portgroup named "<source name> + suffix (-new)".
    2. Write a JSON hand-off file to state\ that records what was created
       (vCenter, vDS, portgroup name, moref, VLAN, tenant info).

  Step 2 (02-import-switch-nic) consumes that hand-off file to perform the
  tenant network import and NIC migration - it does NOT re-discover this
  information itself.

  The source vDS and destination vDS are separate variables: the destination
  portgroup can be created on a *different* vDS (source on A, destination on B).
  When both are the same, it simply clones within the same vDS.

.PARAMETER ConfigPath
  Path to config.json. Defaults to ..\config\config.json
  (config.local.json is used in preference if present).

.PARAMETER HandoffPath
  Path to the JSON hand-off file written for step 2.
  Defaults to ..\state\portgroup-handoff.json.

.PARAMETER SourceVdsName
  vDS that hosts the source portgroup. Defaults to config vCenter.sourceVdsName.

.PARAMETER DestinationVdsName
  vDS on which the destination portgroup is created. Defaults to
  config vCenter.destinationVdsName. Use this parameter (or config) to target
  a different vDS.

.PARAMETER Rollback
  Rollback mechanism: delete the destination portgroup and the hand-off file.
  Aborts if any VM is still connected to it - run script 2 first to move the
  NICs back.

.PARAMETER Interactive
  Batch mode WITH per-source prompts. Reads `config.portGroup.sources[]`
  (the array produced by Build-SourcesFromVdsBackup.ps1) and iterates EVERY
  entry, prompting per source: [Y]es build / [N]o skip / [A]ll remaining
  without asking / [Q]uit. Default is Y (empty input = Y).

  In batch mode the standard single-source hand-off is NOT written; instead
  a summary state\step1-batch-result.json is written. Step 2 / 3 should be
  driven by the batch wrapper (Invoke-MigrationBatch.ps1).

.PARAMETER All
  Batch mode WITHOUT prompts. Equivalent to -Interactive + pressing 'A' at
  the first prompt - reads cfg.portGroup.sources[] and processes every
  entry in one shot, no questions asked. Same summary file is written.

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.3.ps1
  # Create the destination portgroup and write the hand-off file (single source)

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.3.ps1 -DestinationVdsName "DSwitch-DR"
  # Create the destination portgroup on a different vDS "DSwitch-DR"

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.3.ps1 -Rollback
  # Rollback: delete the destination portgroup and the hand-off file

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.3.ps1 -Interactive
  # Batch mode: iterate cfg.portGroup.sources[] and prompt per source

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.3.ps1 -All
  # Batch mode: process EVERY source in cfg.portGroup.sources[], no prompts

.NOTES
  Version: 1.3
  Changelog:
    1.3 - same as 1.2; version label bump only.
    1.2 - -Interactive switch: iterate cfg.portGroup.sources[] with
          per-source prompt ([Y]/[N]/[A]/[Q]).
          -All switch: same as Interactive + auto-yes (no prompts).
          Both write state\step1-batch-result.json summary (no single-
          source hand-off in batch mode - use Invoke-MigrationBatch for
          end-to-end step 1/2/3 batch).
    1.1 - cross-vDS uplink remap by index (preserves teaming, no
          disconnects). Skip if source name already ends with -new.
    1.0 - initial version (same-vDS clone via -ReferencePortgroup)
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath,
    [string] $HandoffPath,
    [string] $SourceVdsName,
    [string] $DestinationVdsName,
    [switch] $Rollback,
    [switch] $Interactive,
    [switch] $All
)

$ErrorActionPreference = 'Stop'

# --- Auto-detect repo layout (flat vs nested) ---------------------------
# - Nested (default repo layout):   <repo>\01-create-portgroup\this.ps1 + <repo>\config\
# - Flat (single working folder):   <dir>\this.ps1 + <dir>\config\
$baseDir = if (Test-Path (Join-Path $PSScriptRoot 'config')) { $PSScriptRoot }
           else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $ConfigPath)  { $ConfigPath  = Join-Path $baseDir 'config\config.json' }
if (-not $HandoffPath) { $HandoffPath = Join-Path $baseDir 'state\portgroup-handoff.json' }

# --- Load configuration -------------------------------------------------
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "Loading config file: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# --- Variables: source/destination vDS and portgroup names --------------
if (-not $SourceVdsName)      { $SourceVdsName      = $cfg.vCenter.sourceVdsName }
if (-not $DestinationVdsName) { $DestinationVdsName = $cfg.vCenter.destinationVdsName }
if (-not $SourceVdsName)      { throw "Source vDS not specified (-SourceVdsName or config.vCenter.sourceVdsName)" }
if (-not $DestinationVdsName) { throw "Destination vDS not specified (-DestinationVdsName or config.vCenter.destinationVdsName)" }

$suffix = $cfg.portGroup.destinationSuffix

# In single mode we read portGroup.source. Interactive mode iterates
# portGroup.sources[] and the top-level $sourcePg is unused.
$sourcePg = $cfg.portGroup.source
$destPg   = if ($sourcePg) { $sourcePg + $suffix } else { '' }

Write-Host "Source vDS                  : $SourceVdsName"
Write-Host "Destination vDS             : $DestinationVdsName"
$batchMode = $Interactive -or $All
if ($batchMode) {
    $modeLabel = if ($All) { 'ALL BATCH (auto-yes)' } else { 'INTERACTIVE BATCH (prompt per source)' }
    Write-Host "Mode                        : $modeLabel (cfg.portGroup.sources[])" -ForegroundColor Yellow
}
elseif ($Rollback) {
    Write-Host "Mode                        : ROLLBACK (delete destination portgroup)" -ForegroundColor Magenta
    Write-Host "Source/Dest portgroup       : $sourcePg / $destPg"
}
else {
    Write-Host "Mode                        : CREATE destination portgroup"
    Write-Host "Source/Dest portgroup       : $sourcePg / $destPg"
    Write-Host "Hand-off file               : $HandoffPath"
}

# --- PowerCLI ------------------------------------------------------------
Import-Module VMware.VimAutomation.Vds -ErrorAction Stop

$viCred = Get-Credential -Message "vCenter credentials ($($cfg.vCenter.server))"
$vc = Connect-VIServer -Server $cfg.vCenter.server -Credential $viCred
Write-Host "Connected to vCenter: $($vc.Name)" -ForegroundColor Green

# =======================================================================
# Helper: build one destination portgroup (handles same-vDS vs cross-vDS,
# uplink remap, existing-reuse). Returns @{ status, pg, vlan, message }.
#   status : ok | reused | skipped-suffix | failed
# =======================================================================
function Build-OnePortgroupClone {
    param($SrcVds, $DestVds, [string] $SourceName, [string] $DestName, [string] $Suffix)

    if (-not [string]::IsNullOrEmpty($Suffix) -and $SourceName.EndsWith($Suffix)) {
        return @{ status='skipped-suffix'; pg=$null; vlan=$null; message="source name already ends with $Suffix" }
    }

    $src = Get-VDPortgroup -VDSwitch $SrcVds -Name $SourceName -ErrorAction Stop
    $vlan = $src.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId

    $existing = Get-VDPortgroup -VDSwitch $DestVds -Name $DestName -ErrorAction SilentlyContinue
    if ($existing) {
        return @{ status='reused'; pg=$existing; vlan=$vlan; message="dest portgroup already exists - reusing" }
    }

    if ($SrcVds.Name -eq $DestVds.Name) {
        # Same vDS - uplink names match, -ReferencePortgroup is safe.
        $pg = New-VDPortgroup -VDSwitch $DestVds -Name $DestName -ReferencePortgroup $src
        return @{ status='ok'; pg=$pg; vlan=$vlan; message='created (same vDS)' }
    }

    # Cross-vDS - remap uplink names by index, preserve teaming semantics.
    $srcCfg = $src.ExtensionData.Config
    $spec   = New-Object VMware.Vim.DVPortgroupConfigSpec
    $spec.Name              = $DestName
    $spec.Type              = $srcCfg.Type
    $spec.NumPorts          = $srcCfg.NumPorts
    $spec.AutoExpand        = $srcCfg.AutoExpand
    $spec.Description       = $srcCfg.Description
    $spec.DefaultPortConfig = $srcCfg.DefaultPortConfig
    if ($spec.DefaultPortConfig.UplinkTeamingPolicy -and
        $spec.DefaultPortConfig.UplinkTeamingPolicy.UplinkPortOrder) {
        $srcUplinks = @($SrcVds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
        $dstUplinks = @($DestVds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
        $pairCount  = [Math]::Min($srcUplinks.Count, $dstUplinks.Count)
        $uplinkMap  = @{}
        for ($i = 0; $i -lt $pairCount; $i++) { $uplinkMap[$srcUplinks[$i]] = $dstUplinks[$i] }
        Write-Host ("  Uplink mapping: {0}" -f (
            ($uplinkMap.GetEnumerator() | ForEach-Object { "'$($_.Key)'->'$($_.Value)'" }) -join ', '
        )) -ForegroundColor DarkGray

        $order = $spec.DefaultPortConfig.UplinkTeamingPolicy.UplinkPortOrder
        $remappedActive  = New-Object System.Collections.Generic.List[string]
        foreach ($u in @($order.ActiveUplinkPort | Where-Object { $_ })) {
            if ($uplinkMap.ContainsKey($u)) { $remappedActive.Add($uplinkMap[$u]) }
            else { Write-Warning "Source uplink '$u' (active) has no dest counterpart; dropping" }
        }
        $remappedStandby = New-Object System.Collections.Generic.List[string]
        foreach ($u in @($order.StandbyUplinkPort | Where-Object { $_ })) {
            if ($uplinkMap.ContainsKey($u)) { $remappedStandby.Add($uplinkMap[$u]) }
            else { Write-Warning "Source uplink '$u' (standby) has no dest counterpart; dropping" }
        }
        $order.ActiveUplinkPort  = $remappedActive.ToArray()
        $order.StandbyUplinkPort = $remappedStandby.ToArray()
    }
    $taskMoRef = $DestVds.ExtensionData.AddDVPortgroup_Task(@($spec))
    $deadline  = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $taskInfo = Get-View -Id $taskMoRef
    } while ($taskInfo.Info.State -notin @('success', 'error') -and (Get-Date) -lt $deadline)
    if ($taskInfo.Info.State -ne 'success') {
        throw "AddDVPortgroup failed: $($taskInfo.Info.Error.LocalizedMessage)"
    }
    $pg = Get-VDPortgroup -VDSwitch $DestVds -Name $DestName
    return @{ status='ok'; pg=$pg; vlan=$vlan; message='created (cross-vDS, uplinks remapped)' }
}

try {
    $destVds = Get-VDSwitch -Name $DestinationVdsName

    # ===================== Rollback mode =====================
    if ($Rollback) {
        $existing = Get-VDPortgroup -VDSwitch $destVds -Name $destPg -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Warning "Destination portgroup '$destPg' does not exist on vDS '$DestinationVdsName'; nothing to roll back."
        }
        else {
            $connectedVms = $existing | Get-VM -ErrorAction SilentlyContinue
            if ($connectedVms) {
                Write-Warning "The following VMs are still connected to '$destPg'. Run step 3 first to move the NICs back:"
                $connectedVms | Select-Object Name, PowerState | Format-Table -AutoSize
                throw "Rollback aborted: destination portgroup still has connected VMs."
            }
            if ($PSCmdlet.ShouldProcess($destPg, "Delete portgroup from vDS '$DestinationVdsName'")) {
                Remove-VDPortgroup -VDPortgroup $existing -Confirm:$false
                Write-Host "Deleted portgroup: $destPg" -ForegroundColor Green
            }
        }
        if (Test-Path $HandoffPath) {
            if ($PSCmdlet.ShouldProcess($HandoffPath, "Delete hand-off file")) {
                Remove-Item $HandoffPath -Force
                Write-Host "Deleted hand-off file: $HandoffPath" -ForegroundColor Green
            }
        }
        Write-Host "Rollback complete." -ForegroundColor Green
        return
    }

    $srcVds = Get-VDSwitch -Name $SourceVdsName

    # ===================== Batch mode (-Interactive or -All) ============
    if ($batchMode) {
        if (-not ($cfg.portGroup.PSObject.Properties.Name -contains 'sources') -or
            -not $cfg.portGroup.sources -or @($cfg.portGroup.sources).Count -eq 0) {
            throw "-Interactive / -All requires cfg.portGroup.sources[] to be populated (run Build-SourcesFromVdsBackup.ps1 first)."
        }
        $sources = @($cfg.portGroup.sources)
        Write-Host ("Sources in config           : {0}" -f $sources.Count) -ForegroundColor Yellow

        $batchResults = New-Object System.Collections.Generic.List[object]
        $autoYes   = [bool]$All     # -All starts already auto-yes
        $userAbort = $false
        $i = 0
        foreach ($srcEntry in $sources) {
            if ($userAbort) { break }
            $i++
            $sourceName = $srcEntry.name
            $destName   = $sourceName + $suffix
            $started    = Get-Date

            Write-Host ""
            Write-Host ("[{0}/{1}] {2,-30} -> {3}" -f $i, $sources.Count, $sourceName, $destName) -ForegroundColor Cyan
            if ($srcEntry.PSObject.Properties.Name -contains 'vlan' -and $srcEntry.vlan) {
                Write-Host ("  VLAN(per config)  : {0}" -f $srcEntry.vlan)
            }
            Write-Host ("  Source vDS        : {0}" -f $SourceVdsName)
            Write-Host ("  Destination vDS   : {0}" -f $DestinationVdsName)

            # -WhatIf bypasses the interactive prompt (non-interactive dry-run)
            if (-not $autoYes -and -not $WhatIfPreference) {
                $choice = (Read-Host "  Proceed?  [Y]es / [N]o skip / [A]ll remaining / [Q]uit  (default Y)").Trim().ToLower()
                switch -Regex ($choice) {
                    '^q'    { Write-Host "  User quit batch." -ForegroundColor Yellow; $userAbort = $true; continue }
                    '^a'    { Write-Host "  Auto-yes for remaining $($sources.Count - $i + 1) source(s)." -ForegroundColor Yellow; $autoYes = $true }
                    '^n|^s' {
                        Write-Host "  User skipped." -ForegroundColor Yellow
                        $batchResults.Add([ordered]@{
                            source=$sourceName; dest=$destName; status='user-skipped'
                            durationSec=0; message=''
                        })
                        continue
                    }
                    default { } # empty or 'y*' -> proceed
                }
            }

            if (-not $PSCmdlet.ShouldProcess($sourceName, "Create $destName on $DestinationVdsName")) {
                $batchResults.Add([ordered]@{
                    source=$sourceName; dest=$destName; status='whatif'
                    durationSec=0; message=''
                })
                continue
            }

            try {
                $r = Build-OnePortgroupClone -SrcVds $srcVds -DestVds $destVds `
                        -SourceName $sourceName -DestName $destName -Suffix $suffix
                $elapsed = ((Get-Date) - $started).TotalSeconds
                $line = "  [{0}] {1:F1}s : {2}" -f $r.status.ToUpper(), $elapsed, $r.message
                $color = switch ($r.status) {
                    'ok'             { 'Green' }
                    'reused'         { 'DarkYellow' }
                    'skipped-suffix' { 'DarkYellow' }
                    default          { 'White' }
                }
                Write-Host $line -ForegroundColor $color
                $batchResults.Add([ordered]@{
                    source = $sourceName; dest = $destName
                    status = $r.status; vlan = $r.vlan
                    moref  = if ($r.pg) { $r.pg.Key } else { $null }
                    durationSec = [math]::Round($elapsed, 2)
                    message = $r.message
                })
            }
            catch {
                $elapsed = ((Get-Date) - $started).TotalSeconds
                Write-Warning ("  [FAILED] {0:F1}s : {1}" -f $elapsed, $_.Exception.Message)
                $batchResults.Add([ordered]@{
                    source=$sourceName; dest=$destName; status='failed'
                    durationSec=[math]::Round($elapsed, 2)
                    error=$_.Exception.Message
                })
            }
        }

        # Write batch summary (NOT the single-source hand-off).
        $batchSummaryPath = Join-Path (Split-Path $HandoffPath) 'step1-batch-result.json'
        $summary = [ordered]@{
            runAt              = (Get-Date).ToString('o')
            createdBy          = '01-create-portgroup/New-DistributedPortGroup-v1.1.ps1 -Interactive'
            sourceVdsName      = $SourceVdsName
            destinationVdsName = $DestinationVdsName
            destinationSuffix  = $suffix
            totalCandidates    = $sources.Count
            processed          = $batchResults.Count
            ok                 = ($batchResults | Where-Object { $_.status -eq 'ok' }).Count
            reused             = ($batchResults | Where-Object { $_.status -eq 'reused' }).Count
            skipped            = ($batchResults | Where-Object { $_.status -like '*skip*' }).Count
            failed             = ($batchResults | Where-Object { $_.status -eq 'failed' }).Count
            results            = $batchResults
        }
        $stateDir = Split-Path $batchSummaryPath
        if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        $summary | ConvertTo-Json -Depth 10 | Set-Content $batchSummaryPath -Encoding UTF8

        Write-Host ""
        Write-Host "=== BATCH DONE ===" -ForegroundColor Green
        Write-Host ("  OK          : {0}" -f $summary.ok)
        Write-Host ("  Reused      : {0}" -f $summary.reused)
        Write-Host ("  Skipped     : {0}" -f $summary.skipped) -ForegroundColor $(if ($summary.skipped) { 'Yellow' } else { 'Green' })
        Write-Host ("  Failed      : {0}" -f $summary.failed) -ForegroundColor $(if ($summary.failed)  { 'Red' }    else { 'Green' })
        Write-Host ("  Summary at  : {0}" -f $batchSummaryPath)
        if ($summary.failed -gt 0) {
            Write-Host ""
            Write-Host "Failed sources:" -ForegroundColor Red
            $batchResults | Where-Object { $_.status -eq 'failed' } | ForEach-Object {
                "  - {0}: {1}" -f $_.source, $_.error
            }
        }
        return
    }

    # ===================== Single-source create mode =====================
    if (-not $sourcePg) {
        throw "config.portGroup.source is empty - either set it, or pass -Interactive to iterate config.portGroup.sources[]."
    }

    Write-Host "Source VLAN config: $(Get-VDPortgroup -VDSwitch $srcVds -Name $sourcePg -ErrorAction Stop | ForEach-Object { $_.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId })" -ForegroundColor Yellow

    if (-not $PSCmdlet.ShouldProcess($destPg, "Create on vDS '$DestinationVdsName' (cloned from '$SourceVdsName/$sourcePg')")) {
        return
    }
    $r = Build-OnePortgroupClone -SrcVds $srcVds -DestVds $destVds `
            -SourceName $sourcePg -DestName $destPg -Suffix $suffix
    switch ($r.status) {
        'skipped-suffix' {
            Write-Warning "Source portgroup '$sourcePg' already ends with destinationSuffix '$suffix' - $($r.message). No hand-off written."
            return
        }
        'reused'  { Write-Warning $r.message }
        'ok'      { Write-Host ("Created portgroup: $($r.pg.Name)") -ForegroundColor Green }
    }
    $pg = $r.pg

    # --- Write the hand-off file for step 2 ------------------------------
    $handoff = [ordered]@{
        schemaVersion             = 1
        createdAt                 = (Get-Date).ToString('o')
        createdBy                 = '01-create-portgroup/New-DistributedPortGroup-v1.1.ps1'
        vCenter                   = $cfg.vCenter.server
        sourceVdsName             = $SourceVdsName
        destinationVdsName        = $DestinationVdsName
        sourcePortgroup           = $sourcePg
        destinationPortgroup      = $pg.Name
        destinationPortgroupMoref = $pg.Key
        destinationSuffix         = $suffix
        vlanId                    = "$($pg.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId)"
        tenant                    = [ordered]@{
            orgName    = $cfg.tenant.orgName
            orgVdcName = $cfg.tenant.orgVdcName
            orgVdcId   = if ($cfg.tenant.PSObject.Properties.Name -contains 'orgVdcId') { $cfg.tenant.orgVdcId } else { $null }
        }
    }

    $stateDir = Split-Path $HandoffPath
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $handoff | ConvertTo-Json -Depth 10 | Set-Content -Path $HandoffPath -Encoding UTF8

    Write-Host ""
    Write-Host "Portgroup ready:" -ForegroundColor Green
    Write-Host "  vDS         : $DestinationVdsName"
    Write-Host "  Portgroup   : $($pg.Name)"
    Write-Host "  Key (moref) : $($pg.Key)"
    Write-Host "  VLAN        : $($handoff.vlanId)"
    Write-Host "Hand-off file written: $HandoffPath" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next step: run 02-import-network/Import-OrgVdcNetwork-AutoDetect.ps1 - it reads the hand-off file above." -ForegroundColor Cyan
    Write-Host "To undo:   pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.1.ps1 -Rollback" -ForegroundColor DarkGray
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}

