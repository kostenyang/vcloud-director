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

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.1.ps1
  # Create the destination portgroup and write the hand-off file

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.1.ps1 -DestinationVdsName "DSwitch-DR"
  # Create the destination portgroup on a different vDS "DSwitch-DR"

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.1.ps1 -Rollback
  # Rollback: delete the destination portgroup and the hand-off file

.NOTES
  Version: 1.1
  Changelog:
    1.1 - (a) refuse to build "<source>-new-new" if config.portGroup.source
              already ends with destinationSuffix (operator likely re-ran
              against an already-migrated portgroup)
          (b) cross-vDS clone: -ReferencePortgroup carries the source vDS's
              uplink port names (e.g. "Uplink 1") in the teaming policy and
              the destination vDS rejects them. When SourceVds != DestVds,
              build the spec manually and clear UplinkPortOrder so the
              destination vDS applies its own uplink defaults.
    1.0 - initial version (same-vDS clone via -ReferencePortgroup)
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath,
    [string] $HandoffPath,
    [string] $SourceVdsName,
    [string] $DestinationVdsName,
    [switch] $Rollback
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
# Parameters take precedence, then config
if (-not $SourceVdsName)      { $SourceVdsName      = $cfg.vCenter.sourceVdsName }
if (-not $DestinationVdsName) { $DestinationVdsName = $cfg.vCenter.destinationVdsName }
if (-not $SourceVdsName)      { throw "Source vDS not specified (-SourceVdsName or config.vCenter.sourceVdsName)" }
if (-not $DestinationVdsName) { throw "Destination vDS not specified (-DestinationVdsName or config.vCenter.destinationVdsName)" }

$sourcePg = $cfg.portGroup.source
$destPg   = $cfg.portGroup.source + $cfg.portGroup.destinationSuffix

Write-Host "Source vDS / portgroup      : $SourceVdsName / $sourcePg"
Write-Host "Destination vDS / portgroup : $DestinationVdsName / $destPg"
Write-Host "Hand-off file               : $HandoffPath"
Write-Host "Mode                        : $(if ($Rollback) { 'ROLLBACK (delete destination portgroup)' } else { 'CREATE destination portgroup' })" -ForegroundColor $(if ($Rollback) { 'Magenta' } else { 'White' })

# --- PowerCLI ------------------------------------------------------------
Import-Module VMware.VimAutomation.Vds -ErrorAction Stop

$viCred = Get-Credential -Message "vCenter credentials ($($cfg.vCenter.server))"
$vc = Connect-VIServer -Server $cfg.vCenter.server -Credential $viCred
Write-Host "Connected to vCenter: $($vc.Name)" -ForegroundColor Green

try {
    $destVds = Get-VDSwitch -Name $DestinationVdsName

    # ===================== Rollback mode =====================
    if ($Rollback) {
        $existing = Get-VDPortgroup -VDSwitch $destVds -Name $destPg -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Warning "Destination portgroup '$destPg' does not exist on vDS '$DestinationVdsName'; nothing to roll back."
        }
        else {
            # Safety check: do not delete while VMs are still connected
            $connectedVms = $existing | Get-VM -ErrorAction SilentlyContinue
            if ($connectedVms) {
                Write-Warning "The following VMs are still connected to '$destPg'. Run 02-import-switch-nic/Import-And-Switch-TenantNic.ps1 first to move the NICs back:"
                $connectedVms | Select-Object Name, PowerState | Format-Table -AutoSize
                throw "Rollback aborted: destination portgroup still has connected VMs."
            }
            if ($PSCmdlet.ShouldProcess($destPg, "Delete portgroup from vDS '$DestinationVdsName'")) {
                Remove-VDPortgroup -VDPortgroup $existing -Confirm:$false
                Write-Host "Deleted portgroup: $destPg" -ForegroundColor Green
            }
        }

        # Remove the hand-off file so step 2 cannot run against stale info
        if (Test-Path $HandoffPath) {
            if ($PSCmdlet.ShouldProcess($HandoffPath, "Delete hand-off file")) {
                Remove-Item $HandoffPath -Force
                Write-Host "Deleted hand-off file: $HandoffPath" -ForegroundColor Green
            }
        }
        Write-Host "Rollback complete." -ForegroundColor Green
        return
    }

    # ===================== Create mode =====================
    # Refuse to build "<source>-new-new" if the configured source already ends
    # with destinationSuffix - usually means a re-run against an already-
    # migrated portgroup. Operator should point cfg.portGroup.source at the
    # ORIGINAL name, not the "-new" one.
    $suffix = $cfg.portGroup.destinationSuffix
    if (-not [string]::IsNullOrEmpty($suffix) -and $sourcePg.EndsWith($suffix)) {
        Write-Warning "Source portgroup '$sourcePg' already ends with destinationSuffix '$suffix'; looks like an already-migrated portgroup. Skipping create (would have built '$destPg')."
        return
    }

    $srcVds = Get-VDSwitch -Name $SourceVdsName
    $src    = Get-VDPortgroup -VDSwitch $srcVds -Name $sourcePg

    # VLAN info (log only; New-VDPortgroup -ReferencePortgroup clones it anyway)
    $vlanCfg = $src.Extensiondata.Config.DefaultPortConfig.Vlan
    Write-Host "Source VLAN config: $($vlanCfg.VlanId)" -ForegroundColor Yellow

    $existing = Get-VDPortgroup -VDSwitch $destVds -Name $destPg -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "Destination portgroup '$destPg' already exists on vDS '$DestinationVdsName'; reusing it."
        $pg = $existing
    }
    elseif ($PSCmdlet.ShouldProcess($destPg, "Create on vDS '$DestinationVdsName' (cloned from '$SourceVdsName/$sourcePg')")) {
        if ($srcVds.Name -eq $destVds.Name) {
            # Same vDS - uplink names match, -ReferencePortgroup is safe.
            $pg = New-VDPortgroup -VDSwitch $destVds -Name $destPg -ReferencePortgroup $src
        }
        else {
            # Cross-vDS - -ReferencePortgroup propagates the source vDS's
            # uplink port names into spec.uplinkTeamingPolicy.uplinkPortOrder,
            # and the destination vDS rejects them (its uplinks have
            # different names). REMAP each source uplink to the destination
            # uplink at the same index, preserving the teaming semantics
            # (active/standby roles, order) so VMs don't lose connectivity
            # when the new portgroup takes over.
            $srcCfg = $src.ExtensionData.Config
            $spec   = New-Object VMware.Vim.DVPortgroupConfigSpec
            $spec.Name              = $destPg
            $spec.Type              = $srcCfg.Type
            $spec.NumPorts          = $srcCfg.NumPorts
            $spec.AutoExpand        = $srcCfg.AutoExpand
            $spec.Description       = $srcCfg.Description
            $spec.DefaultPortConfig = $srcCfg.DefaultPortConfig
            if ($spec.DefaultPortConfig.UplinkTeamingPolicy -and
                $spec.DefaultPortConfig.UplinkTeamingPolicy.UplinkPortOrder) {
                $srcUplinks = @($srcVds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
                $dstUplinks = @($destVds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
                $pairCount  = [Math]::Min($srcUplinks.Count, $dstUplinks.Count)
                $uplinkMap  = @{}
                for ($i = 0; $i -lt $pairCount; $i++) { $uplinkMap[$srcUplinks[$i]] = $dstUplinks[$i] }
                Write-Host ("  Uplink mapping: {0}" -f (
                    ($uplinkMap.GetEnumerator() | ForEach-Object { "'$($_.Key)'->'$($_.Value)'" }) -join ', '
                )) -ForegroundColor DarkGray

                $order = $spec.DefaultPortConfig.UplinkTeamingPolicy.UplinkPortOrder
                # PowerCLI gives back .NET String[]; can be null when teaming
                # is inherited or the list is empty. Filter to non-empty strings.
                $remappedActive  = New-Object System.Collections.Generic.List[string]
                foreach ($u in @($order.ActiveUplinkPort | Where-Object { $_ })) {
                    if ($uplinkMap.ContainsKey($u)) { $remappedActive.Add($uplinkMap[$u]) }
                    else { Write-Warning "Source uplink '$u' (active) has no dest counterpart - src has $($srcUplinks.Count), dst has $($dstUplinks.Count); dropping" }
                }
                $remappedStandby = New-Object System.Collections.Generic.List[string]
                foreach ($u in @($order.StandbyUplinkPort | Where-Object { $_ })) {
                    if ($uplinkMap.ContainsKey($u)) { $remappedStandby.Add($uplinkMap[$u]) }
                    else { Write-Warning "Source uplink '$u' (standby) has no dest counterpart - dropping" }
                }
                $order.ActiveUplinkPort  = $remappedActive.ToArray()
                $order.StandbyUplinkPort = $remappedStandby.ToArray()
            }
            $taskMoRef = $destVds.ExtensionData.AddDVPortgroup_Task(@($spec))
            $deadline  = (Get-Date).AddSeconds(60)
            do {
                Start-Sleep -Milliseconds 500
                $taskInfo = Get-View -Id $taskMoRef
            } while ($taskInfo.Info.State -notin @('success', 'error') -and (Get-Date) -lt $deadline)
            if ($taskInfo.Info.State -ne 'success') {
                throw "AddDVPortgroup failed: $($taskInfo.Info.Error.LocalizedMessage)"
            }
            $pg = Get-VDPortgroup -VDSwitch $destVds -Name $destPg
        }
        Write-Host "Created portgroup: $($pg.Name)" -ForegroundColor Green
    }
    else {
        return   # -WhatIf: nothing created, no hand-off file
    }

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
        destinationSuffix         = $cfg.portGroup.destinationSuffix
        vlanId                    = "$($pg.Extensiondata.Config.DefaultPortConfig.Vlan.VlanId)"
        tenant                    = [ordered]@{
            orgName    = $cfg.tenant.orgName
            orgVdcName = $cfg.tenant.orgVdcName
            # Optional URN override - pass through if set in config so step 2 can
            # bypass name-based lookup (useful when many tenants share names).
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
    Write-Host "Next step: run 02-import-switch-nic/Import-And-Switch-TenantNic.ps1 - it reads the hand-off file above." -ForegroundColor Cyan
    Write-Host "To undo:   pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.1.ps1 -Rollback" -ForegroundColor DarkGray
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
