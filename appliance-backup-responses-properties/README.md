# VCD appliance 備份失敗：transfer share 少了 `responses.properties`

依據：VMware Cloud Director **10.6.2** appliance OVA 內的原版腳本（`/opt/vmware/appliance/bin/`）逐行閱讀，以及 lab 10.6.2 transfer share 上的實際檔案。其他 10.x 版本的邏輯應該相近，但沒有逐版比對過。

## 症狀

在 cell 上跑 `/opt/vmware/appliance/bin/create-backup.sh`（或從 VAMI 5480 按 Backup）出現：

```
Invoking Backup utility ...
Using vcloud as default PG DB to backup
cat: /opt/vmware/vcloud-director/data/transfer/responses.properties: No such file or directory
Missing user.certificate.path value in /opt/vmware/vcloud-director/data/transfer/responses.properties. Diagnose the missing HTTP cert file path issue before reattempting the backup creation.
```

## 根因

`create-backup.sh` 會從 NFS transfer share 上的 `responses.properties` 讀出 HTTP 憑證和金鑰的路徑，讀不到就直接結束：

| 行號（10.6.2） | 動作 |
|---|---|
| L64 | `grep user.certificate.path` → 空的就報上面那句錯，結束 |
| L69 | `grep user.key.path` → 空的就報 `Missing user.key.path value ...` |
| L100 | 備份時會把 `responses.properties` 一起打包進 zip |
| L153 | 只能在 `appliance-type` = `primary` 的節點跑 |
| L159 | **這裡才檢查 NFS 有沒有掛載** |

> ⚠️ 讀 `responses.properties` 的檢查（L64）排在「NFS 有沒有掛載」的檢查（L159）**之前**。所以 **NFS 沒掛上也會報同一句錯**，要先排除。

VAMI 的 Backup（`api/backup.py`）也是 ssh 到 primary 跑同一支 `create-backup.sh`，所以 UI 備份一樣會失敗。

### 這個檔是從哪來的

第一次部署 primary 時，`setupvcd.sh`（10.6.2 L210–211）用 `vcloud` 身分把本機的檔案複製到 share：

```
su -l vcloud -s /bin/sh -c "/usr/bin/cp $VCLOUD_HOME/etc/responses.properties $responsefile"
```

所以 **primary 本機 `/opt/vmware/vcloud-director/etc/responses.properties` 還留著一份**，複製回去就好。

常見的消失原因：有人手動刪掉，或搬遷 / 更換 NFS transfer share 時只複製了部分內容。

### 檔案內容（10.6.2，共 8 個 key）

```
user.certificate.path = /opt/vmware/vcloud-director/etc/user.http.pem
user.key.path = /opt/vmware/vcloud-director/etc/user.http.key
user.key.password = <加密>
database.jdbcUrl = jdbc:postgresql://<primary DB IP>:5432/vcloud?...
database.password = <加密>
database.username = vcloud
system.info = <加密金鑰資訊>
system.version = 2
```

> 🔴 **不要手寫這個檔。** 兩個密碼是加密過的，而且要跟 `system.info` 配對。手寫一份或許能讓備份過關，但之後部署 standby / 新 cell（`nfs-setup.sh`、`setup-repmgr-standby.sh`、`update-postgres-db.sh` 都會讀它）或還原備份時會出事。

## 修法（在 primary cell 上用 root 跑）

### 1. 確認 NFS 有掛、share 裡有什麼

```bash
grep transfer /proc/mounts
```
```bash
ls -la /opt/vmware/vcloud-director/data/transfer/
```

- 沒掛，或目錄是空的（連 `appliance-nodes/`、`cells/` 都沒有）→ 問題是 NFS 本身，先修掛載，不要往下做。
- `appliance-nodes/`、`cells/` 都在、只少 `responses.properties` → 繼續。

### 2. 確認是 primary，而且本機那份還在

```bash
cat /opt/vmware/vcloud-director/appliance-type
```
```bash
grep -E '^user\.(certificate|key)\.path' /opt/vmware/vcloud-director/etc/responses.properties
```

第一行要回 `primary`。第二行列出的 `.pem` / `.key` 檔要真的存在（`ls -la` 確認）。

### 3. 複製回 share（跟原廠 `setupvcd.sh` 同一個指令）

```bash
su -l vcloud -s /bin/sh -c "cp /opt/vmware/vcloud-director/etc/responses.properties /opt/vmware/vcloud-director/data/transfer/responses.properties"
```
```bash
chmod 600 /opt/vmware/vcloud-director/data/transfer/responses.properties
```
```bash
ls -la /opt/vmware/vcloud-director/data/transfer/responses.properties
```

應該是 `-rw------- vcloud vcloud`（lab 正常環境的權限就是這樣）。

### 4. 重跑備份

```bash
/opt/vmware/appliance/bin/create-backup.sh
```

成功會產生 `/opt/vmware/vcloud-director/data/transfer/backups/backup-<時間>.zip`。

### 本機那份也不見時的備用來源

| 來源 | 取法 |
|---|---|
| 舊備份 zip（L100 每次都會打包進去） | `unzip -p /opt/vmware/vcloud-director/data/transfer/backups/backup-<時間>.zip responses.properties` |
| standby / 其他 cell | 該節點的 `/opt/vmware/vcloud-director/etc/responses.properties` |

## 附：檢查 appliance 服務

服務名稱取自 10.6.2 appliance 腳本，VAMI 檢查的也是同一批（`api/service.py` 就是跑 `systemctl status`）。

```bash
systemctl status vmware-vcd vpostgres repmgrd appliance-sync.timer vcd_ova_ui nginx --no-pager | grep -E '●|Active:'
```

| 服務 | 用途 | 正常狀態 |
|---|---|---|
| `vmware-vcd` | VCD cell 本體 | active (running) |
| `vpostgres` | 內嵌 PostgreSQL | primary / standby 上 running；`appliance-type` = `cell` 的節點不會跑 |
| `repmgrd` | DB HA 自動容錯移轉 | running；設成手動容錯移轉時 `dead` 是正常的（VAMI 也這樣標註） |
| `appliance-sync.timer` | 節點間同步 | active (waiting) |
| `vcd_ova_ui`、`nginx` | 5480 VAMI 管理介面 | running |

**DB 叢集狀態**（每個節點 Status 都要是 `* running`，只能有一台 `primary`）：

```bash
sudo -i -u postgres /opt/vmware/vpostgres/current/bin/repmgr -f /opt/vmware/vpostgres/current/etc/repmgr.conf cluster show
```

> VAMI 也是跑 `repmgr cluster show`；上面的 binary 路徑與 `-f` 參數是依 `repmgr.conf` 位置推得，找不到指令時用 `find / -name repmgr -type f 2>/dev/null` 找實際位置。

**cell 是否起來**：

```bash
curl -sk https://localhost/api/server_status
```

應回 `Service is up.`（此端點沒有在腳本裡確認過）。沒回就看 log：

```bash
grep -E 'Application Initialization|startup completed|ERROR' /opt/vmware/vcloud-director/logs/cell.log | tail -20
```

**NFS 回應**（備份腳本也是這樣判斷，`ls` 超過 5 秒就當作 NFS 異常）：

```bash
grep transfer /proc/mounts && timeout 5 ls /opt/vmware/vcloud-director/data/transfer/
```

**圖形介面**：`https://<primary IP>:5480`（root 登入），首頁列出所有節點的服務狀態與 DB 叢集角色。

只是要確認能不能備份的話，看 `vpostgres` 在跑、這台是 primary、NFS 有掛就夠了。
