<#
.SYNOPSIS
    Deploy Ubuntu 20.04 NFS server VM for VCD transfer storage.
    VM: kosten-vcd-nfs.rtolab.local @ 192.168.114.61
    NFS export: 192.168.114.61:/exports/vcd-transfer

.EXAMPLE
    pwsh E:\VCD\01-Deploy-NfsVm.ps1
    pwsh E:\VCD\01-Deploy-NfsVm.ps1 -WipeFirst
#>
param(
    [switch] $WipeFirst
)

$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

# --------------- 固定參數 ---------------
$ovaPath   = 'E:\ubuntu-2004-cloud.ova'
$vmName    = 'kosten-vcd-nfs'
$hostname  = 'kosten-vcd-nfs'
$domain    = 'rtolab.local'
$fqdn      = "$hostname.$domain"
$ip        = '192.168.114.61'
$gateway   = '192.168.114.254'
$dns       = '192.168.114.200'
$nfsExport = '/exports/vcd-transfer'

# outer vCenter
$vcServer  = 'vc-mgmt.vmware.taiwan'
$vcUser    = 'administrator@vmwaresso.taiwan'
$vcPw      = '381VMware1!admin'
$rpName    = 'Kosten'
$dsName    = 'vsanDatastore-RTO'
$pgName    = 'selab-dswitch-pg114'
$clName    = 'SELAB-Cluster'
# --------------- 參數結束 ---------------

# cloud-init user-data: 設密碼 + 裝 nfs-kernel-server + 設 export
$userdata = @"
#cloud-config
hostname: $hostname
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
chpasswd:
  list: |
    ubuntu:VMware1!VMware1!
  expire: False
ssh_pwauth: true
packages:
  - nfs-kernel-server
runcmd:
  - mkdir -p $nfsExport
  - chmod 777 $nfsExport
  - echo "$nfsExport 192.168.114.0/24(rw,sync,no_root_squash,no_subtree_check)" >> /etc/exports
  - systemctl enable nfs-kernel-server
  - systemctl start nfs-kernel-server
  - exportfs -ra
  - echo "done" > /root/nfs-setup.done
"@

$metadata = @"
instance-id: $hostname
local-hostname: $hostname
network:
  version: 2
  ethernets:
    ens192:
      addresses: [${ip}/24]
      gateway4: $gateway
      nameservers:
        addresses: [$dns]
        search: [$domain]
"@

$userdataB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userdata))
$metadataB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($metadata))

Write-Host "Connecting $vcServer ..." -ForegroundColor Cyan
Connect-VIServer $vcServer -User $vcUser -Password $vcPw | Out-Null

if ($WipeFirst) {
    $ex = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($ex) {
        Write-Host "[wipe] $vmName" -ForegroundColor Yellow
        if ($ex.PowerState -eq 'PoweredOn') { Stop-VM $ex -Kill -Confirm:$false | Out-Null; Start-Sleep 3 }
        Remove-VM $ex -DeletePermanently -Confirm:$false | Out-Null
    }
}

if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
    Write-Host "[skip] $vmName already exists (use -WipeFirst to redeploy)" -ForegroundColor DarkGray
    Disconnect-VIServer * -Confirm:$false -Force | Out-Null
    return
}

$rp     = Get-ResourcePool -Name $rpName -ErrorAction Stop
$ds     = Get-Datastore    -Name $dsName -ErrorAction Stop
$pg     = Get-VDPortgroup  -Name $pgName -ErrorAction Stop
$cl     = Get-Cluster      -Name $clName -ErrorAction Stop
$vmhost = $cl | Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' } | Get-Random

Write-Host "Loading OVF config ..." -ForegroundColor Cyan
$cfg = Get-OvfConfiguration -Ovf $ovaPath

# network mapping
if ($cfg.NetworkMapping) {
    $cfg.NetworkMapping.PSObject.Properties | ForEach-Object { $_.Value.Value = $pg }
}

# 常見 Ubuntu cloud OVA property 名稱 (有一個就夠)
@('user-data','userdata')   | ForEach-Object { if ($cfg.Common.PSObject.Properties[$_]) { $cfg.Common.$_.Value = $userdataB64 } }
@('meta-data','metadata')   | ForEach-Object { if ($cfg.Common.PSObject.Properties[$_]) { $cfg.Common.$_.Value = $metadataB64 } }
@('hostname','public-hostname') | ForEach-Object { if ($cfg.Common.PSObject.Properties[$_]) { $cfg.Common.$_.Value = $fqdn } }
@('password','Password')    | ForEach-Object { if ($cfg.Common.PSObject.Properties[$_]) { $cfg.Common.$_.Value = 'VMware1!VMware1!' } }

Write-Host "Deploying $vmName (thin) -> $rpName / $dsName ..." -ForegroundColor Cyan
$vm = Import-VApp -Source $ovaPath -OvfConfiguration $cfg -Name $vmName `
    -VMHost $vmhost -Datastore $ds -DiskStorageFormat Thin -Location $rp -Force

# guestinfo 方式 (VMware cloud-init datasource)
$vmView = Get-View -VIObject $vm
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.ExtraConfig = @(
    (New-Object VMware.Vim.OptionValue -Property @{ Key = 'guestinfo.userdata';          Value = $userdataB64 }),
    (New-Object VMware.Vim.OptionValue -Property @{ Key = 'guestinfo.userdata.encoding'; Value = 'base64' }),
    (New-Object VMware.Vim.OptionValue -Property @{ Key = 'guestinfo.metadata';          Value = $metadataB64 }),
    (New-Object VMware.Vim.OptionValue -Property @{ Key = 'guestinfo.metadata.encoding'; Value = 'base64' })
)
$vmView.ReconfigVM($spec)
Write-Host "  guestinfo cloud-init properties set." -ForegroundColor DarkGray

Write-Host "Powering on ..." -ForegroundColor Cyan
Start-VM $vm -Confirm:$false | Out-Null

Write-Host ""
Write-Host "✓ $vmName powered on. cloud-init runs NFS setup in background (~3-5 min)." -ForegroundColor Green
Write-Host "  SSH:    ubuntu@$ip  (pw: VMware1!VMware1!)" -ForegroundColor Cyan
Write-Host "  Verify: cat /root/nfs-setup.done" -ForegroundColor Cyan
Write-Host "  Mount:  showmount -e $ip" -ForegroundColor Cyan
Write-Host "  Export: ${ip}:${nfsExport}" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next: pwsh E:\VCD\02-Deploy-VcdOva.ps1 -DumpPropertiesOnly" -ForegroundColor Yellow

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
