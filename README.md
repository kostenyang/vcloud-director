# chunghwa-vcd

中華電信 **vCloud Director 10.6.1** — 租戶 (Org) VM 網卡切換工具。

把租戶內的 VM 網卡,從「來源 portgroup」切換到「目的 portgroup」。
整個作業**依順序拆成兩個資料夾**,而且是**串接**的 —
Script 1 對 vCenter 建 portgroup 並寫出交接檔,Script 2 讀交接檔來做轉移:

| 順序 | 資料夾 | 作用 |
|------|--------|------|
| 1 | [`01-create-portgroup/`](01-create-portgroup/) | **針對 vCenter**:建立 vDS portgroup,並寫出 JSON 交接檔(PowerCLI) |
| 2 | [`02-import-switch-nic/`](02-import-switch-nic/) | **基於 Script 1 的交接檔**:匯入成 Org VDC Network 並重接 VM 網卡(VCD REST API) |

---

## 目錄

- [運作原理](#運作原理)
- [前置需求](#前置需求)
- [安裝](#安裝)
- [設定](#設定)
- [交接檔 (state)](#交接檔-state)
- [使用流程](#使用流程)
- [Step 2 在 VCD 做的事(自動匯入網路)](#step-2-在-vcd-做的事自動匯入網路)
- [參數說明](#參數說明)
- [檔案結構](#檔案結構)
- [回滾 (Rollback)](#回滾-rollback)
- [疑難排解](#疑難排解)
- [注意事項](#注意事項)

---

## 運作原理

```
   ┌──────────────────────────────┐                 ┌──────────────────────────────┐
   │  01-create-portgroup         │                 │  02-import-switch-nic        │
   │  (PowerCLI,只動 vCenter)     │                 │  (VCD REST API,只動 VCD)    │
   ├──────────────────────────────┤                 ├──────────────────────────────┤
   │ 來源 vDS ─┐                  │  state/          │ 1. 讀交接檔(PG 名/moref/    │
   │           ├▶ 複製 portgroup  │  portgroup-      │    suffix/租戶資訊)         │
   │ 目的 vDS ─┘   設定建立        │  handoff.json    │ 2. System 管理員登入 VCD     │
   │   <來源>-new                 │ ───────────────▶ │ 3. 用交接檔的 moref 建        │
   │   (VLAN/teaming/binding)     │   (交接檔)       │    imported Org VDC 網路      │
   │ ▶ 寫出交接檔                  │                 │ 4. 掃描接在來源網路的 VM      │
   │   ◀── -Rollback 可刪除        │                 │ 5. 重接每張網卡到新網路       │
   └──────────────────────────────┘                 └──────────────────────────────┘
```

- **Script 2 不自己重新探索 portgroup** — 它完全靠 Script 1 寫出的交接檔
  (`state/portgroup-handoff.json`)取得 portgroup 名稱、moref、後綴與租戶資訊。
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
  "vCenter": {                                      // ← Script 1 使用
    "server":             "vcenter.chunghwa.local", // vCenter FQDN
    "sourceVdsName":      "DSwitch-Prod",            // 來源 portgroup 所在的 vDS
    "destinationVdsName": "DSwitch-Prod"             // 目的 portgroup 要建在哪隻 vDS
  },                                                //   (要換另一隻 vDS 就改這裡)
  "vcd": {                                          // ← Script 2 使用(VCD 連線資訊)
    "server":     "vcd.chunghwa.local",     // VCD FQDN
    "apiVersion": "40.0",                   // 10.6.1 固定為 40.0
    "org":        "System",                 // 登入 org,provider 管理員填 System
    "skipCertificateCheck": true            // 自簽憑證設 true
  },
  "tenant": {                               // ← Script 1 讀取後寫進交接檔
    "orgName":    "ChunghwaOrg",             // 租戶 Org 名稱
    "orgVdcName": "ChunghwaOrg-VDC",         // 要匯入網路的 Org VDC 名稱
    "orgVdcId":   null                       // (選填) VDC 的 URN,設了就跳過名稱查詢
  },                                         //   格式:"urn:vcloud:vdc:<uuid>"
  "portGroup": {                            // ← Script 1 使用
    "source":            "PG-Tenant-VLAN100", // 來源 portgroup 名稱
    "destinationSuffix": "-new"               // 目的名稱後綴
  }
}
```

- **Script 1** 讀整份 config(`vCenter` / `tenant` / `portGroup`)。
- **Script 2** 只用 config 的 `vcd` 區段(VCD 連線);其餘資訊全部來自交接檔。
- 帳號密碼**不寫在設定檔**,執行時用 `Get-Credential` 視窗輸入。

---

## 交接檔 (state)

Script 1 建好 portgroup 後,會把結果寫到 `state/portgroup-handoff.json`,
Script 2 就是讀這個檔來做轉移。內容範例:

```json
{
  "schemaVersion": 1,
  "createdAt": "2026-05-14T14:00:00.0000000+08:00",
  "createdBy": "01-create-portgroup/New-DistributedPortGroup.ps1",
  "vCenter": "vcenter.chunghwa.local",
  "sourceVdsName": "DSwitch-Prod",
  "destinationVdsName": "DSwitch-Prod",
  "sourcePortgroup": "PG-Tenant-VLAN100",
  "destinationPortgroup": "PG-Tenant-VLAN100-new",
  "destinationPortgroupMoref": "dvportgroup-1234",
  "destinationSuffix": "-new",
  "vlanId": "100",
  "tenant": { "orgName": "ChunghwaOrg", "orgVdcName": "ChunghwaOrg-VDC" }
}
```

- `state/` 資料夾**不進 git**(含 moref 等環境資訊);由 Script 1 在執行時自動建立。
- Script 2 跑完還會在 `state/` 寫一份 `migration-result.json` 記錄每台 VM 的結果。
- Script 1 `-Rollback` 會一併刪掉交接檔,避免 Script 2 拿到過期資訊。

---

## 使用流程

### 步驟 1 — 針對 vCenter 建立 portgroup 並寫出交接檔

```powershell
# 依 config 建立(來源/目的 vDS 都讀 config)
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1

# 把目的 portgroup 建到「另一隻 vDS」
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -DestinationVdsName "DSwitch-DR"
```

從來源 portgroup 複製所有設定(VLAN、teaming、port binding),在**目的 vDS** 上
建立 `<來源>-new`,並把結果寫到 `state/portgroup-handoff.json`。此步驟**只動 vCenter**。

### 步驟 2 — 基於交接檔匯入租戶並重接 VM 網卡

```powershell
# 先演練:讀交接檔,只列出會被影響的 VM 清單,不做任何變更
pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1 -WhatIf

# 確認清單沒問題後,正式執行
pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1
```

執行內容:

1. 讀取 `state/portgroup-handoff.json`(Script 1 的產出)與 config 的 VCD 連線資訊
2. 以 System 管理員登入 VCD(API 40.0)
3. **自動在指定 Org VDC 匯入網路** — 用交接檔裡的 portgroup moref,
   在租戶端建立「Imported (OPAQUE)」Org VDC Network。
   **不需要先去 VCD UI 手動匯入**(細節見下一節)
4. 輪詢直到網路狀態 `REALIZED` 才往下做(沒 REALIZED 會中止)
5. 掃描該 Org 內所有網卡接在「來源網路」的 VM
6. 改寫每台 VM 的 `networkConnectionSection`,把網卡重接到新網路
   (保留原本的 IP / MAC / IP 配置模式)

最後會印出每台 VM 的成功/失敗結果表,並寫出 `state/migration-result.json`。

---

## Step 2 在 VCD 做的事(自動匯入網路)

> **結論:Step 2 會自己在 Org VDC 把 portgroup 匯入成 Org VDC Network,
> 完全不需要先去 VCD UI 手動操作。**

### 等同於 VCD UI 的哪個動作

Tenant 視角 → **Networking → Networks → New** → Type 選 **「Imported」** →
Backing 選那個 vDS portgroup → Submit。Step 2 把這串動作換成 API 自動做掉。

### 對應的 API 呼叫

對 VCD `/cloudapi/1.0.0/orgVdcNetworks` 送 `POST`,body 大致長這樣:

```json
{
  "name": "PG-Tenant-VLAN100-new",
  "orgVdc": { "id": "urn:vcloud:vdc:<目標 Org VDC>" },
  "networkType": "OPAQUE",
  "backingNetworkId": "dvportgroup-1234",
  "backingNetworkType": "DV_PORTGROUP"
}
```

- `backingNetworkId` 來自交接檔的 `destinationPortgroupMoref`(Script 1 寫的)
- `orgVdc.id` 由 `tenant.orgVdcName`(交接檔裡)解析成 URN
- 送完輪詢 `GET /cloudapi/1.0.0/orgVdcNetworks?filter=name==...` 直到
  `status == REALIZED`,沒 REALIZED 會 throw、不會繼續做 NIC 重接

### 兩種匯入模式的差異(本 script 走的是第一種)

VCD 把 vCenter portgroup 帶進租戶有兩條路,**目前 script 只做第一種**:

| 模式 | VCD UI 對應 | API networkType | 直接掛在 Org VDC? | 共享性 | 本 script |
|------|------------|-----------------|------------------|--------|-----------|
| **Imported (Opaque)** | tenant 內 New Network → **Imported** | `OPAQUE` + `DV_PORTGROUP` backing | ✅ 直接成為 Org VDC Network,VM 可直接接 | 該 portgroup **獨佔**給這個 Org VDC | ✅ **目前用這個** |
| **External Network → Direct** | provider 先建 External Network → tenant New Network → **Direct** | 兩段 API:`externalNetworks` + `orgVdcNetworks(DIRECT)` | ❌ 多一層 External Network | 多個 Org VDC 都能接同一個 External Network | ❌ 沒做 |

兩者結果都能讓 VM 接上那個 portgroup,差在管理層級與是否多租戶共享。
若改天要走 External Network → Direct 那條路,告訴我加 `-NetworkMode` 參數即可。

### 已存在時的行為

Script 2 跑前會先 `GET /cloudapi/1.0.0/orgVdcNetworks?filter=name==<目的網路名>` 檢查,
若該 Org VDC 裡已經有同名網路就**跳過建立**直接進入 NIC 重接 — 所以重複執行是安全的。

---

## 參數說明

### `01-create-portgroup/New-DistributedPortGroup.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | `..\config\config.json` | 設定檔路徑 |
| `-HandoffPath` | `..\state\portgroup-handoff.json` | 要寫出的交接檔路徑 |
| `-SourceVdsName` | `config.vCenter.sourceVdsName` | 來源 portgroup 所在的 vDS |
| `-DestinationVdsName` | `config.vCenter.destinationVdsName` | 目的 portgroup 要建在哪隻 vDS。**要換另一隻 vDS 就用這個** |
| `-Rollback` | — | 回滾:刪除目的 portgroup 與交接檔(見 [回滾](#回滾-rollback)) |
| `-WhatIf` | — | 演練模式,只顯示會做什麼,不實際變更 |

### `02-import-switch-nic/Import-And-Switch-TenantNic.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | `..\config\config.json` | 設定檔路徑(只取 `vcd` 區段) |
| `-HandoffPath` | `..\state\portgroup-handoff.json` | 要讀取的交接檔路徑(Script 1 的產出) |
| `-SourceNetworkName` | 交接檔的 `sourcePortgroup` | 租戶端「來源」Org VDC Network 名稱。當 VCD 裡的網路名稱與 portgroup 名稱不同時用此指定 |
| `-WhatIf` | — | 演練模式,列出受影響 VM 清單但不變更 |

---

## 檔案結構

```
chunghwa-vcd/
├── 01-create-portgroup/
│   └── New-DistributedPortGroup.ps1       # 步驟 1:建 portgroup + 寫交接檔,含 -Rollback
├── 02-import-switch-nic/
│   └── Import-And-Switch-TenantNic.ps1    # 步驟 2:讀交接檔 → 匯入 + 重接網卡
├── lib/
│   └── VcdRest.ps1                        # VCD REST API 共用函式
│                                          #   Connect-VcdApi / Invoke-VcdOpenApi
│                                          #   Invoke-VcdLegacyApi / Get-VcdQuery / Wait-VcdTask
├── config/
│   └── config.json                        # 環境設定(可用 config.local.json 覆蓋)
├── state/                                  # 交接檔目錄(不進 git,執行時自動建立)
│   ├── portgroup-handoff.json             #   Script 1 產出 → Script 2 讀取
│   └── migration-result.json              #   Script 2 產出的執行結果
├── .gitignore
└── README.md
```

---

## 回滾 (Rollback)

### 步驟 1 的回滾 — 刪除建好的 portgroup 與交接檔

```powershell
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -Rollback
```

刪除目的 vDS 上的 `<來源>-new` portgroup,並刪掉 `state/portgroup-handoff.json`。
**安全機制**:若仍有 VM 連在該 portgroup 上,script 會列出 VM 清單並中止 —
請先做步驟 2 的回滾把網卡切回去,再執行此回滾。

### 步驟 2 的回滾 — 把網卡切回原網路

```powershell
# 用 -SourceNetworkName 指定「新網路」當作來源,把網卡反向切回
pwsh ./02-import-switch-nic/Import-And-Switch-TenantNic.ps1 `
     -SourceNetworkName "PG-Tenant-VLAN100-new" -WhatIf
```

> 重接網卡前,建議先用 `-WhatIf` 把受影響 VM 清單(含原 IP)存檔備查。

**完整回滾順序**:先步驟 2 回滾(網卡切回)→ 再步驟 1 回滾(刪 portgroup + 交接檔)。

---

## 疑難排解

| 症狀 | 可能原因 / 處理 |
|------|----------------|
| `Hand-off file not found` | 步驟 2 找不到交接檔;請先跑步驟 1,或用 `-HandoffPath` 指定正確路徑 |
| `登入失敗,沒有取得 access token` | 帳號非 System 管理員;或 `vcd.org` 設錯。provider 管理員 `org` 要填 `System` |
| 憑證錯誤 / SSL 連線失敗 | `config.json` 的 `vcd.skipCertificateCheck` 設 `true`;PowerCLI 端執行 `Set-PowerCLIConfiguration -InvalidCertificateAction Ignore` |
| `Source/Destination vDS not specified` | `config.vCenter.sourceVdsName` / `destinationVdsName` 未填,或用參數指定 |
| `Org VDC not found` | 交接檔裡的 `tenant.orgVdcName` 拼錯,或登入帳號看不到該 VDC |
| `Org VDC '<name>' is ambiguous` | 同 org 內有多個同名 VDC(罕見),或環境特殊。Script 會把所有候選 VDC 連同 URN 印出來;從清單挑對的那個 URN,設成 `tenant.orgVdcId`(格式 `urn:vcloud:vdc:<uuid>`),再重跑步驟 1 → 2 即可跳過名稱查詢 |
| Org VDC Network「未進入 REALIZED」 | VCD 端網路具現化失敗,到 VCD UI 看該網路的錯誤訊息;常見為 moref 對應的 vCenter 不只一個 |
| 回滾步驟 1 被中止 | 目的 portgroup 仍有 VM 連著;先跑步驟 2 的回滾 |
| 某些 VM 重接 `FAIL` | VM 可能鎖定中、vApp 有未完成的 task,或該版本不允許開機狀態下變更;稍後重跑(script 可重複執行,已重接的不受影響) |

---

## 注意事項

- **步驟 2 一定先用 `-WhatIf` 跑過**,確認受影響的 VM 清單。
- 兩支 script 都可**重複執行**:portgroup / Org VDC Network 已存在會跳過;已重接的網卡不會被重複處理。
- Script 2 完全依賴交接檔;若手動改了 portgroup,請重跑 Script 1 讓交接檔同步。
- 重接網卡會**保留原本的 IP / MAC / IP 配置模式**,只改變網卡所連接的網路。
- 匯入網路(imported,DV_PORTGROUP backing)屬 **provider 操作**,務必用 System 帳號。
- 帳密只透過 `Get-Credential` 即時輸入,不落地、不進 git。
- 不同 VCD 小版本的 API 行為偶有差異,建議先在**測試租戶**驗證一台 VM 再大量套用。
