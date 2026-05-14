<#
.SYNOPSIS
  步驟 2 / 2 - 把 script 1 建好的 portgroup 匯入成租戶的 Org VDC Network,
  並把該租戶內、原本接在「來源網路」的 VM 網卡重接到新網路。

.DESCRIPTION
  流程:
    1. 以 System 管理員登入 VCD (10.6.1 / API 40.0)
    2. 用 query service 找到新 portgroup 的 moref
    3. 用 OpenAPI 在指定 Org VDC 建立「已匯入 (imported / OPAQUE)」的 Org VDC Network
       目的網路名稱 = 來源網路名稱 + 後綴 (-new)
    4. 找出該 Org 內所有網卡接在「來源網路」的 VM
    5. 透過 legacy API 改寫每台 VM 的 networkConnectionSection,把網卡重接到新網路

  預設為 -WhatIf 演練模式以外的正式執行;先用 -WhatIf 看清單再正式跑。

.PARAMETER ConfigPath
  config.json 路徑,預設 ..\config\config.json (若有 config.local.json 會優先採用)。

.PARAMETER SourceNetworkName
  租戶端「來源」Org VDC Network 名稱。預設取 config 的 portGroup.source。

.EXAMPLE
  pwsh ./scripts/2-Import-And-Switch-TenantNic.ps1 -WhatIf      # 先演練
  pwsh ./scripts/2-Import-And-Switch-TenantNic.ps1             # 正式執行
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = "$PSScriptRoot\..\config\config.json",
    [string] $SourceNetworkName
)

$ErrorActionPreference = 'Stop'

# --- 載入設定與共用函式 -------------------------------------------------
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "讀取設定檔: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

. "$PSScriptRoot\..\lib\VcdRest.ps1"

$orgName  = $cfg.tenant.orgName
$vdcName  = $cfg.tenant.orgVdcName
$destPg   = $cfg.portGroup.source + $cfg.portGroup.destinationSuffix
if (-not $SourceNetworkName) { $SourceNetworkName = $cfg.portGroup.source }
$destNetworkName = $SourceNetworkName + $cfg.portGroup.destinationSuffix

Write-Host "Org              : $orgName"
Write-Host "Org VDC          : $vdcName"
Write-Host "來源網路 (VCD)   : $SourceNetworkName"
Write-Host "目的網路 (VCD)   : $destNetworkName"
Write-Host "目的 portgroup   : $destPg"
Write-Host ""

# --- 登入 VCD -----------------------------------------------------------
$vcdCred = Get-Credential -Message "VCD System 管理員帳密 ($($cfg.vcd.server))"
$session = Connect-VcdApi -Server $cfg.vcd.server -Credential $vcdCred `
    -Org $cfg.vcd.org -ApiVersion $cfg.vcd.apiVersion `
    -SkipCertificateCheck:$cfg.vcd.skipCertificateCheck
Write-Host "已登入 VCD: $($cfg.vcd.server)" -ForegroundColor Green

# --- 1. 找 Org / Org VDC ------------------------------------------------
$orgList = Invoke-VcdLegacyApi -Session $session -Uri '/api/org'
$org = $orgList.OrgList.Org | Where-Object { $_.name -eq $orgName }
if (-not $org) { throw "找不到 Org: $orgName" }
$orgHref = $org.href

$vdcRec = Get-VcdQuery -Session $session -Type 'orgVdc' -Filter "name==$vdcName"
if (-not $vdcRec) { throw "找不到 Org VDC: $vdcName" }
if ($vdcRec.Count -gt 1) { throw "Org VDC 名稱重複: $vdcName,請改用更精確的設定" }
$vdcUuid = ($vdcRec.href -split '/')[-1]
$vdcUrn  = "urn:vcloud:vdc:$vdcUuid"
Write-Host "Org VDC URN: $vdcUrn"

# --- 2. 找新 portgroup 的 moref ----------------------------------------
$pgRec = Get-VcdQuery -Session $session -Type 'portgroup' -Filter "name==$destPg" |
    Where-Object { $_.portgroupType -eq 'DV_PORTGROUP' }
if (-not $pgRec) { throw "找不到 DV portgroup: $destPg (請先跑 script 1)" }
if (@($pgRec).Count -gt 1) { throw "portgroup 名稱重複: $destPg,無法判斷要匯入哪一個" }
$pgMoref = $pgRec.moref
Write-Host "portgroup moref: $pgMoref"

# --- 3. 建立 imported Org VDC Network -----------------------------------
$existingNet = Invoke-VcdOpenApi -Session $session `
    -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$destNetworkName"
if ($existingNet.values | Where-Object { $_.orgVdc.id -eq $vdcUrn }) {
    Write-Warning "Org VDC Network '$destNetworkName' 已存在於 $vdcName,跳過建立。"
}
elseif ($PSCmdlet.ShouldProcess($destNetworkName, "在 $vdcName 建立 imported Org VDC Network (backing: $pgMoref)")) {
    $body = @{
        name               = $destNetworkName
        description        = "Imported from DV portgroup $destPg (建立者: 2-Import-And-Switch-TenantNic.ps1)"
        orgVdc             = @{ id = $vdcUrn }
        networkType        = 'OPAQUE'
        backingNetworkId   = $pgMoref
        backingNetworkType = 'DV_PORTGROUP'
    }
    $null = Invoke-VcdOpenApi -Session $session -Path '/cloudapi/1.0.0/orgVdcNetworks' -Method Post -Body $body

    # 輪詢直到網路出現且 status = REALIZED
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 4
        $check = Invoke-VcdOpenApi -Session $session `
            -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$destNetworkName"
        $net = $check.values | Where-Object { $_.orgVdc.id -eq $vdcUrn }
    } while (-not ($net -and $net.status -eq 'REALIZED') -and (Get-Date) -lt $deadline)

    if (-not ($net -and $net.status -eq 'REALIZED')) {
        throw "Org VDC Network '$destNetworkName' 建立後未進入 REALIZED 狀態,請至 VCD 檢查。"
    }
    Write-Host "已建立 Org VDC Network: $destNetworkName (REALIZED)" -ForegroundColor Green
}

# --- 4. 找出接在來源網路的 VM ------------------------------------------
Write-Host ""
Write-Host "掃描 Org '$orgName' 內接在 '$SourceNetworkName' 的 VM ..." -ForegroundColor Cyan
$vmRecords = Get-VcdQuery -Session $session -Type 'vm' `
    -Filter "isVAppTemplate==false;org==$orgHref"

$targets = New-Object System.Collections.Generic.List[object]
foreach ($vm in $vmRecords) {
    $ncsUri = "$($vm.href)/networkConnectionSection/"
    try {
        $ncs = Invoke-VcdLegacyApi -Session $session -Uri $ncsUri
    } catch {
        Write-Warning "  讀取網卡設定失敗,略過: $($vm.name) - $($_.Exception.Message)"
        continue
    }
    $hit = $ncs.NetworkConnectionSection.NetworkConnection |
        Where-Object { $_.network -eq $SourceNetworkName }
    if ($hit) {
        $targets.Add([pscustomobject]@{
            Name       = $vm.name
            Href       = $vm.href
            Status     = $vm.status
            NicIndexes = ($hit.NetworkConnectionIndex -join ',')
            Section    = $ncs
        })
    }
}

if ($targets.Count -eq 0) {
    Write-Host "沒有任何 VM 接在 '$SourceNetworkName',結束。" -ForegroundColor Yellow
    return
}

Write-Host "找到 $($targets.Count) 台 VM 需要重接:" -ForegroundColor Yellow
$targets | Format-Table Name, Status, NicIndexes -AutoSize

# --- 5. 重接網卡 --------------------------------------------------------
$report = New-Object System.Collections.Generic.List[object]
foreach ($t in $targets) {
    if (-not $PSCmdlet.ShouldProcess($t.Name, "把網卡 [$($t.NicIndexes)] 從 '$SourceNetworkName' 重接到 '$destNetworkName'")) {
        $report.Add([pscustomobject]@{ VM = $t.Name; Result = 'WhatIf - 略過' })
        continue
    }
    try {
        $section = $t.Section
        foreach ($nc in $section.NetworkConnectionSection.NetworkConnection) {
            if ($nc.network -eq $SourceNetworkName) { $nc.network = $destNetworkName }
        }
        $putUri = $section.NetworkConnectionSection.href
        $task = Invoke-VcdLegacyApi -Session $session -Uri $putUri -Method Put `
            -Body ([xml]$section.OuterXml) `
            -ContentType "application/vnd.vmware.vcloud.networkConnectionSection+xml;version=$($session.ApiVersion)"
        Wait-VcdTask -Session $session -TaskHref $task.Task.href | Out-Null
        Write-Host "  OK  $($t.Name)" -ForegroundColor Green
        $report.Add([pscustomobject]@{ VM = $t.Name; Result = '成功' })
    }
    catch {
        Write-Warning "  FAIL $($t.Name): $($_.Exception.Message)"
        $report.Add([pscustomobject]@{ VM = $t.Name; Result = "失敗: $($_.Exception.Message)" })
    }
}

Write-Host ""
Write-Host "===== 執行結果 =====" -ForegroundColor Cyan
$report | Format-Table -AutoSize
