# vcloud-director

vDS portgroup → VCD Org VDC Network → 租戶 VM 網卡的 **三步驟切換工具**,
含**單筆模式**與**批次模式**(讀 vDS export / 比對現況 / 一次跑完幾百個 source)。

| 模式 | 適用 | 入口 |
|------|------|------|
| **單筆** | 一次處理一個 source portgroup;手動編輯 `config.json` 後依序跑 step 1 → 2 → 3 | `01-create-portgroup/` ... `03-switch-nics/` |
| **批次** | 從 vDS 備份 XML 一次產出幾百個 source 清單,自動 diff 現況,只跑該跑的 | `00-build-config/` + `Invoke-MigrationBatch.ps1` |

兩種模式共用同一份 config schema、同一組底層 step 腳本,**不會互相打架**。

---

## 三步驟主流程(兩個模式都走這條)

| 順序 | 資料夾 | 作用 | 寫出 / 讀取 |
|------|--------|------|------------|
| 1 | [`01-create-portgroup/`](01-create-portgroup/) | **針對 vCenter** 建 vDS portgroup | 寫 `portgroup-handoff.json` |
| 2 | [`02-import-network/`](02-import-network/) | **匯入** 成租戶的 Org VDC Network | 讀 PG hand-off,寫 `network-handoff.json` |
| 3 | [`03-switch-nics/`](03-switch-nics/) | **切換** Org 內 VM 的網卡 | 讀 network hand-off,寫 `migration-result.json` |

**核心設計**:Step 2 把 Org / Org VDC 的 URN 都 resolve 好寫進 hand-off,Step 3 直接讀 URN — 不再做名稱查詢、不會踩名稱重複的 ambiguous 問題。

---

## 目錄

- [運作原理](#運作原理)
- [Step 1 / Step 2 的版本變體](#step-1--step-2-的版本變體)
- [批次模式(step 0 + wrapper)](#批次模式step-0--wrapper)
- [前置需求](#前置需求)
- [設定](#設定)
- [交接檔 (state)](#交接檔-state)
- [使用流程 — 單筆模式](#使用流程--單筆模式)
- [使用流程 — 批次模式](#使用流程--批次模式)
- [處理 Org / VDC 名稱重複](#處理-org--vdc-名稱重複)
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
- **Step 2 / Step 3 完全脫耦**:Step 2 把所有需要的 URN 寫進 `network-handoff.json`,Step 3 直接用,不必再查名稱。
- Step 2 跑成功不代表 Step 3 就會跑(可中間停下、之後再跑)。

---

## Step 1 / Step 2 的版本變體

| 路徑 | 適用場景 |
|------|----------|
| [`01-create-portgroup/New-DistributedPortGroup.ps1`](01-create-portgroup/New-DistributedPortGroup.ps1) | **v1.0** — 同 vDS 複製、用 `-ReferencePortgroup`;sourceVds == destVds 場景 |
| [`01-create-portgroup/New-DistributedPortGroup-v1.1.ps1`](01-create-portgroup/New-DistributedPortGroup-v1.1.ps1) | **v1.1** — 跨 vDS 修正版。同 vDS 自動走 v1.0 路徑;跨 vDS 走 raw API 並**按 index 把 source uplink 名稱 remap 到 dest vDS 的 uplink 名稱**(保留 teaming policy 的 active / standby,VM 切換時不斷網)。另含「source 名稱已是 `*-new` 則跳過建立」守門條款 |
| [`01-create-portgroup/New-DistributedPortGroup-v1.2.ps1`](01-create-portgroup/New-DistributedPortGroup-v1.2.ps1) | **v1.2 (推薦)** — 在 v1.1 基礎上加 `-Interactive` switch:讀 `cfg.portGroup.sources[]` 逐筆 prompt `[Y]/[N]/[A]/[Q]` 建 portgroup;寫 `state\step1-batch-result.json` 摘要(不寫 single-source hand-off)。不加 `-Interactive` 時行為跟 v1.1 完全一樣 |
| [`02-import-network/Import-OrgVdcNetwork.ps1`](02-import-network/Import-OrgVdcNetwork.ps1) | **v1** — 固定建 OPAQUE 網路(用 portgroup moref 當 backing) |
| [`02-import-network/Import-OrgVdcNetwork-AutoDetect.ps1`](02-import-network/Import-OrgVdcNetwork-AutoDetect.ps1) | **v2** — **依 source 網路型態自動分支**:source 是 OPAQUE → dest 也建 OPAQUE(同 v1);source 是 DIRECT → 自動到 provider 建 external network → tenant 建 DIRECT 網路 |

兩組變體**輸入 / 輸出 hand-off 完全一致**,可混搭。

---

## 批次模式(step 0 + wrapper)

當你要一次處理幾百個 source(例如從 vDS export 的整批 portgroup),用批次模式:

| 階段 | 腳本 | 作用 | 輸出 |
|------|------|------|------|
| **0a** 產候選 | [`00-build-config/Build-SourcesFromVdsBackup.ps1`](00-build-config/Build-SourcesFromVdsBackup.ps1) | 讀 vDS export 的 `META-INF/data.xml`,套用 filter 產出**候選清單**塞進 `portGroup.sources[]` | `config/config-batch.json` |
| **0b** 比對現況 | [`00-build-config/Compare-MigrationState.ps1`](00-build-config/Compare-MigrationState.ps1) | 連 vCenter + VCD,判斷每個候選**哪些 step 還沒做** | `state/todo.json` |
| **0c** 跑全部 | [`Invoke-MigrationBatch.ps1`](Invoke-MigrationBatch.ps1) | 依 todo 跑 step 1 → 2 → 3,**密碼只 prompt 一次**(全程 cached) | `state/batch-result.json` |

**核心精神:產 JSON → 確認 → script 讀 JSON 跑**(每階段都可單獨 review、單獨重跑)。

### Step 0 的 filter 預設規則

`Build-SourcesFromVdsBackup.ps1` 預設過濾掉這些(都是 infra 網段,不該被當 tenant 資料切過去):

- `type=uplink` 的 portgroup(uplink 物件本身)
- `binding=ephemeral`(通常不是 tenant 資料用)
- 名稱結尾是 `-new`(已被前次 migration 建出來的;suffix 與 `portGroup.destinationSuffix` 對應)
- 名稱含 `FT`(Fault Tolerance logging)
- 名稱含 `VMotion`
- 名稱含 `vtep`(NSX VTEP transport)
- 名稱含 `vsan`(vSAN storage)

可用 `-NamePattern` / `-ExcludePattern` / `-IncludeAllTypes` 覆寫。

### 「重複跳過繼續」如何保證

| 場景 | 處理 |
|------|------|
| dest portgroup 已存在 | step 1 `Write-Warning "reusing it"` + 寫 hand-off → wrapper 視同成功,繼續 step 2/3 |
| dest Org VDC Network 已存在 | step 2 `Write-Warning "skipping creation"` + 用既有 URN 寫 hand-off → 繼續 step 3 |
| source 名字本身是 `*-new`(前次已 migrate 完) | step 1 v1.1 早退、不寫 hand-off → wrapper 偵測到 → 記 `skipped-after-step1` → 進下一個 source |
| Compare 之前就判斷該 source 全做完 | `todo.pending[]` 直接不放這筆 |
| 任一 step throw 真錯誤 | wrapper try/catch → 記 `failed` → 進下一個,不中斷整批 |

---

## 前置需求

| 項目 | 需求 |
|------|------|
| vCloud Director | 10.6.1(REST API version `40.0`)或 10.5.x(`39.1`)。改 `config.vcd.apiVersion` |
| portgroup 類型 | vDS **分散式 portgroup**(VCD 匯入網路只支援這種) |
| PowerShell | 7.0 以上 |
| VMware PowerCLI | 步驟 1 需要(`VMware.VimAutomation.Vds` 模組) |
| vCenter 權限 | 在來源/目的 vDS 上讀取與建立 portgroup 的權限 |
| VCD 權限 | **System (provider) 管理員**(批次 wrapper 預設假設 vCenter / VCD 同帳號;若異,加 `-SeparateCredentials`) |

---

## 設定

編輯 [config/config.json](config/config.json)。

> **建議**:不要把實際環境資訊 commit。複製一份成 `config/config.local.json`(已被 `.gitignore` 忽略),所有 script 都會自動優先採用 local 檔。

```jsonc
{
  "vCenter": {
    "server":             "tpe-vcha022.vs.local",
    "sourceVdsName":      "vDS-TPE-Resource",
    "destinationVdsName": "vDS-TPE-vcd"
  },
  "vcd": {
    "server":     "ecloud.cht.com.tw",
    "apiVersion": "39.1",                     // VCD 10.5 = 39.1;10.6.1 = 40.0
    "org":        "System",
    "skipCertificateCheck": true
  },
  "tenant": {
    "orgName":    "ecloud-stage",
    "orgVdcName": "ecloud-stage"
    // "orgVdcId":   "urn:vcloud:vdc:..."     // 選填,直接指定 VDC URN
  },
  "portGroup": {
    "source":            "ds-10-190-000",     // 單筆模式用
    "destinationSuffix": "-new"
  }
}
```

批次模式會在 `portGroup` 下新增 `sources[]` 陣列(`Build-SourcesFromVdsBackup.ps1` 自動產出),`portGroup.source` 會被自動填為 `sources[0]` 讓 v1.1 / v2 在「直接讀 config-batch.json」時也能跑出第一個 source。

---

## 交接檔 (state)

`state/` 資料夾不進 git(含 URN/href 等環境資訊),由 script 在執行時自動建立。

### `state/portgroup-handoff.json`(Step 1 寫,Step 2 讀)

```json
{
  "schemaVersion": 1, "createdAt": "2026-05-26T...",
  "vCenter": "...", "sourceVdsName": "...", "destinationVdsName": "...",
  "sourcePortgroup": "ds-10-190-000",
  "destinationPortgroup": "ds-10-190-000-new",
  "destinationPortgroupMoref": "dvportgroup-1234",
  "destinationSuffix": "-new",
  "vlanId": "2500",
  "tenant": { "orgName": "...", "orgVdcName": "...", "orgVdcId": null }
}
```

### `state/network-handoff.json`(Step 2 寫,Step 3 讀)

```json
{
  "schemaVersion": 1, "createdAt": "2026-05-26T...",
  "tenant": {
    "orgName":    "ecloud-stage",
    "orgUrn":     "urn:vcloud:org:...",
    "orgHref":    "https://.../api/org/...",
    "orgVdcName": "ecloud-stage",
    "orgVdcUrn":  "urn:vcloud:vdc:..."
  },
  "sourceNetworkName":     "ds-10-190-000",
  "sourceNetworkType":     "OPAQUE",
  "destNetworkName":       "ds-10-190-000-new",
  "destNetworkType":       "OPAQUE",
  "destNetworkUrn":        "urn:vcloud:network:...",
  "destPortgroup":         "ds-10-190-000-new",
  "destPortgroupMoref":    "dvportgroup-1234",
  "destExternalNetworkUrn": null
}
```

### `state/todo.json`(批次模式用 / `Compare-MigrationState.ps1` 寫)

```json
{
  "checkedAt": "...", "totalCandidates": 307,
  "alreadyDone": 245, "pendingCount": 62,
  "anomalies": [],
  "pending": [
    { "name": "ds-10-190-013", "vlan": 2513,
      "destPortgroupExists": false, "destNetworkExists": false,
      "sourceVmCount": null,
      "needs": ["step1","step2","step3"] }
  ]
}
```

### `state/batch-result.json`(批次模式 wrapper 寫)

每筆 source 的 status / steps / duration / error。

---

## 使用流程 — 單筆模式

### Step 1 — 建 portgroup

```powershell
# 同 vDS 複製
pwsh ./01-create-portgroup/New-DistributedPortGroup.ps1

# 跨 vDS 推薦用 v1.1(自動 remap uplink names,保留 teaming)
pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.1.ps1
```

### Step 2 — 把 portgroup 匯入成 Org VDC Network

```powershell
# v1 固定走 OPAQUE 路徑
pwsh ./02-import-network/Import-OrgVdcNetwork.ps1 -WhatIf
pwsh ./02-import-network/Import-OrgVdcNetwork.ps1

# v2 依 source 型態自動分支(OPAQUE / DIRECT)
pwsh ./02-import-network/Import-OrgVdcNetwork-AutoDetect.ps1 -WhatIf
pwsh ./02-import-network/Import-OrgVdcNetwork-AutoDetect.ps1
```

### Step 3 — 切換 Org 裡 VM 的網卡

```powershell
pwsh ./03-switch-nics/Switch-TenantVmNics.ps1 -WhatIf   # 先看清單
pwsh ./03-switch-nics/Switch-TenantVmNics.ps1           # 正式跑
```

---

## 使用流程 — 批次模式

```powershell
# Step 0a - 解 vDS export,產候選清單
pwsh ./00-build-config/Build-SourcesFromVdsBackup.ps1
# (預設讀 ../backup/META-INF/data.xml,寫 ../config/config-batch.json)

# Step 0b - 比對現況,產 todo.json
pwsh ./00-build-config/Compare-MigrationState.ps1
# (預設讀 config-batch.json,連 vCenter + VCD,寫 state/todo.json)
# 加 -CheckVms 還會查 source 網路上 VM 數(用來判 step3 是否做完)

# Step 0c - 一鍵全跑(密碼 1 次,自動 dispatch)
pwsh ./Invoke-MigrationBatch.ps1 -WhatIf -Limit 3   # 先 dry-run 看前 3 筆
pwsh ./Invoke-MigrationBatch.ps1 -Limit 3           # 真跑前 3 筆
pwsh ./Invoke-MigrationBatch.ps1                    # 全部
```

`Invoke-MigrationBatch.ps1` 內部會:

1. 預設先跑一次 `Compare-MigrationState.ps1` 更新 todo(`-SkipCompare` 可關掉)
2. **Prompt 一次** vCenter + VCD 帳密(假設同帳號;`-SeparateCredentials` 切兩次)
3. 全域 override `Get-Credential`,所有子腳本拿到 cached cred,不再 prompt
4. 對 `todo.pending[]` 每筆 source:
   - 合成 temp config(複製 config-batch.json + 把 `portGroup.source` 改成當前 source)
   - 清前一筆殘留的 hand-off
   - 按 `needs[]` 跑 step 1 / 2 / 3
   - try/catch — 單筆失敗不中斷整批
5. 寫 `state/batch-result.json`

---

## 處理 Org / VDC 名稱重複

當你環境裡很多 tenant 的 org name / VDC name 重複(同名),光靠名稱無法唯一定位 Org VDC。Step 2 / Compare 都提供三種定位方式,**優先順序**:

1. `-OrgVdcUrn 'urn:vcloud:vdc:...'`(最直接,跳過所有名稱查詢)
2. `config.json` 內加 `tenant.orgVdcId`(Step 1 寫進 PG hand-off,後續自動帶)
3. **名稱查詢**(fallback)— 真的 ambiguous 時 Step 2 / Compare 會把候選 URN 印在錯誤訊息裡,挑對的填回去重跑

> Step 3 **不需要**任何名稱查詢 — Step 2 已把 URN 寫進 hand-off。

---

## 參數說明

### `00-build-config/Build-SourcesFromVdsBackup.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-BackupRoot` | `..\backup` | 解壓後的 vDS export 目錄(需含 `META-INF\data.xml`) |
| `-OutFile` | `..\config\config-batch.json` | 輸出檔 |
| `-TemplateConfig` | `..\config\config.json` | 拿 vCenter / vcd / tenant 區塊的 template |
| `-NamePattern` | `''` | 名稱 include filter(regex,預設不限) |
| `-ExcludePattern` | `-new$\|FT\|VMotion\|vtep\|vsan` | 名稱 exclude filter(regex,case-insensitive) |
| `-IncludeAllTypes` | off | 預設只取 standard/static;加此參數含 uplink + ephemeral |
| `-DestinationSuffix` | `-new` | 寫進輸出 JSON 的 destinationSuffix |

### `00-build-config/Compare-MigrationState.ps1`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | `..\config\config-batch.json` | 候選清單 |
| `-OutFile` | `..\state\todo.json` | 比對結果 |
| `-OrgVdcUrn` | — | 指定 VDC URN,跳過名稱查詢 |
| `-CheckVms` | off | 多查每個 source 網路上 VM 數(用來判 step3 是否做完);多 N 次 VCD round-trip |

### `Invoke-MigrationBatch.ps1`(批次主程式)

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | `.\config\config-batch.json` | 來源 batch config |
| `-SkipCompare` | off | 略過 Compare 直接讀現有 todo.json |
| `-CheckVms` | off | 轉傳給 Compare-MigrationState |
| `-OrgVdcUrn` | — | 轉傳給 Compare-MigrationState |
| `-Limit N` | 0 (全部) | 只跑前 N 筆 pending(測試用) |
| `-WhatIf` | — | 不真的跑 step,只列要做什麼 |
| `-SeparateCredentials` | off | 預設 vCenter / VCD 共用同一組密碼(prompt 1 次);加此參數 prompt 2 次 |

### `01-create-portgroup/New-DistributedPortGroup.ps1` / `-v1.1` / `-v1.2`

| 參數 | 預設 | 說明 |
|------|------|------|
| `-ConfigPath` | (auto) | config.json 路徑 |
| `-HandoffPath` | (auto) | 要寫出的 portgroup-handoff.json 路徑 |
| `-SourceVdsName` | `config.vCenter.sourceVdsName` | 來源 portgroup 所在 vDS |
| `-DestinationVdsName` | `config.vCenter.destinationVdsName` | 目的 portgroup 要建在哪隻 vDS |
| `-Rollback` | — | 刪除目的 portgroup 與 hand-off |
| `-WhatIf` | — | 演練(v1.2 `-Interactive` 同時下會 bypass 互動 prompt) |
| `-Interactive` *(v1.2 only)* | — | 讀 cfg.portGroup.sources[] 逐筆 prompt;寫 step1-batch-result.json,不寫 single-source hand-off |

### `02-import-network/Import-OrgVdcNetwork.ps1` / `-AutoDetect`

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
vcloud-director/
├── Invoke-MigrationBatch.ps1                # 批次主程式
├── 00-build-config/
│   ├── Build-SourcesFromVdsBackup.ps1       # Step 0a - 從 vDS XML 產候選
│   └── Compare-MigrationState.ps1           # Step 0b - 比對現況產 todo
├── 01-create-portgroup/
│   ├── New-DistributedPortGroup.ps1         # Step 1 v1.0 - 同 vDS
│   ├── New-DistributedPortGroup-v1.1.ps1    # Step 1 v1.1 - 跨 vDS uplink remap
│   └── New-DistributedPortGroup-v1.2.ps1    # Step 1 v1.2 - + -Interactive batch (推薦)
├── 02-import-network/
│   ├── Import-OrgVdcNetwork.ps1             # Step 2 v1 - 固定 OPAQUE
│   └── Import-OrgVdcNetwork-AutoDetect.ps1  # Step 2 v2 - 自動 OPAQUE / DIRECT
├── 03-switch-nics/
│   └── Switch-TenantVmNics.ps1              # Step 3
├── lib/
│   └── VcdRest.ps1
├── config/
│   ├── config.json                          # 單筆 template
│   └── config-batch.json                    # 批次 (由 Build-SourcesFromVdsBackup 產出)
├── state/                                    # 不進 git
│   ├── portgroup-handoff.json
│   ├── network-handoff.json
│   ├── migration-result.json
│   ├── todo.json                            # 批次模式
│   └── batch-result.json                    # 批次模式
├── .gitignore
└── README.md
```

> Script 都有 **auto-detect 結構** — 平鋪在同一個工作目錄下也能跑(把 `lib/`、`config/` 跟 script 放在同一層即可)。

---

## 回滾 (Rollback)

### Step 3 反向 — 把網卡切回原網路

```powershell
pwsh ./03-switch-nics/Switch-TenantVmNics.ps1 `
     -SourceNetworkName "ds-10-190-000-new" -WhatIf
```

### Step 2 — 手動從 VCD 刪掉 imported network

(目前無 `-Rollback`,直接到 VCD UI 或 `DELETE /cloudapi/1.0.0/orgVdcNetworks/<urn>` 處理。)

### Step 1 — 刪掉 portgroup

```powershell
pwsh ./01-create-portgroup/New-DistributedPortGroup-v1.1.ps1 -Rollback
```

刪除目的 portgroup 與 `state/portgroup-handoff.json`。**安全機制**:目的 portgroup 仍有 VM 連著就中止 — 先做 Step 3 反向。

**完整回滾順序**:Step 3 反向 → 刪 imported network → Step 1 -Rollback。

---

## 疑難排解

| 症狀 | 處理 |
|------|------|
| `Hand-off file not found` | Step 2/3 找不到前一支寫的 hand-off;先跑前一步,或用 `-PortgroupHandoff`/`-NetworkHandoff` 指定 |
| `Login failed: no access token` | 帳號非 System 管理員;或 `vcd.org` 設錯。Provider admin 要填 `System` |
| `Invalid API version(s) requested` | VCD 不支援 config 設定的 `vcd.apiVersion`;改為它支援的版本(錯誤訊息會列) |
| 憑證錯誤 / SSL 連線失敗 | `config.vcd.skipCertificateCheck = true`;PowerCLI 端 `Set-PowerCLIConfiguration -InvalidCertificateAction Ignore` |
| `Org not found` / `Org name is ambiguous` | orgName 拼錯;org 名稱真的重複(罕見) |
| `Org VDC '<n>' is ambiguous` | 同 org 內多個同名 VDC;用 `-OrgVdcUrn` 或設 `tenant.orgVdcId` 鎖定 |
| `Org VDC Network did not reach REALIZED` | VCD 端網路具現化失敗;到 VCD UI 看該網路的錯誤訊息 |
| `Cannot specify orgVdc for network creation` | 舊版 step 2 用 `orgVdc.id`;新版用 `ownerRef.id` — 拉最新 main |
| `spec.uplinkTeamingPolicy.uplinkPortOrder.activeUplinkPort. Uplink 1 is not valid` | 跨 vDS 用了 v1.0;改用 [v1.1](01-create-portgroup/New-DistributedPortGroup-v1.1.ps1),會 remap uplink 名稱保留 teaming |
| 切過去 VM 斷網 | 不應該發生 — v1.1 已保留 teaming policy。若真的斷,檢查 dest vDS 上有對應 uplink、active uplink 上 host vmnic 是 linked |
| 回滾 Step 1 被中止 | 目的 portgroup 仍有 VM 連著;先做 Step 3 反向 |
| 某些 VM 重接 `FAIL` | VM 鎖定中、vApp 有未完成 task,或不允許開機狀態變更;稍後重跑(可重複執行) |
| 批次跑到一半失敗 | 看 `state/batch-result.json` 的 `failed` / `skipped`;重跑 `Invoke-MigrationBatch.ps1`(Compare 會自動把已做完的剔除) |

---

## 注意事項

- **第一次跑 / 任何 step 都建議先用 `-WhatIf`** 演練。
- 三支 step + 批次 wrapper 都可**重複執行**:已建的 portgroup / network 會 reuse、已重接的 NIC 不會重做。
- Step 3 完全靠 Step 2 寫的 hand-off;若手動改了網路,重跑 Step 2 讓 hand-off 同步。
- 重接網卡會**保留 IP / MAC / IP 配置模式**,只改變網卡所連接的網路。
- 匯入網路屬 **provider 操作**,務必用 System 帳號。
- 帳密只透過 `Get-Credential` 即時輸入,不落地、不進 git。批次 wrapper 在記憶體 cache 一份,跑完即釋放。
