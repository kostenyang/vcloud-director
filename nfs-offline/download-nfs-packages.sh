#!/usr/bin/env bash
#
# download-nfs-packages.sh
# -------------------------------------------------------------------
# 在【有網路】的 Ubuntu 22.04 (Jammy) 機器上執行。
# 會把 nfs-kernel-server 及其所有相依套件 (.deb) 下載到 ./debs，
# 一併產生離線安裝 script，最後打包成 nfs-offline-bundle.tar.gz。
#
# 用法:
#   chmod +x download-nfs-packages.sh
#   ./download-nfs-packages.sh
#
# 注意: 下載端的 OS 版本/架構必須和離線目標機一致 (Ubuntu 22.04 / amd64)。
# -------------------------------------------------------------------
set -euo pipefail

PKGS="nfs-kernel-server nfs-common rpcbind keyutils"
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
DEBDIR="${WORKDIR}/debs"

echo "==> 檢查 OS 版本"
. /etc/os-release
if [[ "${VERSION_ID:-}" != "22.04" ]]; then
  echo "!! 警告: 偵測到 ${PRETTY_NAME:-unknown}，本 bundle 是給 Ubuntu 22.04 用的。"
  read -r -p "   仍要繼續? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || exit 1
fi

echo "==> 建立下載目錄: ${DEBDIR}"
rm -rf "${DEBDIR}"
mkdir -p "${DEBDIR}"

echo "==> 更新套件索引"
sudo apt-get update

# 用一個臨時 cache 目錄，--download-only 連同相依套件一起抓，
# --reinstall 確保即使本機已裝過也會把 .deb 抓下來。
echo "==> 下載 ${PKGS} 及其相依套件"
sudo apt-get install -y --download-only --reinstall \
  -o Dir::Cache::archives="${DEBDIR}" \
  -o Debug::NoLocking=true \
  ${PKGS}

# apt 會在 cache 目錄留下 partial/ 與 lock，清掉只留 .deb
sudo find "${DEBDIR}" -mindepth 1 -maxdepth 1 ! -name '*.deb' -exec rm -rf {} +
sudo chown -R "$(id -u):$(id -g)" "${DEBDIR}"

COUNT=$(find "${DEBDIR}" -name '*.deb' | wc -l)
echo "==> 已下載 ${COUNT} 個 .deb"

echo "==> 產生離線安裝 script"
# install script 與本下載 script 同目錄；若不存在則提示
if [[ ! -f "${WORKDIR}/install-nfs-offline.sh" ]]; then
  echo "!! 找不到 install-nfs-offline.sh，請確認與本 script 放在一起。"
fi

echo "==> 打包成 nfs-offline-bundle.tar.gz"
cd "${WORKDIR}"
tar czf nfs-offline-bundle.tar.gz debs install-nfs-offline.sh
echo ""
echo "完成！把 nfs-offline-bundle.tar.gz 複製到離線機器後:"
echo "  tar xzf nfs-offline-bundle.tar.gz"
echo "  sudo ./install-nfs-offline.sh /srv/nfs 10.0.0.0/24"
