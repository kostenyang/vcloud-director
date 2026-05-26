# 密碼處理原則

V2 系列三隻腳本(`Build-SourcesFromOrg-V2.ps1` / `Step12-Import-V2.ps1` /
`Step3-Switch-V2.ps1`)取得 vCenter / VCD 帳密的方式,從**安全到方便**有三層:

| 等級 | 方式 | 適合 | 風險 |
| --- | --- | --- | --- |
| 🟢 安全 | 互動式 prompt(預設) | 一次性 / 偶爾跑 | 無 |
| 🟡 中等 | `$DEFAULT_USERNAME` / `$DEFAULT_PASSWORD` 變數 | 同一台機器頻繁跑 | 密碼明碼在檔案內 |
| 🔴 危險 | 把上面填過密碼的檔 commit 上 git | **不可以做** | 公開外洩 |

---

## 🟢 方式 1:互動式 prompt(預設行為)

什麼都不改,執行時會跳 terminal 內 prompt:

```powershell
pwsh .\Step12-Import-V2.ps1

# console:
# [CRED] Credentials for vCenter (...) AND VCD (...) - one prompt, shared
#   Username: vc_sysadmin13@vc.local
#   Password: ********
```

每次都打一次。密碼**不會落地**任何檔案。

---

## 🟡 方式 2:腳本內變數

3 隻 V2 腳本開頭都有:

```powershell
$DEFAULT_USERNAME = ''
$DEFAULT_PASSWORD = ''
```

兩個都填**真實值**就會跳過 prompt:

```powershell
$DEFAULT_USERNAME = 'vc_sysadmin13@vc.local'
$DEFAULT_PASSWORD = 'YourPassword'
```

執行時 console:

```
[CRED] Using hardcoded credentials from script header (user=vc_sysadmin13@vc.local)
```

**任何一個欄位空 = fallback 回方式 1 的 prompt**。

---

## 🔴 不可以做:把密碼 commit 上 git

填過密碼的 `*.ps1`,**絕對不要**:

```powershell
git add Step12-Import-V2.ps1
git commit -m "..."
git push          # ← 公開 repo 上密碼明文外洩
```

GitHub 公開 repo 的內容會被搜尋引擎跟 bot 爬走,密碼一旦提交即使後續刪除,**歷史紀錄仍永久留存** — 必須去 GitHub Settings 廢掉密碼。

---

## 防呆做法:避免 commit 密碼

### 做法 A:`git update-index --assume-unchanged`(最方便)

告訴 git「假裝這個檔沒被改」,本地填了密碼,git 不會偵測差異:

```powershell
git update-index --assume-unchanged Step12-Import-V2.ps1
git update-index --assume-unchanged Step3-Switch-V2.ps1
git update-index --assume-unchanged Build-SourcesFromOrg-V2.ps1
```

之後 `git status` / `git add .` 都不會把這 3 個檔列出來。

要還原(以後 git pull 才會吃到更新):

```powershell
git update-index --no-assume-unchanged Step12-Import-V2.ps1
```

⚠️ 缺點:`git pull` 上游有更新時會卡住(因 local 有「不應該被忽略」的改動)。需要先 reset 才能 pull。

### 做法 B:另存 `.local.ps1` 副本(更乾淨)

把填過密碼的版本另存:

```powershell
Copy-Item .\Step12-Import-V2.ps1 .\Step12-Import-V2.local.ps1
notepad .\Step12-Import-V2.local.ps1   # 填密碼

# 跑那一份
pwsh .\Step12-Import-V2.local.ps1
```

`.gitignore` 加一行,確保 `.local.ps1` 永遠不被 commit:

```gitignore
*.local.ps1
```

優點:`git pull` 完全不受影響,你的密碼版獨立於 repo 之外。

### 做法 C:環境變數(進階)

如果你想跑 CI / 自動化,別放在檔案,改用 env var。可以小改腳本:

```powershell
$DEFAULT_USERNAME = $env:VCD_USERNAME
$DEFAULT_PASSWORD = $env:VCD_PASSWORD
```

執行前在 shell 設好,腳本不接觸密碼字串:

```powershell
$env:VCD_USERNAME = 'vc_sysadmin13@vc.local'
$env:VCD_PASSWORD = 'YourPassword'
pwsh .\Step12-Import-V2.ps1
# 用完
Remove-Item Env:\VCD_PASSWORD
```

---

## 帳號權限要求

V2 系列三隻都假設**同一組帳號**對 vCenter 跟 VCD 都有效(SSO 整合常見的情境)。

如果 vCenter 跟 VCD 是**不同帳號**:

```powershell
pwsh .\Step12-Import-V2.ps1 -SeparateCredentials
# 會分別 prompt 兩次
```

或者用變數方式時,只能對應其中一邊。要兩邊分別固定就要再小改腳本(分成兩組變數)。

| 系統 | 需要的權限 |
| --- | --- |
| vCenter | 來源 / 目的 vDS 上讀取 + 建立 portgroup 的權限 |
| VCD | **System (provider) 管理員** — 因為腳本要 query 跨 tenant 的 Org VDC、建 external network |

`cfg.vcd.org` 一定要是 `"System"`(走 `/sessions/provider`),**不是** tenant org name。

---

## 已知踩雷

| 症狀 | 原因 / 處理 |
| --- | --- |
| `The argument is null or empty. Provide an argument that is not null or empty` 出現在 Connect-VIServer / Connect-VcdApi | Get-Credential GUI dialog 被 cancel 或環境無 GUI。V2 已改用 `Read-Host`(commit `75bad6d`),pull 最新即可 |
| `VCD login 401` | 用了 tenant org 帳號但 `vcd.org` 設成 `System`(或反之);或密碼錯 |
| `[CRED] Using hardcoded credentials` 但跑到一半 401 | 變數內密碼錯,或帳號沒 System 管理員權限 |
| 想 reset 不再用變數 | 把 `$DEFAULT_USERNAME`/`$DEFAULT_PASSWORD` 兩行任一個改回 `''` 即可 |

---

## TL;DR

- **生產 / 共用機器:用方式 1**(prompt),什麼都不要動。
- **自己一台機器要常常跑:用方式 2** + 做法 A 或 B 避免誤 commit。
- **絕對不要做的事**:把填過密碼的 `*.ps1` `git push`。
