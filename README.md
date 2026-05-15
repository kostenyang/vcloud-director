# chunghwa-vcd

中華電信 **vCloud Director 10.6.1** — 租戶 (Org) VM 網卡切換工具。

把租戶內的 VM 網卡,從「來源 portgroup」切換到「目的 portgroup」。
作業**依順序拆成三個資料夾**,後一支吃前一支寫出的交接檔:

| 順序 | 資料夾 | 作用 | 寫出 / 讀取 |
|------|--------|------|------------|
| 1 | [`01-create-portgroup/`](01-create-portgroup/) | **針對 vCenter** 建 vDS portgroup | 寫 `portgroup-handoff.json` |
| 2 | [`02-import-network/`](02-import-network/) | **匯入** 成租戶的 Org VDC Network | 讀 `portgroup-handoff.json`,寫 `network-handoff.json` |
| 3 | [`03-switch-nics/`](03-switch-nics/) | **切換** Org 內 VM 的網卡 | 讀 `network-handoff.json`,寫 `migration-result.json` |

**重點**:Step 2 把 Org / Org VDC 的 URN 都 resolve 好寫進 hand-off,Step 3 直接讀 URN — **不再做名稱查詢、不會踩名稱重複的 ambiguous 問題**。

---

## 目錄

- [運作原理](#運作原理)
- [前置需求](#前置需求)
- [安裝](#安裝)
- [設定](#設定)
- [交接檔 (state)](#交接檔-state)
- [使用流程](#使用流程)
- [處理 Org / VDC 名稱重複](#處理-org--vdc-名稱重複)
- [Step 2 在 VCD 做的事(自動匯入網路)](#step-2-在-vcd-做的事自動匯入網路)
- [參數說明](#參數說明)
- [檔案結構](#檔案結構)
- [回滾 (Rollback)](#回滾-rollback)
- [疑難排解](#疑難排解)
- [注意事項](#注意事項)

---

## 運作原理

```
   ┌─────────────────────┐    ┌──────────────────────┐    ┌─────────────────────┐
   │ 01-create-portgroup │    │ 02-import-network    │    │ 03-switch-nics      │
   │ (PowerCLI / vCenter)│    │ (VCD REST / Provider)│    │ (VCD REST)          │
   ├─────────────────────┤    ├──────────────────────┤    ├─────────────────────┤
   │ 來源 vDS ─┐         │    │ 1. 讀 PG hand-off    │    │ 1. 讀 net hand-off  │
   │           ├▶ 複製 PG │───▶│ 2. resolve Org/VDC   │───▶│   (URN 已就緒)      │
   │ 目的 vDS ─┘  <來源>-new │  │    URN(可override)  │    │ 2. 找接在來源網路   │
   │ ▶寫 PG hand-off     │    │ 3. 建 imported       │    │    的 VM            │
   │ ─Rollback 可刪除     │    │    Org VDC Network   │    │ 3. 改 NIC.network   │
   └─────────────────────┘    │ 4. 寫 net hand-off   │    │    指向新網路       │
                              └──────────────────────┘    │ 4. 寫 result        │
                                                          └─────────────────────┘
```

- **來源 vDS 與目的 vDS 是分開的變數** — 目的 portgroup 可以建在「另一隻 vDS」上。
- 命名規則:**目的名稱 = 來源名稱 + 後綴**(預設 `-new`)。
- **Step 2 與 Step 3 完全脫耦**:Step 2 把所有需要的 URN 寫進 `network-handoff.json`,
  Step 3 直接拿 URN 用,不必再查名稱。
- Step 2 跑成功不代表 Step 3 就會跑(你可以中間停下來,或之後再跑)。

---

## 前置需求

| 項目 | 需求 |
|------|------|
| vCloud Director | 10.6.1(REST API version `40.0`)。較舊環境改 config 的 `vcd.apiVersion` 對應版本(如 `39.1`) |
| portgroup 類型 | vDS **分散式 portgroup**(VCD 匯入網路只支援這種) |
| PowerShell | 7.0 以上 |
| VMware PowerCLI | 步驟 1 需要(`VMware.VimAutomation.Vds` 模組) |
| vCenter 權限 | 在來源/目的 vDS 上讀取與建立 portgroup 的權限 |
| VCD 權限 | **System (provider) 管理員** — 匯入 portgroup 網路屬 provider 操作 |

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
> (已被 `.gitignore` 忽略),所有 script 都會自動優先採用 local 檔。

```jsonc
{
  "vCenter": {                                      // ← Step 1 使用
    "server":             "vcenter.chunghwa.local",
    "sourceVdsName":      "DSwitch-Prod",
    "destinationVdsName": "DSwitch-Prod"
  },
  "vcd": {                                          // ← Step 2 / Step 3 使用
    "server":     "vcd.chunghwa.local",
    "apiVersion": "40.0",                   // 10.6.1 = 40.0
    "org":        "System",                 // provider admin → System
    "skipCertificateCheck": true
  },
  "tenant": {                               // ← Step 1 讀,寫進 PG hand-off
    "orgName":    "ChunghwaOrg",
    "orgVdcName": "ChunghwaOrg-VDC",
    "orgVdcId":   null                      // (選填) URN 直接指定 VDC,跳過名稱查詢
  },                                        //   格式:"urn:vcloud:vdc:<uuid>"
  "portGroup": {                            // ← Step 1 使用
    "source":            "PG-Tenant-VLAN100",
    "destinationSuffix": "-new"
  }
}
```

---

## 交接檔 (state)

`state/` 資料夾不進 git(含 URN/href 等環境資訊),由 script 在執行時自動建立。

### `state/portgroup-handoff.json`(Step 1 寫,Step 2 讀)

```json
{
  "schemaVersion": 1, "createdAt": "2026-05-15T...",
  "vCenter": "...", "sourceVdsName": "...", "destinationVdsName": "...",
  "sourcePortgroup": "PG-Tenant-VLAN100",
  "destinationPortgroup": "PG-Tenant-VLAN100-new",
  "destinationPortgroupMoref": "dvportgroup-1234",
  "destinationSuffix": "-new",
  "vlanId": "100",
  "tenant": { "orgName": "...", "orgVdcName": "...", "orgVdcId": null }
}
```

### `state/network-handoff.json`(Step 2 寫,Step 3 讀)

```json
{
  "schemaVersion": 1, "createdAt": "2026-05-15T...",
  "tenant": {
    "orgName":    "ChunghwaOrg",
    "orgUrn":     "urn:vcloud:org:...",
    "orgHref":    "https://.../api/org/...",
    "orgVdcName": "ChunghwaOrg-VDC",
    "orgVdcUrn":  "urn:vcloud:vdc:..."
  },
  "sourceNetworkName":   "PG-Tenant-VLAN100",
  "destNetworkName":     "PG-Tenant-VLAN100-new",
  "destNetworkUrn":      "urn:vcloud:network:...",
  "destPortgroup":       "PG-Tenant-VLAN100-new",
  "destPortgroupMoref":  "dvportgroup-1234"
}
```

### `state/migration-result.json`(Step 3 寫)

每台 VM 的成功/失敗結果。

---

## 使用流程

### 步驟 1 — 針對 vCenter 建 portgroup

```powershell
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1
# 把目的建到另一隻 vDS:
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -DestinationVdsName "DSwitch-DR"
```

寫出 `state/portgroup-handoff.json`。

### 步驟 2 — 把 portgroup 匯入成 Org VDC Network

```powershell
pwsh ./02-import-network/Import-OrgVdcNetwork.ps1 -WhatIf
pwsh ./02-import-network/Import-OrgVdcNetwork.ps1
```

讀 `portgroup-handoff.json` → 在租戶 Org VDC 建 imported (OPAQUE) Org VDC Network →
寫 `state/network-handoff.json`(含 Org/VDC URN)。

### 步驟 3 — 切換 Org 裡 VM 的網卡

```powershell
pwsh ./03-switch-nics/Switch-TenantVmNics.ps1 -WhatIf   # 先看清單
pwsh ./03-switch-nics/Switch-TenantVmNics.ps1           # 正式跑
```

讀 `network-handoff.json` → 找接在來源網路的 VM → 改 networkConnectionSection 把 NIC 重接到新網路 → 寫 `state/migration-result.json`。

---

## 處理 Org / VDC 名稱重複

當你環境裡很多 tenant 的 org name / VDC name 重複(同名),光靠名稱無法唯一定位 Org VDC。Step 2 提供三種定位方式,**優先順序**:

### 1. `-OrgVdcUrn` 參數(最直接)

```powershell
pwsh ./02-import-network/Import-OrgVdcNetwork.ps1 `
     -OrgVdcUrn 'urn:vcloud:vdc:27d913a4-81d1-4207-ba16-7c6be9a3c869'
```

跳過所有名稱查詢,直接用 URN 鎖定 VDC。

### 2. `tenant.orgVdcId` in `config.json`

config 加上 URN,Step 1 會把它寫進 portgroup hand-off,Step 2 自動採用:

```jsonc
"tenant": {
  "orgName":    "ecloud-stage",
  "orgVdcName": "ecloud-stage",
  "orgVdcId":   "urn:vcloud:vdc:27d913a4-..."
}
```

設定後重跑 Step 1 → Step 2。

### 3. 名稱查詢(fallback)

config 沒設 `orgVdcId` 也沒給 `-OrgVdcUrn` → Step 2 會用 `name + orgName` 查詢。
若仍 ambiguous,Step 2 會把所有候選 VDC 連 URN **印在錯誤訊息裡**,挑對的那個填進
config 或 `-OrgVdcUrn` 即可:

```
Org VDC 'ecloud-stage' is ambiguous in 'ecloud-stage'. Found 2 match(es):

Name         Urn                                               IsEnabled  Href
----         ---                                               ---------  ----
ecloud-stage urn:vcloud:vdc:27d913a4-81d1-4207-ba16-7c6be9a3c869  true   https://...
ecloud-stage urn:vcloud:vdc:abcdef12-...                          true   https://...

Pick the right URN above and either:
  (a) re-run with -OrgVdcUrn 'urn:vcloud:vdc:...', or
  (b) set tenant.orgVdcId in config\config.json and re-run step 1 first.
```

> Step 3 **不需要**任何名稱查詢 — Step 2 已把 URN 寫進 `network-handoff.json`,Step 3 直接讀。

---

## Step 2 在 VCD 做的事(自動匯入網路)

> **結論:Step 2 會自動在 Org VDC 把 portgroup 匯入成 Org VDC Network,
> 不需要先去 VCD UI 手動操作。**

對應 VCD UI 操作:
**Tenant 視角 → Networking → Networks → New** → Type 選 **Imported** →
Backing 選那個 vDS portgroup → Submit

對應 API:`POST /cloudapi/1.0.0/orgVdcNetworks`

```json
{
  "name": "PG-Tenant-VLAN100-new",
  "orgVdc": { "id": "urn:vcloud:vdc:..." },
  "networkType": "OPAQUE",
  "backingNetworkId": "dvportgroup-1234",
  "backingNetworkType": "DV_PORTGROUP"
}
```

送完輪詢直到 `status == REALIZED` 才寫 hand-off,沒 REALIZED 會 throw、不會繼續。

### 已存在時的行為

Step 2 跑前會先 `GET /cloudapi/1.0.0/orgVdcNetworks?filter=name==<目的網路名>` 檢查;
若該 Org VDC 裡已經有同名網路就**跳過建立**,直接用既有網路的 URN 寫進 hand-off。
所以重複執行是安全的。

### 兩種匯入模式(本 script 走第一種)

| 模式 | 描述 | 本 script |
|------|------|-----------|
| **Imported (Opaque)** | tenant 內 New Network → Imported,DV_PORTGROUP backing | ✅ |
| **External Network → Direct** | provider 先建 External Network → tenant 用 Direct 接 | ❌ |

---

## 參數說明

### `01-create-portgroup/New-DistributedPortGroup.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | (auto) | config.json 路徑 |
| `-HandoffPath` | (auto) | 要寫出的 portgroup-handoff.json 路徑 |
| `-SourceVdsName` | `config.vCenter.sourceVdsName` | 來源 portgroup 所在 vDS |
| `-DestinationVdsName` | `config.vCenter.destinationVdsName` | 目的 portgroup 要建在哪隻 vDS |
| `-Rollback` | — | 刪除目的 portgroup 與 hand-off |
| `-WhatIf` | — | 演練 |

### `02-import-network/Import-OrgVdcNetwork.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | (auto) | 只取 `vcd` 區段 |
| `-PortgroupHandoff` | (auto) | 讀:Step 1 hand-off |
| `-NetworkHandoff` | (auto) | 寫:Step 3 要讀的 hand-off |
| `-OrgVdcUrn` | — | 指定 VDC URN,跳過名稱查詢(最高優先) |
| `-WhatIf` | — | 演練 |

### `03-switch-nics/Switch-TenantVmNics.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | (auto) | 只取 `vcd` 區段 |
| `-NetworkHandoff` | (auto) | 讀:Step 2 hand-off(URN 已就緒) |
| `-SourceNetworkName` | hand-off 的 `sourceNetworkName` | 來源網路名稱(回滾時用此反向) |
| `-WhatIf` | — | 演練,列出受影響 VM 不變更 |

---

## 檔案結構

```
chunghwa-vcd/
├── 01-create-portgroup/
│   └── New-DistributedPortGroup.ps1       # Step 1
├── 02-import-network/
│   └── Import-OrgVdcNetwork.ps1           # Step 2(只匯入網路)
├── 03-switch-nics/
│   └── Switch-TenantVmNics.ps1            # Step 3(只切 VM 網卡)
├── lib/
│   └── VcdRest.ps1
├── config/
│   └── config.json
├── state/                                  # 不進 git
│   ├── portgroup-handoff.json             #   Step 1 → Step 2
│   ├── network-handoff.json               #   Step 2 → Step 3
│   └── migration-result.json              #   Step 3 輸出
├── .gitignore
└── README.md
```

> Script 都有 **auto-detect 結構** — 平鋪在同一個工作目錄下也能跑(把 `lib/`、
> `config/` 跟 script 放在同一層即可,例如 `remod\` 全部攤平)。

---

## 回滾 (Rollback)

### Step 3 反向 — 把網卡切回原網路

```powershell
pwsh ./03-switch-nics/Switch-TenantVmNics.ps1 `
     -SourceNetworkName "PG-Tenant-VLAN100-new" -WhatIf
```

### Step 2 — 手動從 VCD 刪掉 imported network

(目前無 `-Rollback`,直接到 VCD UI 或 `DELETE /cloudapi/1.0.0/orgVdcNetworks/<urn>` 處理。)

### Step 1 — 刪掉 portgroup

```powershell
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1 -Rollback
```

刪除目的 portgroup 與 `state/portgroup-handoff.json`。**安全機制**:目的 portgroup 仍有 VM 連著就中止 — 先做 Step 3 反向。

**完整回滾順序**:Step 3 反向 → 刪 imported network → Step 1 -Rollback。

---

## 疑難排解

| 症狀 | 處理 |
|------|------|
| `Hand-off file not found` | Step 2/3 找不到前一支寫的 hand-off;先跑前一步,或用 `-PortgroupHandoff`/`-NetworkHandoff` 指定 |
| `Login failed: no access token` | 帳號非 System 管理員;或 `vcd.org` 設錯。provider admin 要填 `System` |
| `Invalid API version(s) requested` | 你的 VCD 不支援 config 設定的 `vcd.apiVersion`;改成它支援的版本(錯誤訊息會列出來) |
| 憑證錯誤 / SSL 連線失敗 | `config.vcd.skipCertificateCheck = true`;PowerCLI 端 `Set-PowerCLIConfiguration -InvalidCertificateAction Ignore` |
| `Org not found` / `Org name is ambiguous` | orgName 拼錯;org 名稱真的重複(罕見) |
| `Org VDC '<n>' is ambiguous` | 同 org 內多個同名 VDC 或環境特殊。Step 2 會把候選 URN 印出來;用 `-OrgVdcUrn` 或設 config `tenant.orgVdcId` 指定 |
| `Org VDC Network did not reach REALIZED` | VCD 端網路具現化失敗;到 VCD UI 看該網路的錯誤訊息 |
| 回滾 Step 1 被中止 | 目的 portgroup 仍有 VM 連著;先做 Step 3 反向 |
| 某些 VM 重接 `FAIL` | VM 鎖定中、vApp 有未完成 task,或不允許開機狀態變更;稍後重跑(可重複執行) |

---

## 注意事項

- **Step 2 / Step 3 一定先用 `-WhatIf` 跑過**。
- 三支 script 都可**重複執行**:已建的 portgroup / network 會跳過、已重接的 NIC 不會重做。
- Step 3 完全靠 Step 2 寫的 hand-off;若手動改了網路,重跑 Step 2 讓 hand-off 同步。
- 重接網卡會**保留 IP / MAC / IP 配置模式**,只改變網卡所連接的網路。
- 匯入網路屬 **provider 操作**,務必用 System 帳號。
- 帳密只透過 `Get-Credential` 即時輸入,不落地、不進 git。
