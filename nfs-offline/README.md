# NFS Server 離線安裝 (Ubuntu 22.04 / amd64)

不需要網路就能在離線機器上裝好 NFS server。流程分兩階段:**線上打包 → 離線安裝**。

## 套件清單
- `nfs-kernel-server` — NFS server 本體
- `nfs-common` — 共用工具 (含 client)
- `rpcbind` — portmapper
- `keyutils` — kerberos/idmap 相依

(相依套件由 `apt-get --download-only` 自動一起抓下來)

## 階段一:在「有網路的 Ubuntu 22.04」上打包
> 線上機器的 **OS 版本 (22.04) 與架構 (amd64) 必須跟離線目標機一致**,
> 否則抓到的 .deb 版本對不上,離線端會缺相依。最保險是用同一份 Ubuntu image 開的 VM。

```bash
chmod +x download-nfs-packages.sh
./download-nfs-packages.sh
```

產出 `nfs-offline-bundle.tar.gz`(內含 `debs/` 與 `install-nfs-offline.sh`)。

## 階段二:在「離線目標機」上安裝
```bash
tar xzf nfs-offline-bundle.tar.gz
chmod +x install-nfs-offline.sh

# 用法: sudo ./install-nfs-offline.sh [EXPORT_DIR] [ALLOWED_CIDR] [OPTIONS]
sudo ./install-nfs-offline.sh /srv/nfs 10.0.0.0/24
```

完成後會自動:
1. 用 `dpkg -i debs/*.deb` 離線安裝
2. 建立 export 目錄、寫入 `/etc/exports`
3. 啟動 `rpcbind` + `nfs-server` 並 `exportfs -ra`

## Client 掛載
```bash
sudo mount -t nfs <server_ip>:/srv/nfs /mnt
```

## 參數
| 參數 | 預設 | 說明 |
|------|------|------|
| EXPORT_DIR | `/srv/nfs` | 要分享的目錄 |
| ALLOWED_CIDR | `*` | 允許來源網段,正式環境請改 (如 `10.0.0.0/24`) |
| OPTIONS | `rw,sync,no_subtree_check,no_root_squash` | export 選項 |
