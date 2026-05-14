<#
.SYNOPSIS
  Step 1 / 2 - Create the "destination" distributed portgroup on a vCenter vDS.

.DESCRIPTION
  Clones the settings (VLAN, binding, teaming, etc.) from the source portgroup
  and creates a new portgroup named "<source name> + suffix (-new)".

  The source vDS and destination vDS are separate variables: the destination
  portgroup can be created on a *different* vDS (source on A, destination on B).
  When both are the same, it simply clones within the same vDS.

  This script only touches vCenter, not VCD. Run script 2 afterwards to import
  the network into the tenant and reconnect the NICs.

.PARAMETER ConfigPath
  Path to config.json. Defaults to ..\config\config.json
  (config.local.json is used in preference if present).

.PARAMETER SourceVdsName
  vDS that hosts the source portgroup. Defaults to config vCenter.sourceVdsName.

.PARAMETER DestinationVdsName
  vDS on which the destination portgroup is created. Defaults to
  config vCenter.destinationVdsName. Use this parameter (or config) to target
  a different vDS.

.PARAMETER Rollback
  Rollback mechanism: delete the previously created destination portgroup.
  Aborts if any VM is still connected to it - run script 2 first to move the
  NICs back.

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1
  # Create the destination portgroup using config values

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -DestinationVdsName "DSwitch-DR"
  # Create the destination portgroup on a different vDS "DSwitch-DR"

.EXAMPLE
  pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -Rollback
  # Rollback: delete the destination portgroup that was created
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath = "$PSScriptRoot\..\config\config.json",
    [string] $SourceVdsName,
    [string] $DestinationVdsName,
    [switch] $Rollback
)

$ErrorActionPreference = 'Stop'

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
            return
        }

        # Safety check: do not delete while VMs are still connected
        $connectedVms = $existing | Get-VM -ErrorAction SilentlyContinue
        if ($connectedVms) {
            Write-Warning "The following VMs are still connected to '$destPg'. Run 02-import-switch-nic/Import-And-Switch-TenantNic.ps1 first to move the NICs back:"
            $connectedVms | Select-Object Name, PowerState | Format-Table -AutoSize
            throw "Rollback aborted: destination portgroup still has connected VMs."
        }

        if ($PSCmdlet.ShouldProcess($destPg, "Delete portgroup from vDS '$DestinationVdsName'")) {
            Remove-VDPortgroup -VDPortgroup $existing -Confirm:$false
            Write-Host "Deleted portgroup: $destPg (rollback complete)" -ForegroundColor Green
        }
        return
    }

    # ===================== Create mode =====================
    $srcVds = Get-VDSwitch -Name $SourceVdsName
    $src    = Get-VDPortgroup -VDSwitch $srcVds -Name $sourcePg

    # VLAN info (log only; New-VDPortgroup -ReferencePortgroup clones it anyway)
    $vlanCfg = $src.Extensiondata.Config.DefaultPortConfig.Vlan
    Write-Host "Source VLAN config: $($vlanCfg.VlanId)" -ForegroundColor Yellow

    $existing = Get-VDPortgroup -VDSwitch $destVds -Name $destPg -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "Destination portgroup '$destPg' already exists on vDS '$DestinationVdsName'; skipping creation."
        return
    }

    if ($PSCmdlet.ShouldProcess($destPg, "Create on vDS '$DestinationVdsName' (cloned from '$SourceVdsName/$sourcePg')")) {
        $new = New-VDPortgroup -VDSwitch $destVds -Name $destPg -ReferencePortgroup $src
        Write-Host "Created portgroup: $($new.Name)" -ForegroundColor Green
        Write-Host "  vDS         : $DestinationVdsName"
        Write-Host "  Key (moref) : $($new.Key)"
        Write-Host "  VLAN        : $($new.Extensiondata.Config.DefaultPortConfig.Vlan.VlanId)"
        Write-Host ""
        Write-Host "Next step: run 02-import-switch-nic/Import-And-Switch-TenantNic.ps1 to import into the tenant and reconnect NICs." -ForegroundColor Cyan
        Write-Host "To undo:   pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -Rollback" -ForegroundColor DarkGray
    }
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
