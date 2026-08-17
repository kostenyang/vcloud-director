# 「Bridge 狀態」是什麼、怎麼湊出來

> 承接 [`README.md`](README.md) 的實作紀錄。這篇只講**架構概念與達成方式**。

## 先講結論：bridge 不是一個要安裝的元件

它是一個**狀態**——

> **同一批硬體上，舊的 VCD 租戶 與 新的 VCF Automation（Supervisor / VPC）並存。**

目的是讓底層先完成現代化（升到 VCF 9.1），而**既有 VCD 租戶照常營運**，
再用剩下的時間把租戶逐步搬進 VCF Automation。
所以它天生是**過渡用的**：橋的終點是 VCFA，不是長期架構。

## 成立條件只有三個

| # | 條件 | 說明 |
|---|---|---|
| 1 | 底層是 **VCF 9.1** | vCenter 9.1 + NSX 9.1（+ VCF Operations / VCF Automation） |
| 2 | VCD 是 **10.6.2** | 支援 VCF 9 的版本；公開線最新的 10.6.1.2 並未列 vSphere 9 支援 |
| 3 | VCD 指向**同一套** vCenter / NSX / 叢集 | ← **這點是 bridge 的本體** |

第 3 點才是關鍵：**不要另外給 VCD 一套硬體**。
把 VCD 的 Provider VDC 直接建在 VCF 管理域那個叢集上，
VCD 與 VCFA 就會共用同一批 host、同一個 vSAN、同一套 NSX。

## 拓樸長這樣

```
                    ┌─────────────── 同一批實體資源 ───────────────┐
                    │   vSphere 9.1 cluster + vSAN + NSX 9.1        │
                    └───────┬───────────────────────────┬──────────┘
                            │                           │
        ┌───────────────────┴────────┐     ┌────────────┴────────────────────┐
        │  舊世界：VMware Cloud Director│     │  新世界：VCF Automation          │
        │  ├ Provider VDC  →  同一個   │     │  ├ Supervisor / VSP             │
        │  │   cluster (resource pool) │     │  ├ NSX VPC                      │
        │  ├ Org / Org VDC             │     │  └ Namespace / 現代化租戶        │
        │  ├ Edge Gateway (NSX T1)     │     │                                 │
        │  └ Org VDC Network (segment) │     │                                 │
        └──────────────────────────────┘     └─────────────────────────────────┘
                    ↑ 既有租戶照常營運          ↑ 新租戶 / 搬過來的租戶
                            └──────── 遷移方向 ────────┘
```

兩邊各自管理自己的租戶，但**底層是同一套**——這就是「bridge」。

## 達成順序

```
底層已是 VCF 9.1（vCenter 9.1 / NSX 9.1）
  └─ 部署 VCD 10.6.2（先備妥 NFS transfer share）
       └─ 註冊「同一套」vCenter + NSX（憑證先信任、URL 用 FQDN）
            └─ Provider VDC 指到 VCF 叢集的 resource pool   ← 共用硬體在這一步
                 └─ Geneve network pool（TZ 要選 host 真的在的那個）
                      └─ Org → Org VDC → Edge Gateway → Org VDC Network
```

> ⚠️ 若要做到 Edge Gateway，**network pool 必須在建 Provider VDC 之前就先建好**，
> 且建 PVDC 時就要帶 `NsxTManagerReference` + `NetworkPool`。
> 詳見 [`README.md` 坑 #11](README.md)。

## 兩條路徑：in-place 升級 vs greenfield

達成 bridge 有兩種走法，**終點狀態相同，但驗證到的東西不同**：

| | in-place（真實客戶場景） | greenfield（本次實作） |
|---|---|---|
| 起點 | 已在運作的 VCD 10.6.x + 舊底層 | 全新環境 |
| 做法 | 底層升到 VCF 9.1 → VCD 套用 10.6.2 patch | 直接部署 VCD 10.6.2 接上 VCF 9.1 |
| 租戶 | **全程不中斷**是重點 | 無既有租戶 |
| 驗到什麼 | 升級過程本身、租戶無感 | **平台相容性**（能不能跑、功能是否完整） |

**本次驗證屬 greenfield**：證明了 VCD 10.6.2 在 vCenter 9.1 + NSX 9.1 上
可以一路正常運作到 Edge Gateway 與 Org VDC Network。
但**沒有驗到升級過程**——真實導入前，仍應在對應環境驗一次
`10.6.x → 10.6.2` 的升級路徑與租戶中斷時間。

## 專案條款（內部資料 — 請勿外流）

> 以下整理自 **VCD 10.6.2 Migration Patch Readme**。該文件載明相關計畫、時程與
> 架構細節屬專有資訊並受 NDA 規範，**本節僅供內部參考，不得對外分享**。
> （此 repo 為 private；若日後改為 public，**請先移除本節**。）

**版本與取得**
- 10.6.2 是 **gated release**，非一般公開更新。
- 支援的來源版本：**10.6 / 10.6.1 / 10.6.1.1 / 10.6.1.2**。
  由更舊或其他版本直接升級 **不受支援**，必須先升到上述 10.6.x 基準。
- 官方 binaries：`...10.6.2.11927-25290816_update.tar.gz`（既有環境升級）與
  對應的 `_OVF10.ova`（全新部署）。

**支援範圍**
- bridged 狀態下的技術支援**僅涵蓋核心平台**，以及明確驗證過的擴充：
  **VCDA / CSE / DSE**。
- 其他第三方 plug-in / extension 不在支援範圍內。

**時限（這是重點）**
- 需在 intake 後 **90 天內**向 Broadcom 客戶團隊提交高階遷移 roadmap，
  才能維持此 bridged 環境的技術支援。
- 支援延續取決於**實際遷移進度**（租戶要真的持續搬出 VCD）。
- **VCD 10.6.x End-of-Support：2027 年 10 月**。

**產品定位**
- VCFA 採用 Supervisor / VPC 的新架構典範，
  **並不以「與 VCD 100% 功能對等」為目標**——規劃遷移時要預期功能落差，
  對應的 runbook 用途正在於補這些手動設定。

**問題回報管道**
- 技術問題 / bug：透過 GSS 開 SR。
- 缺功能導致遷移受阻：透過 Aha! 提 feature request。
- 兩者的追蹤編號都應同步給客戶團隊，登錄在 CSP Migration Tracker。

## 心智模型

把它想成搬家時的**臨時走廊**：

- 你先把房子的結構翻新（底層升 VCF 9.1）
- 舊家具還在原位照常用（VCD 租戶不中斷）
- 新房間已經蓋好、可以開始住人（VCFA）
- 然後慢慢把家具一間一間搬過去（租戶遷移）
- **走廊本身不是要住的地方**——搬完就該拆

所以規劃時，重點不在「把 bridge 建得多完美」，
而在**盡早開始搬、並清楚知道搬完的期限**。
