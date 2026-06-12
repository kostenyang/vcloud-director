#!/usr/bin/env bash
#
# install-nfs-offline.sh
# -------------------------------------------------------------------
# 在【離線】Ubuntu 22.04 目標機上執行。
# 從同目錄的 ./debs 安裝 NFS server 套件 (不需網路)，
# 並建立 export 目錄、寫入 /etc/exports、啟動服務。
#
# 用法:
#   sudo ./install-nfs-offline.sh [EXPORT_DIR] [ALLOWED_CIDR] [OPTIONS]
#
# 範例:
#   sudo ./install-nfs-offline.sh /srv/nfs 10.0.0.0/24
#   sudo ./install-nfs-offline.sh /export/iso 192.168.1.0/24 "ro,sync,no_subtree_check"
#
# 預設:
#   EXPORT_DIR    = /srv/nfs
#   ALLOWED_CIDR  = *            (所有來源，正式環境請改成你的網段)
#   OPTIONS       = rw,sync,no_subtree_check,no_root_squash
# -------------------------------------------------------------------
set -euo pipefail

EXPORT_DIR="${1:-/srv/nfs}"
ALLOWED_CIDR="${2:-*}"
OPTIONS="${3:-rw,sync,no_subtree_check,no_root_squash}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEBDIR="${SCRIPT_DIR}/debs"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "!! 請用 root / sudo 執行" >&2
  exit 1
fi

if [[ ! -d "${DEBDIR}" ]] || ! ls "${DEBDIR}"/*.deb >/dev/null 2>&1; then
  echo "!! 找不到 ${DEBDIR}/*.deb，請先解開 nfs-offline-bundle.tar.gz" >&2
  exit 1
fi

echo "==> 從本地 .deb 安裝 NFS 套件 (離線)"
# dpkg 一次安裝整個目錄，相依關係由目錄內的 .deb 互相滿足
if ! dpkg -i "${DEBDIR}"/*.deb; then
  echo "==> dpkg 回報相依問題，嘗試用本地套件修復..."
  # 不連網，只用本地目錄當 apt 來源來補相依
  apt-get install -y --no-download --fix-broken \
    -o Dir::Cache::archives="${DEBDIR}" || {
      echo "!! 自動修復失敗。可能是 bundle 缺少某些相依套件 (下載端與此機環境不一致)。" >&2
      echo "   請在『與本機相同基底』的線上機器重跑 download-nfs-packages.sh。" >&2
      exit 1
    }
fi

echo "==> 建立 export 目錄: ${EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}"
chmod 777 "${EXPORT_DIR}"

EXPORT_LINE="${EXPORT_DIR} ${ALLOWED_CIDR}(${OPTIONS})"
echo "==> 設定 /etc/exports"
touch /etc/exports
# 移除同一目錄的舊設定，避免重複
sed -i "\#^${EXPORT_DIR}[[:space:]]#d" /etc/exports
echo "${EXPORT_LINE}" >> /etc/exports
echo "    ${EXPORT_LINE}"

echo "==> 啟用並啟動服務"
systemctl enable --now rpcbind 2>/dev/null || true
systemctl enable --now nfs-server

echo "==> 重新載入 export 表"
exportfs -ra
exportfs -v

echo ""
echo "完成！NFS server 已就緒。"
echo "  目前 export:"
showmount -e localhost 2>/dev/null || exportfs -v
echo ""
echo "用戶端掛載測試 (在 client 上):"
echo "  sudo mount -t nfs <server_ip>:${EXPORT_DIR} /mnt"
echo ""
echo "防火牆若有開 ufw，需放行: sudo ufw allow from ${ALLOWED_CIDR} to any port nfs"
