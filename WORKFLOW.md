# 完整操作流程

兩種 VM 接網路情境(直連 OVDC vs 走 vApp Network)分開講。
參數細節 / 元件設計請看 [`README.md`](README.md);密碼處理請看 [`CREDENTIALS.md`](CREDENTIALS.md)。

---

## 兩種情境

| 情境 | VM NIC 怎麼接的 | 用哪幾隻 |
| --- | --- | --- |
| **A. 直連 OVDC** | VM NIC 直接接 Org VDC Network(VCD UI → vApp → NIC 顯示 `ds-10-191-043`) | Build → Step12 → **Step3-V3** |
| **B. 走 vApp Network** | VM NIC 接 vApp 內部的 vApp Network,vApp Network 再 parent 到 OVDC | Build → Step12 → **Step2b → Step2c**(+ Step3-V3 處理混合情境的直連 VM) |

不確定的話到 VCD UI → tenant org → vApp → Networks 看就知道。**也可能混合**(同 tenant 一部分 VM 直連、一部分走 vApp net)。

---

## 0. 一次性準備

```powershell
git clone https://github.com/kostenyang/vcloud-director.git
cd vcloud-director

# PowerCLI
Install-Module VMware.PowerCLI -Scope CurrentUser
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

預設值已 baked 為 chunghwa customer 環境(`tpe-vcha022.vs.local` / `ecloud.cht.com.tw` / `vDS-TPE-Resource` → `vDS-TPE-vcd` / API 39.1)。

---

## 共用前 2 步(不管 A / B 都要做)

### Step 1:產 configorg.json

```powershell
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName 'viqa.qa'
```

- 連 VCD,查目標 tenant 內所有 DIRECT OVDC 網路
- 寫 `config\configorg.json` 帶 sources[]

### Step 2:Phase 1 — 建 -new OVDC(VM 不動)

```powershell
pwsh .\Step12-Import-V3.ps1 -WhatIf      # dry-run
pwsh .\Step12-Import-V3.ps1              # 真跑
```

對每個 source 做三件事(VM 完全不動):
1. vCenter 在 `vDS-TPE-Resource` clone portgroup 到 `vDS-TPE-vcd` 變 `*-new`(uplink 自動 remap)
2. VCD provider 建 `ext-*-new` external network
3. VCD tenant 建 `*-new` DIRECT Org VDC Network

完成後到 VCD UI 確認 `*-new` 三個物件都在。

---

## 情境 A:直連 OVDC 流程

### Step 3-A:切 VM NIC(直接從 OVDC 名換到 OVDC 名)

```powershell
pwsh .\Step3-Switch-V3.ps1 -WhatIf       # dry-run
pwsh .\Step3-Switch-V3.ps1               # 真切
```

對每個 source:
- 找 NIC.network == source OVDC name 的 VM
- 改成 dest OVDC name,PUT
- VM 不用關機,< 1 秒 blip

---

## 情境 B:走 vApp Network 流程(分兩動)

### Step 2b:對 vApp 加新 vApp Network(VM 不動)

```powershell
pwsh .\Step2b-AddVAppNetwork-V1.ps1 -WhatIf
pwsh .\Step2b-AddVAppNetwork-V1.ps1
```

對每個 source:
- 找有 vApp Network parent = source OVDC 的 vApp
- **APPEND** 一個新的 vApp Network 進去:
  - networkName = `<source>-new`(同 dest OVDC 名)
  - ParentNetwork = `<source>-new` OVDC
  - FenceMode = bridged(Direct)
- 舊 vApp Network **保留**,跟新的並存(VM 還沒換到新的,維持服務)

完成後到 VCD UI → vApp → Networks 應該看到原來 vApp net + 新的 `*-new` vApp net **都在**。

### Step 2c:VM NIC 從舊 vApp net 切到新 vApp net

```powershell
pwsh .\Step2c-SwitchVMInVApp-V1.ps1 -WhatIf     # 列每台會切的 VM
pwsh .\Step2c-SwitchVMInVApp-V1.ps1             # 真切
```

對每個 source 在每個 vApp 內:
- 找該 vApp 裡 parent = source OVDC 的 vApp net 名稱清單
- 對 vApp 內每台 VM:
  - 把 NIC.network 在那清單內的,改成新 vApp net 名(`<source>-new`)
  - PUT,wait task
- 舊 vApp net 上 0 VM 後可手動到 VCD UI 刪掉(自由選擇)

### (可選)Step 3-A:如果同 tenant **混合**有直連 OVDC 的 VM

```powershell
pwsh .\Step3-Switch-V3.ps1
```

跑這個處理沒走 vApp net 的那些 VM。Step2c + Step3-V3 不衝突 — Step2c 只動 NIC.network = vApp net 名的;Step3-V3 只動 NIC.network = OVDC 名的。

---

## 各情境完整命令

### 情境 A:全 direct(常見)

```powershell
git pull
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName 'viqa.qa'
pwsh .\Step12-Import-V3.ps1
pwsh .\Step3-Switch-V3.ps1
```

### 情境 B:全 vApp net(常見 — 大部分 production tenant)

```powershell
git pull
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName 'viqa.qa'
pwsh .\Step12-Import-V3.ps1
pwsh .\Step2b-AddVAppNetwork-V1.ps1
pwsh .\Step2c-SwitchVMInVApp-V1.ps1
```

### 情境 C:混合(部分 direct + 部分 vApp net)

```powershell
git pull
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName 'viqa.qa'
pwsh .\Step12-Import-V3.ps1
pwsh .\Step2b-AddVAppNetwork-V1.ps1
pwsh .\Step2c-SwitchVMInVApp-V1.ps1
pwsh .\Step3-Switch-V3.ps1     # 處理剩下直連的 VM
```

---

## 看結果

```powershell
# Phase 1 (Step12)
Get-Content .\state\step12-batch-result.json -Raw | ConvertFrom-Json |
    Select-Object -ExpandProperty results |
    Format-Table source, status, durationSec

# Step2b (vApp Network add)
Get-Content .\state\step2b-batch-result.json -Raw | ConvertFrom-Json |
    Select-Object -ExpandProperty results |
    Format-Table source, status, vappCount

# Step2c (VM NIC switch inside vApp)
$r = Get-Content .\state\step2c-batch-result.json -Raw | ConvertFrom-Json
$r.results | Format-Table source, vmCount, status
$r.results | Where-Object { $_.source -eq 'ds-10-191-043' } |
    Select-Object -ExpandProperty vmResults |
    Format-Table vapp, vm, nicIndexes, status, error -AutoSize

# Step3 (direct OVDC NIC switch)
Get-Content .\state\step3-batch-result.json -Raw | ConvertFrom-Json |
    Select-Object -ExpandProperty results |
    Format-Table source, status, vmCount
```

---

## 換下一個 tenant

```powershell
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName '另一個tenant'
# configorg.json 被新 tenant 內容覆寫,跑同樣的 step 12 / 2b / 2c / 3
```

---

## VM 開機可切

不管走情境 A / B,VM **完全不用關機**:
- vCenter 對 NIC backing 的 reconfigure 是 hot 操作
- IP / MAC / IP 配置模式都保留
- 通常 < 1 秒 blip,TCP 自己 retransmit
- **前提**:source 跟 dest 的 vDS uplinks 接同一條 physical 網路(同 VLAN 跨 vDS 標準情境)

---

## 密碼免每次輸入

每隻 V2+ / Step2b / Step2c 開頭有:

```powershell
$DEFAULT_VCD_USERNAME = ''     # 填這
$DEFAULT_VCD_PASSWORD = ''
```

填了就跳過 prompt。**填過密碼的版本絕不能 `git push`**(見 [CREDENTIALS.md](CREDENTIALS.md))。

防呆:

```powershell
git update-index --assume-unchanged Step12-Import-V3.ps1
git update-index --assume-unchanged Step2b-AddVAppNetwork-V1.ps1
git update-index --assume-unchanged Step2c-SwitchVMInVApp-V1.ps1
git update-index --assume-unchanged Step3-Switch-V3.ps1
```

---

## 反悔 / 回滾

### Step2c / Step3 切錯 → NIC 切回去

對少量 VM,**最快是 VCD UI 一台一台改回 NIC.network**。

或自己寫一個 ad-hoc:

```powershell
# 例:把 ds-10-191-043-new 上的 VM 切回 ds-10-191-043
# Step3-V3 直接吃 -SourceNetworkName,把它當「現在的」當 source
# (此 flag 在 V3 沒了,可用單筆模式 03-switch-nics\Switch-TenantVmNics.ps1)
pwsh .\03-switch-nics\Switch-TenantVmNics.ps1 -SourceNetworkName 'ds-10-191-043-new'
```

### Step2b 加的 vApp net 想刪

確認 0 VM 接這個 vApp net 後,VCD UI → vApp → Networks → 刪。

### Step12 建的 -new OVDC / ext / portgroup 想全砍

確認都 0 VM 後,順序:
1. VCD UI 砍 `*-new` Org VDC Network
2. VCD Provider 砍 `ext-*-new` external network
3. vCenter 砍 `vDS-TPE-vcd` 上的 `*-new` portgroup

---

## 已知踩雷

| 症狀 | 處理 |
| --- | --- |
| `Step2c` 報 `new-vappnet-missing` | Step2b 該 vApp 沒成功 / 沒跑;先補跑 Step2b |
| `Step2b` / `Step2c` PUT 報 400 | 看 console 內 `VCD response:` 那段,VCD 會給具體欄位問題 |
| VM NIC 切完斷網 | source / dest vDS uplinks 沒接同 physical 網路;或 vApp 是 fenced(NAT)非 bridged,vApp net 切過去後 NAT rule 改變 |
| Step2b 加的 vApp net 已存在 | Script 會偵測,印 `skip vApp: dest vApp net already exists`,**不會重建** |
| `git pull` 失敗 fast-forward | 之前有 force-push;`git fetch --all && git reset --hard origin/main` 對齊 |
| VM 鎖定中無法 PUT | 等 VM 的 pending task 完成再重跑(Step2c / Step3 都 idempotent) |

---

## TL;DR

### 走 vApp Network(典型 tenant)

```powershell
git pull
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName 'viqa.qa'
pwsh .\Step12-Import-V3.ps1
pwsh .\Step2b-AddVAppNetwork-V1.ps1
pwsh .\Step2c-SwitchVMInVApp-V1.ps1
```

### 直連 OVDC

```powershell
git pull
pwsh .\Build-SourcesFromOrg-V3.ps1 -OrgName 'viqa.qa'
pwsh .\Step12-Import-V3.ps1
pwsh .\Step3-Switch-V3.ps1
```

VM **不用關機**。
