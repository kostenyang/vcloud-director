# 完整操作流程

V3 standalone 三隻為主(repo 根目錄),客戶下載這三個檔即可跑。
參數細節跟元件設計請看 [`README.md`](README.md);密碼處理請看 [`CREDENTIALS.md`](CREDENTIALS.md)。

---

## 三隻主要 script(repo 根目錄)

| 順序 | 檔案 | 作用 |
| --- | --- | --- |
| 1 | [`Build-SourcesFromOrg-V3.ps1`](Build-SourcesFromOrg-V3.ps1) | 查 VCD 目標 tenant,把 DIRECT 網路清單寫進 `config\configorg.json` |
| 2 | [`Step12-Import-V3.ps1`](Step12-Import-V3.ps1) | **Phase 1** — 為每個 source 建 dest portgroup + import 成 Org VDC Network(不切 NIC) |
| 3 | [`Step3-Switch-V3.ps1`](Step3-Switch-V3.ps1) | **Phase 2** — 切 VM NIC 從 source network 到 `<source>-new` |

V3 = V2 + polling 加速(4s → 2s)。V2 / V1 留著當 baseline 不會消失。

---

## 0. 一次性準備

```powershell
git clone https://github.com/kostenyang/vcloud-director.git
cd vcloud-director

# PowerCLI
Install-Module VMware.PowerCLI -Scope CurrentUser
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

預設值已 baked 為 chunghwa customer 環境(`tpe-vcha022.vs.local` / `ecloud.cht.com.tw` / `vDS-TPE-Resource` → `vDS-TPE-vcd` / API 39.1)。其他環境用 `-VcdServer` / `-VCenterServer` / 等等覆寫。

---

## 每個 tenant 三步流程

### Step 1:產 configorg.json

```powershell
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName 'viqa.qa'
```

它會:
1. Prompt VCD 帳密(provider admin,`vcd.org = System`)
2. Resolve `viqa.qa` 的 Org VDC URN
3. Query 該 VDC 內所有 DIRECT 網路(已是 `-new` 結尾的會自動跳過)
4. 寫 [`config\configorg.json`](config/configorg.json),`portGroup.sources[]` 填入清單

**預期輸出**:
```
Sources emitted: 4
Preview:
  - ds-10-191-043  parent=ext-ds-10-191-043
  - ds-10-191-044  parent=ext-ds-10-191-044
  - ds-10-191-045  parent=ext-ds-10-191-045
  - ds-10-191-096  parent=ext-ds-10-191-096
```

要 review / 刪某筆就直接編輯:
```powershell
notepad .\config\configorg.json
```

### Step 2:Phase 1 — 建 portgroup + import 進 org(不切 NIC)

```powershell
# 先 dry-run 看會做什麼(完全不會建)
pwsh .\Step12-Import-V3.ps1 -WhatIf

# 真跑
pwsh .\Step12-Import-V3.ps1
```

**VM 完全不會被動到。VM 還在原本的 source 網路上跑**。

對每個 source(以 ds-10-191-043 為例):
1. step 1:vCenter 在 `vDS-TPE-Resource` 找 `ds-10-191-043` portgroup → clone 到 `vDS-TPE-vcd` 變 `ds-10-191-043-new`(**cross-vDS 自動 remap uplink 名稱,保留 teaming**)
2. step 2:VCD 看 source `ds-10-191-043` (DIRECT) → 讀 `ext-ds-10-191-043` 拿 subnet + vCenter URN → 建 `ext-ds-10-191-043-new` external network → 建 `ds-10-191-043-new` DIRECT Org VDC Network

Console:
```
[1/4] ds-10-191-043  ->  ds-10-191-043-new
  -> step1 (portgroup)...
     portgroup: ds-10-191-043-new  moref=dvportgroup-880273  vlan=2843
  -> step2 (org vdc network)...
  [OK] 12.3s   srcType=DIRECT destNet=DIRECT
```

### Step 3:VCD UI 驗證

切之前必看,確認 phase 1 結果正常:

| 在哪 | 看什麼 |
| --- | --- |
| tenant viqa.qa → Networks | 多 4 個 `*-new` DIRECT 網路,VM count = 0 |
| Provider → External Networks | 多 4 個 `ext-*-new` |
| vCenter vDS-TPE-vcd | 多 4 個 `ds-10-191-*-new` portgroup,VLAN 跟 source 一致 |

不對勁就馬上 rollback(見最下面)。

### Step 4:Phase 2 — 切 VM NIC(真實 migration)

```powershell
# 先 dry-run 看會切哪些 VM
pwsh .\Step3-Switch-V3.ps1 -WhatIf

# 真切
pwsh .\Step3-Switch-V3.ps1
```

對每個 source:
1. 找所有接在 source network 的 VM
2. 改每張匹配的 NIC `.network = <dest>`,PUT 回 VCD
3. 等 task success,記 result

**VM 不用關機。NIC reconfigure 是 vCenter 熱操作,VM 持續跑**:
- IP / MAC / IP 配置模式都**完整保留**
- 通常 < 1 秒內完成(可能掉幾個封包,TCP 自己 retransmit)
- 前提:source 跟 dest 的 underlying vDS uplinks 接同一條 physical 網路(同 VLAN 跨 vDS 的標準情境)

### Step 5:看結果

```powershell
# Phase 1
Get-Content .\state\step12-batch-result.json -Raw | ConvertFrom-Json |
    Select-Object -ExpandProperty results |
    Format-Table source, status, durationSec

# Phase 2 — per-source 統計
Get-Content .\state\step3-batch-result.json -Raw | ConvertFrom-Json |
    Select-Object -ExpandProperty results |
    Format-Table source, status, vmCount, durationSec

# Phase 2 — 看某個 source 內每台 VM 的成敗
$r = Get-Content .\state\step3-batch-result.json -Raw | ConvertFrom-Json
$r.results | Where-Object { $_.source -eq 'ds-10-191-043' } |
    Select-Object -ExpandProperty vmResults |
    Format-Table vm, result, error -AutoSize
```

預期看到每筆 `status = ok`,每台 VM `result = Success`。

### Step 6:換下一個 tenant

```powershell
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName '另一個tenant'
# configorg.json 被新 tenant 內容覆寫

pwsh .\Step12-Import-V3.ps1
# (verify in VCD UI)
pwsh .\Step3-Switch-V3.ps1
```

---

## 怎麼避免每次都輸密碼

兩種方式,詳見 [`CREDENTIALS.md`](CREDENTIALS.md):

### 方式 A:腳本內變數(只在本機填)

每隻 V3 開頭有:

```powershell
# Step12-Import-V3.ps1 (vCenter + VCD 都要)
$DEFAULT_VC_USERNAME  = ''     ← 填這
$DEFAULT_VC_PASSWORD  = ''
$DEFAULT_VCD_USERNAME = ''
$DEFAULT_VCD_PASSWORD = ''

# Build-SourcesFromOrg-V3.ps1 / Step3-Switch-V3.ps1 (只 VCD)
$DEFAULT_VCD_USERNAME = ''
$DEFAULT_VCD_PASSWORD = ''
```

填了就完全靜默不 prompt。

### 方式 B:讓 git 假裝你沒改過(防誤 commit)

```powershell
git update-index --assume-unchanged Step12-Import-V3.ps1
git update-index --assume-unchanged Step3-Switch-V3.ps1
git update-index --assume-unchanged Build-SourcesFromOrg-V3.ps1
```

⚠️ **絕對不要把填過密碼的版本 `git push`**。

---

## 部分執行 / 限筆數

```powershell
# 只跑第一筆(測試水溫)
pwsh .\Step12-Import-V3.ps1 -Limit 1
pwsh .\Step3-Switch-V3.ps1  -Limit 1
```

或編輯 configorg.json 砍掉 sources[] 內不要做的那幾筆。

---

## 反悔 / 回滾

### Phase 2 切錯 → VM NIC 反向切回 source

```powershell
# 用 step 3 v1 的單 source 模式(不用 batch)
pwsh .\03-switch-nics\Switch-TenantVmNics.ps1 -SourceNetworkName 'ds-10-191-043-new'
```

或直接到 VCD UI 一台 VM 一台 VM 把 NIC 改回去(對少量 VM 最快)。

### Phase 1 建錯 → 刪 -new 物件

確認 -new network 上 0 VM 之後:

1. VCD UI → tenant Networks → 刪 `ds-10-191-XXX-new`
2. VCD UI → Provider External Networks → 刪 `ext-ds-10-191-XXX-new`
3. vCenter → vDS-TPE-vcd → 刪 `ds-10-191-XXX-new` portgroup(或用 step 1 `-Rollback`)

---

## 已知踩雷

| 症狀 | 處理 |
| --- | --- |
| `Required script missing: ...v1.X.ps1` | 拉到舊版 wrapper;改用 V3 standalone(`Step12-Import-V3.ps1`),不依賴 wrapper |
| `Cannot validate argument on parameter 'Credential'` | 舊版 Get-Credential GUI 沒回應;V2+ 已改用 Read-Host,`git pull` 拿最新 |
| `Response status code does not indicate success: 400` | V3 已 patch 會印 VCD 完整錯誤訊息,看 `VCD response:` 那段對症處理 |
| `[poll #N] ... not yet visible / status=...` 卡很久 | Polling 中 — 5 分鐘 timeout 後會 throw,看 last status;或到 VCD UI 看 network 真正狀態 |
| 切完 VM 斷網 | source 跟 dest 的 vDS uplinks 沒接同一條 physical 網路;確認兩 vDS 對應 host 接同 VLAN |
| 某些 VM 切 NIC 失敗 | VM 鎖定中 / vApp 有 pending task;等該 task 結束重跑(idempotent),或先 power-off 那幾台 |

---

## TL;DR — 4 行最小流程

```powershell
git pull
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName 'viqa.qa'
pwsh .\Step12-Import-V3.ps1
pwsh .\Step3-Switch-V3.ps1   # 確認 phase 1 後再執行
```

VM 開機狀態都可以做,**不用 power-off**。
