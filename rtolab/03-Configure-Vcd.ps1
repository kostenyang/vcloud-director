<#
.SYNOPSIS
    VCD 10.6.1 post-deploy 設定:
      1. 等 VCD appliance 起來
      2. Mount NFS transfer storage
      3. 印出 wizard 後續步驟

.DESCRIPTION
    Run AFTER 01-Deploy-NfsVm + 02-Deploy-VcdOva.
    NFS server: 192.168.114.61:/exports/vcd-transfer
    VCD mount point: /opt/vmware/vcloud-director/data/transfer

.EXAMPLE
    pwsh E:\VCD\03-Configure-Vcd.ps1
    pwsh E:\VCD\03-Configure-Vcd.ps1 -SkipNfsMount
#>
param(
    [string] $VcdIp      = '192.168.114.60',
    [string] $VcdRootPw  = 'VMware1!VMware1!',
    [string] $NfsServer  = '192.168.114.61',
    [string] $NfsExport  = '/exports/vcd-transfer',
    [string] $NfsMountPt = '/opt/vmware/vcloud-director/data/transfer',
    [switch] $SkipNfsMount
)

$ErrorActionPreference = 'Stop'
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$vcServer = 'vc-mgmt.vmware.taiwan'
$vcUser   = 'administrator@vmwaresso.taiwan'
$vcPw     = '381VMware1!admin'
$vmName   = 'kosten-vcd'

# ---- 等 VCD VM tools ready ----
Write-Host "Connecting $vcServer ..." -ForegroundColor Cyan
Connect-VIServer $vcServer -User $vcUser -Password $vcPw | Out-Null

$vm = Get-VM -Name $vmName -ErrorAction Stop
Write-Host "Waiting for VMware Tools on $vmName ..." -ForegroundColor Cyan
$deadline = (Get-Date).AddMinutes(20)
while ($true) {
    $status = (Get-VM -Name $vmName).ExtensionData.Guest.ToolsStatus
    if ($status -match 'toolsOk|toolsOld') { break }
    if ((Get-Date) -gt $deadline) { Write-Error "Timeout waiting for VMware Tools on $vmName." }
    Write-Host "  ... tools=$status ($('{0:mm}:{0:ss}' -f ($deadline - (Get-Date))) remaining)" -ForegroundColor DarkGray
    Start-Sleep 15
}
Write-Host "  Tools ready." -ForegroundColor Green

# ---- 確認 VCD appliance 可以 ping ----
Write-Host "Checking network ($VcdIp) ..." -ForegroundColor Cyan
$reach = Test-Connection $VcdIp -Count 2 -Quiet -ErrorAction SilentlyContinue
if (-not $reach) { Write-Warning "$VcdIp 還 ping 不到, 繼續等 firstboot..." }
else             { Write-Host "  $VcdIp reachable." -ForegroundColor Green }

# ---- NFS mount via VMScript ----
if (-not $SkipNfsMount) {
    Write-Host ""
    Write-Host "Mounting NFS transfer storage via VMScript ..." -ForegroundColor Cyan

    $cred = [PSCredential]::new('root', (ConvertTo-SecureString $VcdRootPw -AsPlainText -Force))

    # 1. 確認 nfs-utils 已裝 (PhotonOS: tdnf)
    $installNfs = @'
which mount.nfs >/dev/null 2>&1 || tdnf install -y nfs-utils
'@
    Invoke-VMScript -VM $vm -ScriptText $installNfs -GuestCredential $cred -ScriptType Bash | Out-Null
    Write-Host "  nfs-utils checked." -ForegroundColor DarkGray

    # 2. mkdir + mount
    $mountScript = @"
mkdir -p '$NfsMountPt'
chown vcloud:vcloud '$NfsMountPt' 2>/dev/null || true
mount -t nfs -o rw,sync '$NfsServer`:$NfsExport' '$NfsMountPt'
"@
    $res = Invoke-VMScript -VM $vm -ScriptText $mountScript -GuestCredential $cred -ScriptType Bash
    Write-Host "  Mount output: $($res.ScriptOutput)" -ForegroundColor DarkGray

    # 3. 驗證 mount 成功
    $verify = Invoke-VMScript -VM $vm -ScriptText "df -h '$NfsMountPt'" -GuestCredential $cred -ScriptType Bash
    Write-Host "  df: $($verify.ScriptOutput)" -ForegroundColor DarkGray

    # 4. 加 /etc/fstab (idempotent)
    $fstabLine = "$NfsServer`:$NfsExport $NfsMountPt nfs rw,sync 0 0"
    $fstabScript = @"
grep -qF '$NfsServer`:$NfsExport' /etc/fstab || echo '$fstabLine' >> /etc/fstab
"@
    Invoke-VMScript -VM $vm -ScriptText $fstabScript -GuestCredential $cred -ScriptType Bash | Out-Null
    Write-Host "  /etc/fstab updated (idempotent)." -ForegroundColor DarkGray

    Write-Host "  NFS mount done: $NfsServer`:$NfsExport -> $NfsMountPt" -ForegroundColor Green
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null

# ---- 後續 wizard 指引 ----
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  VCD 10.6.1 初始設定 Wizard (手動)" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "URL: https://$VcdIp/cloud" -ForegroundColor Yellow
Write-Host "     (如果 redirect 到 /ui/login, 這是 VCD UI; 繼續即可)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Wizard 步驟:" -ForegroundColor Yellow
Write-Host "  1. System Name     : kosten-vcd (或自訂)"
Write-Host "  2. Credentials     : admin 帳號 + 密碼 (建議 VMware1!VMware1!)"
Write-Host "  3. Transfer Storage: $NfsServer`:$NfsExport"
Write-Host "     (VCD 會自動偵測到已 mount 的路徑)"
Write-Host "  4. License key     : 可先跳過 (eval mode 30天)"
Write-Host "  5. Email / SMTP    : 可先跳過"
Write-Host ""
Write-Host "Wizard 完成後:" -ForegroundColor Yellow
Write-Host "  VCD UI: https://$VcdIp/ui"
Write-Host "  Admin : admin / (你設的密碼)"
Write-Host ""
Write-Host "接 VCF 5.2.1 (等 bringup 完成後):" -ForegroundColor Yellow
Write-Host "  pwsh E:\VCD\05-Connect-Vcf521.ps1"
