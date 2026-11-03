# Avi（NSX ALB）controller 重裝後，修復 VCD 的 NSX-ALB 設定

| 檔案 | 說明 |
|---|---|
| `vcd_alb_reimport.py` | 盤點 → 信任新憑證 → 刪掉指向舊 UUID 的 SEG / NSX-T Cloud → 依備份匯回新的。只用 Python 3 標準函式庫（3.6 以上），VCD cell 上的 `python3` 就能跑。所有會改東西的動作**預設都是 dry-run**，要加 `--apply` 才會執行。 |

## 症狀

- 刪 controller 時出現：`Cannot delete Load Balancer Controller <名稱> since it has associated Load Balancer Clouds.`
- Controller / NSX-T Clouds / Service Engine Groups 的任何操作都報：`PKIX path building failed ... unable to find valid certification path to requested target`
- 信任新憑證之後，查 SEG 時又報：`Cloud uuid 'cloud-xxxx' does not exist!`

## 根因

controller 重裝之後，**憑證（CA）換了**，Avi 上 **cloud 和 SEG 的 UUID 也全換了**。VCD 存的是：

- controller：URL、帳密、信任的憑證 → 憑證換掉後 VCD 就連不上
- NSX-T Cloud / SEG：Avi 物件的 UUID（`backingId`）→ 重裝後這些 UUID 不存在了

而且 **backing 不能改**（lab 實測）：

| 嘗試 | 結果 |
|---|---|
| `PUT /loadBalancer/clouds/{id}` 改 `backingId` | `cannot have its backing be updated` |
| `PUT /loadBalancer/serviceEngineGroups/{id}` 改 `backingId` | `Unable to change serviceEngineGroupBacking.backingId` |
| 憑證不被信任時刪 SEG | 失敗：VCD 刪除前會先呼叫 Avi（`GET /api/systemconfiguration`） |
| 信任新 CA 後刪 SEG、Cloud（backing 已不存在） | ✅ 刪得掉 |
| 沿用原本的 controller 記錄，重新匯入新 Cloud、SEG | ✅ |

所以正確的順序是：**信任新 CA →（密碼變了就更新 controller）→ 刪舊 SEG → 刪舊 Cloud → 匯入新 Cloud → 匯入新 SEG → Edge Gateway 重新指派 SEG**。controller 記錄不用刪。

## 用法

```bash
export VCD_PASS='<administrator@System 密碼>'
V="--vcd vcd.example.local --controller avi-vip.example.local"

python3 vcd_alb_reimport.py $V status                                   # 1. 盤點（唯讀）
python3 vcd_alb_reimport.py $V trust --ca-pem new-root-ca.pem           # 2. 信任新 CA（先看 dry-run）
python3 vcd_alb_reimport.py $V trust --ca-pem new-root-ca.pem --apply
python3 vcd_alb_reimport.py $V cleanup                                  # 3. 刪舊 SEG / Cloud（先看 dry-run）
python3 vcd_alb_reimport.py $V cleanup --apply                          #    會先寫 vcd-alb-backup-*.json
python3 vcd_alb_reimport.py $V import                                   # 4. 匯入新的 Cloud / SEG
python3 vcd_alb_reimport.py $V import --apply
```

或一次跑完：`python3 vcd_alb_reimport.py $V all --ca-pem new-root-ca.pem --apply`（重複執行是安全的，沒事可做就會跳過）。

| 參數 | 用途 |
|---|---|
| `--ca-pem` | 新的 Root CA（有中繼 CA 就放在同一個檔案裡），一張一張匯入 VCD Trusted Certificates，已經信任的會跳過 |
| `--from-server` | 沒有 CA 檔時，直接信任 controller 目前出示的憑證（等同 UI 跳出的 Trust 視窗），會印出 SHA256 指紋給你核對 |
| `--avi-pass` / `AVI_PASS` | 重裝後 Avi admin 密碼變了才需要；VCD 會先驗證才存，密碼錯了不會把記錄改壞 |
| `--cloud-map "Avi名稱=VCD名稱"` | 新 cloud 對不到舊記錄時手動指定。預設規則：舊的只有一個、新的也只有一個就直接對；否則依名稱對應 |
| `--seg-map "Avi名稱=VCD名稱"` | 同上，用於 SEG。預設依名稱對應（VCD 匯入時預設的名稱就是 Avi 上的名稱） |
| `--workdir` | 備份檔的目錄 |
| `--api-version` | 預設自動偵測（10.6 = 39.2，10.5 = 38.1） |

匯入時，名稱、`description`、`reservationType`（DEDICATED / SHARED）、`supportedFeatureSet`（STANDARD / PREMIUM）都會照舊記錄還原。

## 注意

- **新憑證的 SAN 要包含 controller URL 的主機名**（例如 VIP FQDN）。不包含的話，就算信任了也是 `Failed to connect to Load Balancer Controller`。lab 用 IP 註冊、但 SAN 只有 FQDN 時就是這樣。
- 錯誤是 `validity check failed ... NotBefore` → VCD cell 時鐘比憑證簽發時間慢，要檢查 NTP。
- 從 Trusted Certificates 拿掉憑證後，VCD 已經開著的 TLS 連線還會繼續通一陣子。驗證時要看新連線的結果。
- `cleanup` 只會刪 **backing 已經不存在** 的 SEG / Cloud。backing 還在的不會動。
- 如果 SEG 還**指派給 Edge Gateway**，`cleanup` 會中止並列出是哪些 Edge Gateway。要先在那些 Edge 刪掉 Virtual Service / Pool、移除 SEG 指派，再重跑。**這條路徑沒有在 lab 驗證過**。
- 匯回來之後，原本有用 LB 的 Edge Gateway 要重新指派 SEG。Avi 上新的 Virtual Service 需要重建（重裝後 Avi 上已經沒有了）。

## 驗證環境

2026-11-03：VCD 10.6.2（API 39.2）+ Avi 22.1.5 + NSX 9.1.1（NSX-T cloud、overlay TZ、Geneve network pool）。模擬重裝的方式是：在 Avi 上刪掉 cloud / SEG 再用同名重建（UUID 改變），並把 portal 憑證換成新 CA 簽發的。完整跑過 `status → trust → cleanup → import`、重複執行 `all`、`--from-server`、`--avi-pass`（密碼正確 / 錯誤）。

真正重裝還會換掉 Avi 的 cluster UUID，這點 lab 模擬不到。VCD 的 controller 記錄只存 URL、帳密和憑證，預期不受影響。
