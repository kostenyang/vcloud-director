# 完整操作流程

step-by-step,涵蓋兩種使用情境(per-tenant 跟 vDS 整批)+ 回滾。
參數細節跟元件設計請看 [`README.md`](README.md)。

---

## 0. 一次性準備

```powershell
git clone https://github.com/kostenyang/vcloud-director.git
cd vcloud-director

# 確保 PowerCLI 在
Install-Module VMware.PowerCLI -Scope CurrentUser
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false

# 修 config\config.json 把 vCenter / VCD 連線資訊填成你的環境
notepad .\config\config.json
```

`config\config.json` 的關鍵欄位:
- `vCenter.server` / `sourceVdsName` / `destinationVdsName`
- `vcd.server` / `apiVersion`(10.5 = `39.1`,10.6.1 = `40.0`)
- `vcd.org` = `"System"`(provider admin 永遠是 System,**不是** tenant 名)

---

## 兩種使用情境

| 情境 | 適合 | 用哪個 generator |
| --- | --- | --- |
| **A. 一次處理一個 tenant** | 規模小、tenant 單獨切換、只搬 DIRECT 網路 | [`Build-SourcesFromOrg.ps1`](00-build-config/Build-SourcesFromOrg.ps1) → `configorg.json` |
| **B. 一次處理整個 vDS 上幾百個 portgroup** | 大規模搬 vDS、跨 tenant、OPAQUE 為主 | [`Build-SourcesFromVdsBackup.ps1`](00-build-config/Build-SourcesFromVdsBackup.ps1) → `config-batch.json` |

兩者底層共用相同 step 1 / 2 / 3 + wrapper,**差別只在 sources[] 從哪來**。

---

## 情境 A:Per-tenant 流程

### A1. 產 configorg.json

```powershell
pwsh .\00-build-config\Build-SourcesFromOrg.ps1 -OrgName 'viqa.qa'
```

Script 會:
1. 跳出輸密碼框(provider admin)
2. resolve `viqa.qa` 的 Org VDC URN
3. 查該 VDC 內所有 DIRECT 網路
4. 寫 [`config\configorg.json`](config/configorg.json),裡面 `portGroup.sources[]` = 該 tenant 的所有 DIRECT 網路名單

預期輸出:

```
Sources emitted: 4
Preview:
  - ds-10-191-043  parent=ext-ds-10-191-043
  - ds-10-191-044  parent=ext-ds-10-191-044
  - ds-10-191-045  parent=ext-ds-10-191-045
  - ds-10-191-096  parent=ext-ds-10-191-096
```

### A2. Review configorg.json

```powershell
Get-Content .\config\configorg.json -Raw | ConvertFrom-Json |
    Select-Object -ExpandProperty portGroup |
    Select-Object -ExpandProperty sources |
    Format-Table name, parentNetworkName, gateway -AutoSize
```

要刪掉某筆就直接手動編輯 sources[]。

### A3. Dry-run 看 batch 會做什麼

```powershell
pwsh .\Invoke-MigrationBatch.ps1 -ConfigPath .\config\configorg.json -All -WhatIf
```

不會建任何東西,只列每個 source 會經過哪些 step。

### A4. 真跑

```powershell
pwsh .\Invoke-MigrationBatch.ps1 -ConfigPath .\config\configorg.json -All
```

**只輸一次密碼**(vCenter + VCD 共用),然後 wrapper 對每個 source 跑 step 1 → 2 → 3:

| Step | 對 `ds-10-191-043` 做什麼 |
| --- | --- |
| 1 | 在 `vDS-TPE-Resource` 找 portgroup `ds-10-191-043` → clone 到 `vDS-TPE-vcd` 變成 `ds-10-191-043-new`,**保留 teaming policy(uplink 自動 remap)** |
| 2 v2 | VCD 找 source `ds-10-191-043`(DIRECT)→ 讀 parent `ext-ds-10-191-043` → **建新 ext network `ext-ds-10-191-043-new`**(用 step 1 的新 portgroup 當 backing)→ **建新 DIRECT 網路 `ds-10-191-043-new`** 指向新 ext |
| 3 | 找接在 `ds-10-191-043` 的 VM,把 NIC 切到 `ds-10-191-043-new`,**保留 IP / MAC** |

### A5. 看結果

```powershell
Get-Content .\state\batch-result.json -Raw | ConvertFrom-Json |
    Select-Object -ExpandProperty results |
    Format-Table source, status, durationSec, message
```

預期看到每筆 `status = ok`。

### A6. 換下一個 tenant

```powershell
pwsh .\00-build-config\Build-SourcesFromOrg.ps1 -OrgName '另一個tenant'
# configorg.json 被新 tenant 內容覆寫

pwsh .\Invoke-MigrationBatch.ps1 -ConfigPath .\config\configorg.json -All
```

---

## 情境 B:vDS 整批流程

### B1. 解壓 vDS export 到 `.\backup\`

`.\backup\META-INF\data.xml` + `.\backup\data\dvportgroup-*.bak`(.bak 不會被讀)

### B2. 產 config-batch.json

```powershell
pwsh .\00-build-config\Build-SourcesFromVdsBackup.ps1
```

預設過濾 `-new$` / `FT` / `VMotion` / `vtep` / `vsan`,只收 standard/static 的。

### B3. Diff 現況產 todo.json

```powershell
pwsh .\00-build-config\Compare-MigrationState.ps1
# 加 -CheckVms 才會查 step3 是否做完
```

`state\todo.json` 顯示哪些 source 缺 step1 / step2 / step3。

### B4. Batch wrapper 一鍵跑

```powershell
# 先 dry-run + 限制只跑前 3 個
pwsh .\Invoke-MigrationBatch.ps1 -WhatIf -Limit 3

# 真跑前 3 個確認流程
pwsh .\Invoke-MigrationBatch.ps1 -Limit 3

# 全跑(剩下 ~300 個)
pwsh .\Invoke-MigrationBatch.ps1
```

`Invoke-MigrationBatch.ps1` 預設讀 `config-batch.json`,自動跑 Compare 再 dispatch step 1+2+3。

---

## 三種「停下來逐筆確認」的選項

| 場景 | 命令 |
| --- | --- |
| 整個 batch 每筆都要按 [Y]/[N]/[A]/[Q] | `Invoke-MigrationBatch.ps1 -ConfigPath ... -Interactive` |
| **只跑 step 1 的 batch + 逐筆問** | `New-DistributedPortGroup-v1.3.ps1 -ConfigPath ... -Interactive` |
| 只跑 step 1 的 batch + 全自動不問 | `New-DistributedPortGroup-v1.3.ps1 -ConfigPath ... -All` |

---

## Hand-off 與 state 檔

```
state/
├── portgroup-handoff.json    # step 1 寫,step 2 讀(per-source,跑下一筆會被覆寫)
├── network-handoff.json      # step 2 寫,step 3 讀(同上)
├── migration-result.json     # step 3 寫
├── todo.json                 # Compare 寫,wrapper 讀(批次模式)
├── step1-batch-result.json   # v1.3 -Interactive / -All 寫(只 step 1 batch)
└── batch-result.json         # Invoke-MigrationBatch 寫(整批 step 1+2+3)
```

跑完任何 batch 模式都先看對應的 `*-result.json`。

---

## 回滾

### 整體建議順序:**Step 3 反向 → 刪 imported network → Step 1 -Rollback**

```powershell
# Step 3 反向 — 把 VM 切回 source
pwsh .\03-switch-nics\Switch-TenantVmNics.ps1 -SourceNetworkName 'ds-10-191-043-new' -WhatIf
pwsh .\03-switch-nics\Switch-TenantVmNics.ps1 -SourceNetworkName 'ds-10-191-043-new'

# Step 2 反向 — 手動到 VCD UI 刪 imported network(腳本沒做)
# 或 API:DELETE /cloudapi/1.0.0/orgVdcNetworks/<urn>

# Step 1 反向 — 刪掉新建的 portgroup
pwsh .\01-create-portgroup\New-DistributedPortGroup-v1.3.ps1 -Rollback
# (該 portgroup 上還有 VM 連著會被擋住,先做 step 3 反向)
```

---

## viqa.qa 4 個 DIRECT 最快路徑

```powershell
git pull                                                                    # 拿最新 script
pwsh .\00-build-config\Build-SourcesFromOrg.ps1 -OrgName 'viqa.qa'         # 產 configorg.json
notepad .\config\configorg.json                                            # 看一下對不對
pwsh .\Invoke-MigrationBatch.ps1 -ConfigPath .\config\configorg.json -All -WhatIf   # dry-run
pwsh .\Invoke-MigrationBatch.ps1 -ConfigPath .\config\configorg.json -All  # 真跑
Get-Content .\state\batch-result.json -Raw | ConvertFrom-Json | Select results -Expand | ft   # 看結果
```

需要再加 `-Interactive` 改成逐筆問就好。
