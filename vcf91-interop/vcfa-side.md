# VCFA 側：Edge 對應與 Migration Tool 現況

承接 [`README.md`](README.md)（VCD 側）與 [`bridge-state.md`](bridge-state.md)（架構概念）。
這篇記錄 **bridge 的另一半**：在 VCF Automation 這邊看到什麼、Edge 怎麼對應、
以及 VCD→VCFA Migration Tool 的實際狀態。

## 重點結論：VCFA 的 Edge Cluster 不是「建」的，是「同步」的

在 VCFA Provider Management → **Networking → Edge/VNA Clusters**，
畫面上**只有一個 `SYNC` 按鈕，沒有 New/Create**。

因為 Edge Cluster 的真實來源是 **NSX**。VCFA 只是把 NSX 既有的 edge cluster 同步進來納管。

所以當我們為了 VCD 的 Edge Gateway 在 NSX 建好 `edge-cl01` 之後，
VCFA 這邊按一次 SYNC 就直接對應上了：

![VCFA Edge Cluster 同步結果](images/09-vcfa-edge-cluster-synced.png)

| 欄位 | 值 |
|---|---|
| Name | `edge-cl01` |
| Health | **Healthy** |
| Nodes | 1 |
| Type | VM |
| Region | `vcf1` |
| Organizations / VPCs | 0 / 0（尚未被 VCFA 租戶使用）|

Recent Tasks 顯示 `Synced Edge Clusters for Organization System … Succeeded`。

### 這正是 bridge 的具體證據

**同一個 NSX edge cluster，同時服務兩邊**：

```
                    NSX 9.1
                  edge-cl01  (1 node, Healthy)
                       │
        ┌──────────────┴──────────────┐
        │                             │
   VCD 10.6.2                     VCF Automation
   Tier-0 t0-gw01                 Edge/VNA Clusters
   └ Edge Gateway (T1)            └ 已同步納管
      tenant01-edge                  (可供 VPC 使用)
```

不需要為了 VCFA 另外部署一組 edge — 這就是「同一批硬體、兩套消費層並存」。

> 對照：VCD 側的 Edge Gateway 建立方式與踩到的坑見 [`README.md`](README.md)。

## Migration Tool（VCD → VCFA）

位置：**VCF Services → Migration Tool**。

![VCFA Migration Tool](images/10-vcfa-migration-tool.png)

UI 直接畫出了整條遷移鏈：

```
Cloud Director → Migration Service → Provider Infra Migration
   → Organization Migration → Workloads Migration → VCF Automation

                    Plan → Evaluation → Migration
```

入口是 **ADD VMWARE CLOUD DIRECTOR SITE**：加入並註冊一個 VCD site 之後，
VCFA 會跑一次 evaluation、提出建議的 migration plan，
可以直接遷移、也可以先編輯 plan 再執行。

### ⚠️ 目前狀態：後端 502，流程走不下去

畫面上持續出現：

```
Http failure response for
https://<vcfa>/ui-proxy/ext-ui/provider/broadcom/migration/api/vcdInstances: 502
```

點 `ADD VMWARE CLOUD DIRECTOR SITE` 沒有反應（對話框不會開），
因為 `vcdInstances` 取不到。

診斷佐證：

| 測試 | 結果 | 意義 |
|---|---|---|
| `curl` 直打該 API（未帶 token） | `401` | ui-proxy 與路由正常，端點存在 |
| 瀏覽器（帶 token）打同一 API | `502` | 打到後端了，但 **migration service 本身不可用** |
| VCFA 其他端點 `/automation/`、`/tm/login/` | `200` | VCFA 主體正常 |

→ 結論：**不是 VCFA 整體壞掉，是 migration 這個 service/plugin 的後端沒起來**。
要跑 migration 得先讓該服務恢復。

## 附帶觀察

- VCFA 執行個體處於 **licensing evaluation**（提示需在期限內加入已授權的 vCenter 9.0+）。
- Infrastructure Overview：Organizations 1 / Regions 1 / Supervisors 1 / Content Libraries 0。

---

*實機驗證於 2026-08，VCF 9.1 nested lab。截圖為 VCFA Provider Management console。*
