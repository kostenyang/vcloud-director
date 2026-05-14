# chunghwa-vcd

中華電信 **vCloud Director 10.6.1** — 租戶 (Org) VM 網卡切換工具。

把租戶內的 VM 網卡,從「來源 portgroup」切換到「目的 portgroup」。
整個作業**依順序拆成兩個資料夾**:

| 順序 | 資料夾 | 作用 |
|------|--------|------|
| 1 | [`01-create-portgroup/`](01-create-portgroup/) | 在 vCenter 建立目的 portgroup(PowerCLI) |
| 2 | [`02-import-switch-nic/`](02-import-switch-nic/) | 從 VCD 租戶端匯入並重接網卡(VCD REST API) |

---

## 目錄

- [運作原理](#運作原理)
- [前置需求](#前置需求)
- [安裝](#安裝)
- [設定](#設定)
- [使用流程](#使用流程)
- [參數說明](#參數說明)
- [檔案結構](#檔案結構)
- [回滾 (Rollback)](#回滾-rollback)
- [疑難排解](#疑難排解)
- [注意事項](#注意事項)

---

## 運作原理

```
   ┌──────────────────────────────┐      ┌──────────────────────────────┐
   │  01-create-portgroup         │      │  02-import-switch-nic        │
   │  (PowerCLI,只動 vCenter)     │      │  (VCD REST API,只動 VCD)    │
   ├──────────────────────────────┤      ├──────────────────────────────┤
   │ 來源 vDS ─┐                  │      │ 1. System 管理員登入 VCD     │
   │           ├▶ 複製 portgroup  │─────▶│ 2. 找新 portgroup 的 moref   │
   │ 目的 vDS ─┘   設定建立        │      │ 3. 建 imported Org VDC 網路   │
   │   <來源>-new                 │      │ 4. 掃描接在來源網路的 VM      │
   │   (VLAN/teaming/binding)     │      │ 5. 重接每張網卡到新網路       │
   │   ◀── -Rollback 可刪除        │      │   (-WhatIf 可演練)           │
   └──────────────────────────────┘      └──────────────────────────────┘
```

- **來源 vDS 與目的 vDS 是分開的變數** — 目的 portgroup 可以建在「另一隻 vDS」上;
  兩者填一樣就是在同一隻 vDS 內複製。
- 命名規則:**目的名稱 = 來源名稱 + 後綴**(預設 `-new`)。
  例:來源 `PG-Tenant-VLAN100` → 目的 `PG-Tenant-VLAN100-new`,對應的
  Org VDC Network 也叫 `PG-Tenant-VLAN100-new`。

---

## 前置需求

| 項目 | 需求 |
|------|------|
| vCloud Director | 10.6.1(REST API version `40.0`) |
| portgroup 類型 | vDS **分散式 portgroup**(VCD 匯入網路只支援這種) |
| PowerShell | 7.0 以上 |
| VMware PowerCLI | 步驟 1 需要(`VMware.VimAutomation.Vds` 模組) |
| vCenter 權限 | 在來源/目的 vDS 上讀取與建立 portgroup 的權限 |
| VCD 權限 | **System (provider) 管理員** — 匯入 portgroup 網路屬 provider 操作 |
| 網路連線 | 執行機器需能連到 vCenter 與 VCD 的 443 |

---

## 安裝

```powershell
# 1. 取得程式碼
git clone https://github.com/kostenyang/vcloud-director.git
cd vcloud-director

# 2. 安裝 PowerCLI(若尚未安裝)
Install-Module VMware.PowerCLI -Scope CurrentUser

# 3. 自簽憑證環境可關掉 PowerCLI 憑證檢查
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

---

## 設定

編輯 [config/config.json](config/config.json)。

> **建議**:不要把實際環境資訊 commit。複製一份成 `config/config.local.json`
> (已被 `.gitignore` 忽略),兩支 script 都會自動優先採用 local 檔。

```jsonc
{
  "vCenter": {
    "server":             "vcenter.chunghwa.local", // vCenter FQDN
    "sourceVdsName":      "DSwitch-Prod",            // 來源 portgroup 所在的 vDS
    "destinationVdsName": "DSwitch-Prod"             // 目的 portgroup 要建在哪隻 vDS
  },                                                //   (要換另一隻 vDS 就改這裡)
  "vcd": {
    "server":     "vcd.chunghwa.local",     // VCD FQDN
    "apiVersion": "40.0",                   // 10.6.1 固定為 40.0
    "org":        "System",                 // 登入 org,provider 管理員填 System
    "skipCertificateCheck": true            // 自簽憑證設 true
  },
  "tenant": {
    "orgName":    "ChunghwaOrg",             // 租戶 Org 名稱
    "orgVdcName": "ChunghwaOrg-VDC"          // 要匯入網路的 Org VDC 名稱
  },
  "portGroup": {
    "source":            "PG-Tenant-VLAN100", // 來源 portgroup 名稱
    "destinationSuffix": "-new"               // 目的名稱後綴
  }
}
```

帳號密碼**不寫在設定檔**,執行時用 `Get-Credential` 視窗輸入。

---

## 使用流程

### 步驟 1 — 在 vCenter 建立目的 portgroup

```powershell
# 依 config 建立(來源/目的 vDS 都讀 config)
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1

# 把目的 portgroup 建到「另一隻 vDS」
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -DestinationVdsName "DSwitch-DR"
```

從來源 portgroup 複製所有設定(VLAN、teaming、port binding),在**目的 vDS** 上
建立 `<來源>-new`。此步驟**只動 vCenter**。完成後會印出新 portgroup 的 moref 與 VLAN。

### 步驟 2 — 匯入租戶並重接 VM 網卡

```powershell
# 先演練:只列出會被影響的 VM 清單,不做任何變更
pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1 -WhatIf

# 確認清單沒問題後,正式執行
pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1
```

執行內容:

1. 以 System 管理員登入 VCD(API 40.0)
2. 用 query service 找到步驟 1 portgroup 的 moref
3. 在指定 Org VDC 建立「已匯入 (imported / OPAQUE)」的 Org VDC Network
4. 掃描該 Org 內所有網卡接在「來源網路」的 VM
5. 改寫每台 VM 的 `networkConnectionSection`,把網卡重接到新網路
   (保留原本的 IP / MAC / IP 配置模式)

最後會印出每台 VM 的成功/失敗結果表。

---

## 參數說明

### `01-create-portgroup/New-DistributedPortGroup.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | `..\config\config.json` | 設定檔路徑 |
| `-SourceVdsName` | `config.vCenter.sourceVdsName` | 來源 portgroup 所在的 vDS |
| `-DestinationVdsName` | `config.vCenter.destinationVdsName` | 目的 portgroup 要建在哪隻 vDS。**要換另一隻 vDS 就用這個** |
| `-Rollback` | — | 回滾:刪除已建立的目的 portgroup(見 [回滾](#回滾-rollback)) |
| `-WhatIf` | — | 演練模式,只顯示會做什麼,不實際變更 |

### `02-import-switch-nic/Import-And-Switch-TenantNic.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | `..\config\config.json` | 設定檔路徑 |
| `-SourceNetworkName` | `config.portGroup.source` | 租戶端「來源」Org VDC Network 名稱。當 VCD 裡的網路名稱與 portgroup 名稱不同時用此指定 |
| `-WhatIf` | — | 演練模式,列出受影響 VM 清單但不變更 |

---

## 檔案結構

```
chunghwa-vcd/
├── 01-create-portgroup/
│   └── New-DistributedPortGroup.ps1       # 步驟 1:建 portgroup (PowerCLI),含 -Rollback
├── 02-import-switch-nic/
│   └── Import-And-Switch-TenantNic.ps1    # 步驟 2:匯入 + 重接網卡 (VCD REST)
├── lib/
│   └── VcdRest.ps1                        # VCD REST API 共用函式
│                                          #   Connect-VcdApi / Invoke-VcdOpenApi
│                                          #   Invoke-VcdLegacyApi / Get-VcdQuery / Wait-VcdTask
├── config/
│   └── config.json                        # 環境設定(可用 config.local.json 覆蓋)
├── .gitignore
└── README.md
```

---

## 回滾 (Rollback)

### 步驟 1 的回滾 — 刪除建好的 portgroup

```powershell
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -Rollback
```

刪除目的 vDS 上的 `<來源>-new` portgroup。
**安全機制**:若仍有 VM 連在該 portgroup 上,script 會列出 VM 清單並中止 —
請先做步驟 2 的回滾把網卡切回去,再執行此回滾。

### 步驟 2 的回滾 — 把網卡切回原網路

```powershell
# 用 -SourceNetworkName 指定「新網路」當作來源,把網卡反向切回
pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1 `
     -SourceNetworkName "PG-Tenant-VLAN100-new" -WhatIf
```

> 重接網卡前,建議先用 `-WhatIf` 把受影響 VM 清單(含原 IP)存檔備查。

**完整回滾順序**:先步驟 2 回滾(網卡切回)→ 再步驟 1 回滾(刪 portgroup)。

---

## 疑難排解

| 症狀 | 可能原因 / 處理 |
|------|----------------|
| `登入失敗,沒有取得 access token` | 帳號非 System 管理員;或 `vcd.org` 設錯。provider 管理員 `org` 要填 `System` |
| 憑證錯誤 / SSL 連線失敗 | `config.json` 的 `vcd.skipCertificateCheck` 設 `true`;PowerCLI 端執行 `Set-PowerCLIConfiguration -InvalidCertificateAction Ignore` |
| `未指定來源/目的 vDS` | `config.vCenter.sourceVdsName` / `destinationVdsName` 未填,或用參數指定 |
| `找不到 DV portgroup` | 步驟 1 尚未執行,或 portgroup 不在 query 範圍;確認 portgroup 類型是 vDS 分散式 |
| `找不到 Org VDC` | `tenant.orgVdcName` 拼錯,或登入帳號看不到該 VDC |
| Org VDC Network「未進入 REALIZED」 | VCD 端網路具現化失敗,到 VCD UI 看該網路的錯誤訊息;常見為 moref 對應的 vCenter 不只一個 |
| 回滾步驟 1 被中止 | 目的 portgroup 仍有 VM 連著;先跑步驟 2 的回滾 |
| 某些 VM 重接 `FAIL` | VM 可能鎖定中、vApp 有未完成的 task,或該版本不允許開機狀態下變更;稍後重跑(script 可重複執行,已重接的不受影響) |
| `讀取網卡設定失敗,略過` | 該 VM 狀態異常(如 partially powered off);手動檢查後再處理 |

---

## 注意事項

- **步驟 2 一定先用 `-WhatIf` 跑過**,確認受影響的 VM 清單。
- 兩支 script 都可**重複執行**:portgroup / Org VDC Network 已存在會跳過;已重接的網卡不會被重複處理。
- 重接網卡會**保留原本的 IP / MAC / IP 配置模式**,只改變網卡所連接的網路。
- 匯入網路(imported,DV_PORTGROUP backing)屬 **provider 操作**,務必用 System 帳號。
- 帳密只透過 `Get-Credential` 即時輸入,不落地、不進 git。
- 不同 VCD 小版本的 API 行為偶有差異,建議先在**測試租戶**驗證一台 VM 再大量套用。
