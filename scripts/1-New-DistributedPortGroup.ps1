<#
.SYNOPSIS
  步驟 1 / 2 - 在 vCenter 的 vDS 上建立「目的端」分散式 portgroup。

.DESCRIPTION
  從來源 portgroup 複製設定 (VLAN、binding、teaming 等),
  建立一個名稱為「來源名稱 + 後綴 (-new)」的新 portgroup。
  這支只動 vCenter,不碰 VCD。建好之後才跑 script 2 匯入租戶。

.PARAMETER ConfigPath
  config.json 路徑,預設為 ..\config\config.json。
  可改用 config.local.json 覆蓋(不會被 git 追蹤)。

.EXAMPLE
  pwsh ./scripts/1-New-DistributedPortGroup.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = "$PSScriptRoot\..\config\config.json"
)

$ErrorActionPreference = 'Stop'

# --- 載入設定 -----------------------------------------------------------
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "讀取設定檔: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$sourcePg = $cfg.portGroup.source
$destPg   = $cfg.portGroup.source + $cfg.portGroup.destinationSuffix
$vdsName  = $cfg.vCenter.vdsName

Write-Host "來源 portgroup : $sourcePg"
Write-Host "目的 portgroup : $destPg"
Write-Host "vDS            : $vdsName"

# --- PowerCLI ------------------------------------------------------------
Import-Module VMware.VimAutomation.Vds -ErrorAction Stop

$viCred = Get-Credential -Message "vCenter 帳密 ($($cfg.vCenter.server))"
$vc = Connect-VIServer -Server $cfg.vCenter.server -Credential $viCred
Write-Host "已連線 vCenter: $($vc.Name)" -ForegroundColor Green

try {
    $vds = Get-VDSwitch -Name $vdsName
    $src = Get-VDPortgroup -VDSwitch $vds -Name $sourcePg

    # VLAN 資訊 (僅作 log,New-VDPortgroup -ReferencePortgroup 會一併複製)
    $vlanCfg = $src.Extensiondata.Config.DefaultPortConfig.Vlan
    Write-Host "來源 VLAN 設定: $($vlanCfg.VlanId)" -ForegroundColor Yellow

    $existing = Get-VDPortgroup -VDSwitch $vds -Name $destPg -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "目的 portgroup '$destPg' 已存在,跳過建立。"
        return
    }

    if ($PSCmdlet.ShouldProcess($destPg, "在 vDS '$vdsName' 上建立 (複製自 '$sourcePg')")) {
        $new = New-VDPortgroup -VDSwitch $vds -Name $destPg -ReferencePortgroup $src
        Write-Host "已建立 portgroup: $($new.Name)" -ForegroundColor Green
        Write-Host "  Key (moref) : $($new.Key)"
        Write-Host "  VLAN        : $($new.Extensiondata.Config.DefaultPortConfig.Vlan.VlanId)"
        Write-Host ""
        Write-Host "下一步: 跑 scripts/2-Import-And-Switch-TenantNic.ps1 匯入租戶並重接網卡。" -ForegroundColor Cyan
    }
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
