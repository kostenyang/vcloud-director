<#
.SYNOPSIS
    Deploy VMware Cloud Director 10.6.1 appliance OVA.
    VM: kosten-vcd.rtolab.local @ 192.168.114.60

.DESCRIPTION
    Step 1 (建議先跑): -DumpPropertiesOnly  -> 印出 OVA 的 OVF property 名稱
    Step 2: 去掉 flag 實際部署
    VCD firstboot ~10-15 min; 完成後用 https://192.168.114.60/cloud 做 wizard 設定.

.EXAMPLE
    pwsh E:\VCD\02-Deploy-VcdOva.ps1 -DumpPropertiesOnly
    pwsh E:\VCD\02-Deploy-VcdOva.ps1
    pwsh E:\VCD\02-Deploy-VcdOva.ps1 -WipeFirst
#>
param(
    [switch] $WipeFirst,
    [switch] $DumpPropertiesOnly
)

$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

# --------------- 固定參數 ---------------
$ovaPath  = 'E:\VCD\VMware_Cloud_Director-10.6.1.11883-25088252_OVF10.ova'
$vmName   = 'kosten-vcd'
$hostname = 'kosten-vcd'
$domain   = 'rtolab.local'
$fqdn     = "$hostname.$domain"
$ip       = '192.168.114.60'
$netmask  = '255.255.255.0'
$prefix   = '24'
$gateway  = '192.168.114.254'
$dns      = '192.168.114.200'
$ntp      = '192.168.114.200'
$rootPw   = 'VMware1!VMware1!'

# outer vCenter
$vcServer = 'vc-mgmt.vmware.taiwan'
$vcUser   = 'administrator@vmwaresso.taiwan'
$vcPw     = '381VMware1!admin'
$rpName   = 'Kosten'
$dsName   = 'vsanDatastore-RTO'
$pgName   = 'selab-dswitch-pg114'
$clName   = 'SELAB-Cluster'
# --------------- 參數結束 ---------------

# ----- 遞迴印出 OvfConfig 所有 property -----
function Show-OvfProperties {
    param($node, [string]$prefix = '')
    foreach ($p in $node.PSObject.Properties) {
        $v = $p.Value
        if ($null -eq $v) { continue }
        if ($v.GetType().Name -eq 'OvfPropertyValue') {
            Write-Host ("  {0,-70} = '{1}'" -f ($prefix + $p.Name), $v.Value) -ForegroundColor DarkCyan
        } elseif ($v.GetType().Name -eq 'OvfNetworkMappingValue') {
            Write-Host ("  NetworkMapping.{0}" -f $p.Name) -ForegroundColor DarkGray
        } else {
            Show-OvfProperties $v ($prefix + $p.Name + '.')
        }
    }
}

# ----- 嘗試設 OVF property (不噴錯) -----
function Try-SetProp {
    param($cfg, [string]$keyPath, [string]$val)
    $parts = $keyPath -split '\.'
    try {
        # 先試頂層 Common 直接當 flat key
        $node = $cfg.Common
        if ($node.PSObject.Properties[$keyPath]) {
            $node.$keyPath.Value = $val; return $true
        }
        # 再試逐層下鑽
        foreach ($part in $parts) {
            if ($null -eq $node -or -not $node.PSObject.Properties[$part]) { return $false }
            $node = $node.$part
        }
        if ($node.GetType().Name -eq 'OvfPropertyValue') {
            $node.Value = $val; return $true
        }
    } catch {}
    return $false
}

Write-Host "Loading OVF config from $ovaPath ..." -ForegroundColor Cyan
Write-Host "(OVA 2.4GB, 解析需 ~30s)" -ForegroundColor DarkGray
$cfg = Get-OvfConfiguration -Ovf $ovaPath

Write-Host ""
Write-Host "=== OVF properties in this OVA ===" -ForegroundColor Yellow
Show-OvfProperties $cfg
Write-Host "===================================" -ForegroundColor Yellow

if ($DumpPropertiesOnly) {
    Write-Host ""
    Write-Host "-DumpPropertiesOnly: 停在這裡. 確認上面的 property 名稱後去掉 flag 再部." -ForegroundColor Yellow
    Write-Host "  如果 property 名稱跟腳本裡的 propMap 不符, 請修改 02-Deploy-VcdOva.ps1 的 propMap." -ForegroundColor Yellow
    return
}

Write-Host ""
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

# network mapping
if ($cfg.NetworkMapping) {
    $cfg.NetworkMapping.PSObject.Properties | ForEach-Object { $_.Value.Value = $pg }
}

# VCD 10.x OVF property map (vami namespace, PhotonOS appliance)
# 執行 -DumpPropertiesOnly 後若 key 名稱不同請在此修改
$propMap = [ordered]@{
    # --- vami namespace (VCD 10.4+) ---
    'vami.VMware_vCloud_Director.ip0'         = $ip
    'vami.VMware_vCloud_Director.netmask0'    = $netmask
    'vami.VMware_vCloud_Director.gateway'     = $gateway
    'vami.VMware_vCloud_Director.DNS'         = $dns
    'vami.VMware_vCloud_Director.domain'      = $domain
    'vami.VMware_vCloud_Director.searchpath'  = $domain
    'vami.VMware_vCloud_Director.hostname'    = $fqdn
    'vami.VMware_vCloud_Director.ntp'         = $ntp
    # --- flat vami (舊版風格) ---
    'vami.ip0.VMware_vCloud_Director'         = $ip
    'vami.netmask0.VMware_vCloud_Director'    = $netmask
    'vami.gateway.VMware_vCloud_Director'     = $gateway
    'vami.DNS.VMware_vCloud_Director'         = $dns
    'vami.domain.VMware_vCloud_Director'      = $domain
    'vami.searchpath.VMware_vCloud_Director'  = $domain
    'vami.hostname.VMware_vCloud_Director'    = $fqdn
    'vami.ntp.VMware_vCloud_Director'         = $ntp
    # --- common keys ---
    'ROOT_PASSWORD'                            = $rootPw
    'ENABLE_SSH'                               = 'true'
    'guestinfo.cis.appliance.root.passwd'      = $rootPw
    'guestinfo.cis.appliance.ssh.enabled'      = 'true'
    'guestinfo.cis.appliance.net.addr'         = $ip
    'guestinfo.cis.appliance.net.prefix'       = $prefix
    'guestinfo.cis.appliance.net.gateway'      = $gateway
    'guestinfo.cis.appliance.net.dns.servers'  = $dns
    'guestinfo.cis.appliance.net.pnid'         = $fqdn
    'guestinfo.cis.appliance.net.mode'         = 'static'
    'guestinfo.cis.appliance.net.addr.family'  = 'ipv4'
}

$set = 0
foreach ($kv in $propMap.GetEnumerator()) {
    if (Try-SetProp $cfg $kv.Key $kv.Value) {
        Write-Host "  [set] $($kv.Key) = '$($kv.Value)'" -ForegroundColor DarkGray
        $set++
    }
}
Write-Host "  $set properties set." -ForegroundColor $(if ($set -gt 0) { 'Green' } else { 'Red' })
if ($set -eq 0) {
    Write-Warning "No OVF properties matched. Run with -DumpPropertiesOnly first and update propMap in the script."
}

Write-Host ""
Write-Host "Deploying $vmName (thin) -> $rpName / $dsName ..." -ForegroundColor Cyan
$vm = Import-VApp -Source $ovaPath -OvfConfiguration $cfg -Name $vmName `
    -VMHost $vmhost -Datastore $ds -DiskStorageFormat Thin -Location $rp -Force

Write-Host "Powering on ..." -ForegroundColor Cyan
Start-VM $vm -Confirm:$false | Out-Null

Write-Host ""
Write-Host "✓ $vmName powered on. VCD firstboot ~10-15 min." -ForegroundColor Green
Write-Host "  Ping check:  Test-Connection $ip -Count 1" -ForegroundColor Cyan
Write-Host "  SSH (root):  ssh root@$ip" -ForegroundColor Cyan
Write-Host "  Setup UI:    https://$ip/cloud  (after firstboot)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. pwsh E:\VCD\04-Add-VcdDns.ps1       (add DNS records now)"
Write-Host "  2. Wait for VCD firstboot to complete"
Write-Host "  3. pwsh E:\VCD\03-Configure-Vcd.ps1    (mount NFS, verify)"
Write-Host "  4. Complete wizard at https://$fqdn/cloud"

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
