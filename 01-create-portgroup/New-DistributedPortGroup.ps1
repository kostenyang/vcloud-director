<#
.SYNOPSIS
  步驟 1 / 2 - 在 vCenter 的 vDS 上建立「目的端」分散式 portgroup。

.DESCRIPTION
  從來源 portgroup 複製設定 (VLAN、binding、teaming 等),
  建立一個名稱為「來源名稱 + 後綴 (-new)」的新 portgroup。

  來源 vDS 與目的 vDS 是「分開的變數」:可以把目的 portgroup 建在
  「另一隻 vDS」上(來源 portgroup 在 A、目的建到 B)。兩者相同時就是
  在同一隻 vDS 上複製。

  這支只動 vCenter,不碰 VCD。建好之後才跑 script 2 匯入租戶。

.PARAMETER ConfigPath
  config.json 路徑,預設 ..\config\config.json(若有 config.local.json 會優先採用)。

.PARAMETER SourceVdsName
  來源 portgroup 所在的 vDS。預設取 config 的 vCenter.sourceVdsName。

.PARAMETER DestinationVdsName
  目的 portgroup 要建在哪一隻 vDS。預設取 config 的 vCenter.destinationVdsName。
  要建到「另一隻 vDS」就用這個參數(或改 config)指定。

.PARAMETER Rollback
  回滾機制:刪除先前建立的「目的 portgroup」。
  若仍有 VM 連在該 portgroup 上會中止,請先用 script 2 把網卡切回去。

.EXAMPLE
  pwsh ./scripts/1-New-DistributedPortGroup.ps1
  # 依 config 建立目的 portgroup

.EXAMPLE
  pwsh ./scripts/1-New-DistributedPortGroup.ps1 -DestinationVdsName "DSwitch-DR"
  # 把目的 portgroup 建到另一隻 vDS「DSwitch-DR」

.EXAMPLE
  pwsh ./scripts/1-New-DistributedPortGroup.ps1 -Rollback
  # 回滾:刪掉建好的目的 portgroup
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $ConfigPath = "$PSScriptRoot\..\config\config.json",
    [string] $SourceVdsName,
    [string] $DestinationVdsName,
    [switch] $Rollback
)

$ErrorActionPreference = 'Stop'

# --- 載入設定 -----------------------------------------------------------
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "讀取設定檔: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# --- 變數:來源/目的 vDS 與 portgroup 名稱 ------------------------------
# 參數優先,其次 config
if (-not $SourceVdsName)      { $SourceVdsName      = $cfg.vCenter.sourceVdsName }
if (-not $DestinationVdsName) { $DestinationVdsName = $cfg.vCenter.destinationVdsName }
if (-not $SourceVdsName)      { throw "未指定來源 vDS(-SourceVdsName 或 config.vCenter.sourceVdsName)" }
if (-not $DestinationVdsName) { throw "未指定目的 vDS(-DestinationVdsName 或 config.vCenter.destinationVdsName)" }

$sourcePg = $cfg.portGroup.source
$destPg   = $cfg.portGroup.source + $cfg.portGroup.destinationSuffix

Write-Host "來源 vDS / portgroup : $SourceVdsName / $sourcePg"
Write-Host "目的 vDS / portgroup : $DestinationVdsName / $destPg"
Write-Host "模式                 : $(if ($Rollback) { 'ROLLBACK(刪除目的 portgroup)' } else { '建立目的 portgroup' })" -ForegroundColor $(if ($Rollback) { 'Magenta' } else { 'White' })

# --- PowerCLI ------------------------------------------------------------
Import-Module VMware.VimAutomation.Vds -ErrorAction Stop

$viCred = Get-Credential -Message "vCenter 帳密 ($($cfg.vCenter.server))"
$vc = Connect-VIServer -Server $cfg.vCenter.server -Credential $viCred
Write-Host "已連線 vCenter: $($vc.Name)" -ForegroundColor Green

try {
    $destVds = Get-VDSwitch -Name $DestinationVdsName

    # ===================== 回滾模式 =====================
    if ($Rollback) {
        $existing = Get-VDPortgroup -VDSwitch $destVds -Name $destPg -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Warning "目的 portgroup '$destPg' 不存在於 vDS '$DestinationVdsName',無需回滾。"
            return
        }

        # 安全檢查:仍有 VM 連著就不刪
        $connectedVms = $existing | Get-VM -ErrorAction SilentlyContinue
        if ($connectedVms) {
            Write-Warning "以下 VM 仍連在 '$destPg',請先用 scripts/2-Import-And-Switch-TenantNic.ps1 把網卡切回去:"
            $connectedVms | Select-Object Name, PowerState | Format-Table -AutoSize
            throw "回滾中止:目的 portgroup 仍有 VM 連接。"
        }

        if ($PSCmdlet.ShouldProcess($destPg, "從 vDS '$DestinationVdsName' 刪除 portgroup")) {
            Remove-VDPortgroup -VDPortgroup $existing -Confirm:$false
            Write-Host "已刪除 portgroup: $destPg(回滾完成)" -ForegroundColor Green
        }
        return
    }

    # ===================== 建立模式 =====================
    $srcVds = Get-VDSwitch -Name $SourceVdsName
    $src    = Get-VDPortgroup -VDSwitch $srcVds -Name $sourcePg

    # VLAN 資訊(僅作 log,New-VDPortgroup -ReferencePortgroup 會一併複製)
    $vlanCfg = $src.Extensiondata.Config.DefaultPortConfig.Vlan
    Write-Host "來源 VLAN 設定: $($vlanCfg.VlanId)" -ForegroundColor Yellow

    $existing = Get-VDPortgroup -VDSwitch $destVds -Name $destPg -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "目的 portgroup '$destPg' 已存在於 vDS '$DestinationVdsName',跳過建立。"
        return
    }

    if ($PSCmdlet.ShouldProcess($destPg, "在 vDS '$DestinationVdsName' 上建立(複製自 '$SourceVdsName/$sourcePg')")) {
        $new = New-VDPortgroup -VDSwitch $destVds -Name $destPg -ReferencePortgroup $src
        Write-Host "已建立 portgroup: $($new.Name)" -ForegroundColor Green
        Write-Host "  vDS         : $DestinationVdsName"
        Write-Host "  Key (moref) : $($new.Key)"
        Write-Host "  VLAN        : $($new.Extensiondata.Config.DefaultPortConfig.Vlan.VlanId)"
        Write-Host ""
        Write-Host "下一步: 跑 scripts/2-Import-And-Switch-TenantNic.ps1 匯入租戶並重接網卡。" -ForegroundColor Cyan
        Write-Host "若要復原: pwsh ./scripts/1-New-DistributedPortGroup.ps1 -Rollback" -ForegroundColor DarkGray
    }
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
