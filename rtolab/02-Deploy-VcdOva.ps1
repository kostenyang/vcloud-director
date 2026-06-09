<#
.SYNOPSIS
    Deploy VMware Cloud Director 10.6.1 appliance OVA.
    eth0 (管理/API): kosten-vcd.rtolab.local @ 192.168.114.60
    eth1 (內部服務/DB): 192.168.114.62

.DESCRIPTION
    OVF 四個 ProductSection:
      vami        -> ip0/netmask0/ip1/netmask1/gateway/DNS/domain/searchpath
      vcloudapp   -> ntp-server/varoot-password/enable_ssh/expire_root_password/nfs_mount
      vcloudconf  -> admin_uname/admin_pwd/admin_email/sys_name
      vcloudnet   -> routes0/routes1 (lab 不用設)

    全部用 OVF 設好，不需要跑 firstboot wizard.
    NetworkMapping 為空時由 post-deploy Set-NetworkAdapter 修正.

.EXAMPLE
    pwsh E:\VCD\02-Deploy-VcdOva.ps1
    pwsh E:\VCD\02-Deploy-VcdOva.ps1 -WipeFirst
#>
param(
    [switch] $WipeFirst
)

$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

# --------------- 固定參數 ---------------
$ovaPath  = 'E:\VCD\VMware_Cloud_Director-10.6.1.11883-25088252_OVF10.ova'
$vmName   = 'kosten-vcd'
$domain   = 'rtolab.local'
$fqdn     = "kosten-vcd.$domain"

# vami — 網路
$ip0      = '192.168.114.60'
$netmask0 = '255.255.255.0'
$ip1      = '192.168.114.62'   # eth1: internal services / embedded DB
$netmask1 = '255.255.255.0'
$gateway  = '192.168.114.254'
$dns      = '192.168.114.200'

# vcloudapp — 系統
$ntp      = '192.168.114.200'
$rootPw   = 'VMware1!VMware1!'
$nfsMount = '192.168.114.61:/exports/vcd-transfer'

# vcloudconf — VCD admin (wizard skip)
$adminUser  = 'administrator'
$adminPw    = 'VMware1!VMware1!'
$adminEmail = "admin@$domain"
$sysName    = 'kosten-vcd'

# outer vCenter
$vcServer = 'vc-mgmt.vmware.taiwan'
$vcUser   = 'administrator@vmwaresso.taiwan'
$vcPw     = '381VMware1!admin'
$rpName   = 'Kosten'
$dsName   = 'vsanDatastore-RTO'
$pgName   = 'selab-dswitch-pg114'
$clName   = 'SELAB-Cluster'
# --------------- 參數結束 ---------------

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

Write-Host "Loading OVF config (2.4GB OVA, ~30s) ..." -ForegroundColor Cyan
$cfg = Get-OvfConfiguration -Ovf $ovaPath
$cfg.DeploymentOption.Value = 'primary-small'

# ---- NetworkMapping: 兩個 NIC 都接 pg114 ----
$cfg.NetworkMapping.eth0_Network.Value = $pg
$cfg.NetworkMapping.eth1_Network.Value = $pg

# ---- vami: 網路設定 ----
$cfg.vami.VMware_vCloud_Director.ip0.Value        = $ip0
$cfg.vami.VMware_vCloud_Director.netmask0.Value   = $netmask0
$cfg.vami.VMware_vCloud_Director.ip1.Value        = $ip1
$cfg.vami.VMware_vCloud_Director.netmask1.Value   = $netmask1
$cfg.vami.VMware_vCloud_Director.gateway.Value    = $gateway
$cfg.vami.VMware_vCloud_Director.DNS.Value        = $dns
$cfg.vami.VMware_vCloud_Director.domain.Value     = $domain
$cfg.vami.VMware_vCloud_Director.searchpath.Value = $domain

# ---- vcloudapp: 系統 (userConfigurable=true 的才能設) ----
$cfg.vcloudapp.VMware_vCloud_Director.ntp_server.Value           = $ntp
$cfg.vcloudapp.VMware_vCloud_Director.varoot_password.Value      = $rootPw
$cfg.vcloudapp.VMware_vCloud_Director.expire_root_password.Value = $false
$cfg.vcloudapp.VMware_vCloud_Director.enable_ssh.Value           = $true
# nfs_mount / vcloudconf (admin_uname/pwd/email/sys_name) 是 userConfigurable=false
# PowerCLI 不開放設定 → firstboot wizard 填入 (需 <5 min)

Write-Host "OVF properties set:" -ForegroundColor DarkGray
Write-Host "  eth0: $ip0/$netmask0  GW: $gateway  DNS: $dns" -ForegroundColor DarkGray
Write-Host "  eth1: $ip1/$netmask1  (internal DB)" -ForegroundColor DarkGray
Write-Host "  root: $rootPw  SSH: enabled  NTP: $ntp" -ForegroundColor DarkGray
Write-Host "  (NFS + admin 在 firstboot wizard 設定)" -ForegroundColor DarkGray

Write-Host ""
Write-Host "Deploying $vmName (primary-small, thin) -> $rpName / $dsName ..." -ForegroundColor Cyan
$vm = Import-VApp -Source $ovaPath -OvfConfiguration $cfg -Name $vmName `
    -VMHost $vmhost -Datastore $ds -DiskStorageFormat Thin -Location $rp `
    -Force

# NetworkMapping 空，部完後接正確 portgroup
Write-Host "Fixing network adapters -> $pgName ..." -ForegroundColor Cyan
$vm | Get-NetworkAdapter | Set-NetworkAdapter -Portgroup $pg -Confirm:$false | Out-Null
Write-Host "  eth0 + eth1 both mapped to $pgName" -ForegroundColor DarkGray

Write-Host "Powering on ..." -ForegroundColor Cyan
Start-VM $vm -Confirm:$false | Out-Null

Disconnect-VIServer * -Confirm:$false -Force | Out-Null

Write-Host ""
Write-Host "✓ $vmName deployed & powered on (primary-small: 2 vCPU)." -ForegroundColor Green
Write-Host "  Firstboot ~10-15 min (DB init + NFS mount + cell config)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  UI:    https://$fqdn/ui       (admin / $adminPw)" -ForegroundColor Cyan
Write-Host "  API:   https://$ip0/api" -ForegroundColor Cyan
Write-Host "  SSH:   root@$ip0  (pw: $rootPw)" -ForegroundColor Cyan
Write-Host "  eth1 (internal): $ip1" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next: pwsh E:\VCD\03-Configure-Vcd.ps1  (firstboot 後驗證)" -ForegroundColor Yellow
