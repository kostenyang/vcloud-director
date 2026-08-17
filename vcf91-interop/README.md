# VCD 10.6.2 × VCF 9.1 互通性驗證

把 **VMware Cloud Director 10.6.2**（Migration Patch / bridge 版）接到 **VCF 9.1**
（vCenter 9.1 + NSX 9.1）的實機驗證紀錄：**做得到什麼、踩了哪些坑、正確的 API 長什麼樣**。

> 官方互通矩陣的 VCD 10.6.x 只列到 vSphere 8 / NSX 4.x。10.6.2 是**專為銜接 VCF 9 的 gated patch**，
> 用途是建立「VCD 舊租戶」與「VCFA 新架構」在同一批硬體上並存的 **bridge 狀態**，
> 讓底層先升到 VCF 9.1，再逐步把 tenant 搬到 VCF Automation。

## TL;DR — 驗證結果

| 項目 | 結果 |
|---|---|
| VCD 10.6.2 appliance 部署（air-gap / 全 API） | ✅ |
| 註冊 **vCenter 9.1** | ✅ `CONNECTED`，vcVersion 9.1.0.0100 |
| 註冊 **NSX 9.1** | ✅（需走 legacy endpoint，見下） |
| Provider VDC（vSAN 儲存原則） | ✅ enabled |
| Geneve Network Pool | ✅ REALIZED（**TZ 要選對，見坑 #6**） |
| Org / Org VDC | ✅ READY |
| NSX Edge node / Edge Cluster / T0（單一 uplink VLAN） | ✅ |
| VCD External Network（T0 backed） | ✅ |
| **Edge Gateway（T1）** | ✅ REALIZED，NSX 端實際生出 T1 |
| **Org VDC Network（routed）** | ✅ REALIZED，NSX 端實際生出 segment |

**結論：VCD 10.6.2 在 vCenter 9.1 + NSX 9.1 上可正常運作到租戶 Org VDC。**
公開的 10.6.1.2 release notes 並未列 vSphere 9 支援 → 這條路**必須用 10.6.2**。

## 環境

| 元件 | 說明 |
|---|---|
| VCD | 10.6.2（appliance，primary cell，API 版本 **39.2**） |
| Backing | VCF 9.1 管理域：vCenter 9.1.0.0300、NSX 9.1.0.0200 |
| 儲存 | vSAN（PVDC 用 `vSAN Default Storage Policy`） |
| Transfer share | 獨立 NFS server（air-gap 離線安裝，見 [`../nfs-offline/`](../nfs-offline/)） |

> 本文件所有位址為實驗室內部 RFC1918 網段；**不含任何帳密**。

---

## 踩到的坑與解法

### 1. OVA 屬性被標成 `userConfigurable=false`，ovftool 直接拒絕
VCD OVA 的 `nfs_mount` / `db_pwd` / `admin_pwd` / `sys_name` / `inst_id` 都是
`ovf:userConfigurable="false"`，`ovftool --prop:` 會回：

```
Error: - Property vcloudapp.nfs_mount.VMware_vCloud_Director is not user configurable.
```

更麻煩的是**連 PowerCLI `ReconfigVM` 改值也被 vCenter 擋**（同樣訊息）。

**解法**：ReconfigVM 時，在**同一個** `VAppPropertySpec` 裡把 `UserConfigurable` 翻成 `$true`
**並且**同時寫入 `Value`，一次送出就會通過：

```powershell
$ps = New-Object VMware.Vim.VAppPropertySpec
$ps.Operation             = "edit"
$ps.Info                  = New-Object VMware.Vim.VAppPropertyInfo
$ps.Info.Key              = $prop.Key
$ps.Info.UserConfigurable = $true      # 關鍵：與 Value 同時送
$ps.Info.Value            = $desiredValue
```

流程 = `ovftool` 只匯入可設屬性（不開機）→ ReconfigVM 補齊隱藏屬性 → 開機。

### 2. .NET 連 VCD 443 會 SSL 握手失敗
PowerShell 的 `Invoke-WebRequest` 對 VCD 會 `The SSL connection could not be established`，
但 `curl.exe -sk` 完全正常。**一律用 curl 打 VCD API**。

### 3. 認證
```bash
curl -sk -D - -o /dev/null -X POST \
  -u '<user>@system:<password>' \
  -H 'Accept: application/*;version=39.2' \
  https://<vcd>/cloudapi/1.0.0/sessions/provider
# 回應 header 取 X-VMWARE-VCLOUD-ACCESS-TOKEN → 之後用 Authorization: Bearer <token>
```
API 版本用 **39.2**（`40.0.0-alpha-*` 是 alpha，指定它會 406）。

### 4. 註冊 vCenter / NSX：先信任憑證，且必須用 FQDN
兩個連續的坑：

1. 直接註冊 → `PKIX path building failed`
   → 先把對方憑證加進 VCD 信任庫：
   ```bash
   curl -sk -X POST -H 'Content-Type: application/json' \
     -d '{"alias":"vc-cert","certificate":"-----BEGIN CERTIFICATE-----\n..."}' \
     https://<vcd>/cloudapi/1.0.0/ssl/trustedCertificates
   ```
2. 用 **IP** 註冊 → `Certificate for <ip> doesn't match any of the subject alternative names: [<fqdn>]`
   → **url 必須填 FQDN**（vCenter/NSX 憑證 SAN 通常只有 FQDN）。

另外：刪除 vCenter 註冊是**非同步**的，unregister task 未完成前重新註冊會回
`Another vCenter found with url ...`（400）——要等 task 結束。

### 5. NSX Manager 註冊：cloudapi 端點是 404，要用 legacy
```
POST /cloudapi/1.0.0/nsxTManagers        → 404 ❌
POST /api/admin/extension/nsxtManagers   → 200 ✅
     Content-Type: application/vnd.vmware.admin.nsxTmanager+json
     Accept:       application/*+json;version=39.2
```

### 6. ⚠️ Network Pool 的 Transport Zone 要選「真的有 host 的那個」
NSX 預設會有一個 `nsx-overlay-transportzone`，但 **VCF 部署的 host 實際掛在
`overlay-tz-mgmt-nsxt`**。若 Geneve pool 綁到前者，pool 會顯示 `REALIZED`，
但底下**沒有任何 transport node**，租戶的 Org VDC Network 之後會實現不了。

建 pool 前先確認 host transport node 用的 TZ：
```bash
curl -sk -u '<nsx-creds>' 'https://<nsx>/api/v1/transport-nodes?node_types=HostNode' \
  | jq '.results[0].host_switch_spec.host_switches[].transport_zone_endpoints[].transport_zone_id'
```
> 注意 policy id 與 MP id **不同**（同一個 TZ 兩邊 id 不一樣），要用名稱對照。

另外兩個相關細節：
- TZ 的 `id` 要填 **NSX policy path**，不是裸 UUID：
  `/infra/sites/default/enforcement-points/default/transport-zones/<uuid>`
- 列可匯入的 TZ 要用 `_context` filter：
  ```
  GET /cloudapi/1.0.0/nsxTResources/importableTransportZones?filter=_context==<nsxManagerUrn>
  ```
  （用 `nsxTManagerId==` 會回 "unknown property"）

### 7. Provider VDC 的 XML 有嚴格順序，且建完預設是停用的
- `NsxTManagerReference` **不是** `VMWProviderVdcParams` 的合法子元素（NSX 是建完之後才關聯）
- 元素順序固定：`ResourcePoolRefs` → `VimServer` → `HighestSupportedHardwareVersion` → `StorageProfile`
- 沒帶 `IsEnabled` 的話 PVDC 會是 **deactivated**，接著建 Org VDC 會撞：
  ```
  409 ... backing Provider VDC "xxx" is currently deactivated
  ```
  → `POST /api/admin/extension/providervdc/{id}/action/enable`（回 204）

storage profile 的 href 是 `/api/admin/pvdcStorageProfile/{id}`（不是 `providerVdcStorageProfile`）。

### 8. Org VDC：`isEnabled` 是元素不是屬性
```
400 ... Attribute 'isEnabled' is not allowed to appear in element 'CreateVdcParams'
```
拿掉即可（預設就會建起來）。端點：`POST /api/admin/org/{orgId}/vdcsparams`
（`Content-Type: application/vnd.vmware.admin.createVdcParams+xml`）。

### 9. NSX 9.1 部署 Edge：schema 換位置了
`hostname` / `dns_servers` / `ntp_servers` / `search_domains` **不再**放在
`vm_deployment_config`，否則會一路報 `property X is unrecognized`。
NSX 9.1 要放在 `node_deployment_info.node_settings`：

```json
"node_deployment_info": {
  "resource_type": "EdgeNode",
  "deployment_config": { "form_factor": "MEDIUM", "vm_deployment_config": { ... } },
  "node_settings": {
    "hostname": "edge01.example.lab",
    "dns_servers": ["..."], "ntp_servers": ["..."], "search_domains": ["..."],
    "enable_ssh": true, "allow_ssh_root_login": true
  }
}
```

### 10. nested 環境：Edge 的 trunk portgroup 必須放行三件事
Edge VM 的 TEP / uplink 介面接的 trunk portgroup 要開
**Promiscuous + Forged Transmits + MAC Changes**，否則 overlay/uplink 不通。

### 11. ⭐ PVDC 必須「**建立當下**」就是 NSX-T backed，事後補不回來
這是整個流程最花時間的一關。建 Edge Gateway 時會撞：

```
400 ... Org VDC <name> is not NSX-T Backed.
```

即使 Org VDC 已經指到 GENEVE network pool 也一樣 —— 因為判定的是 **PVDC**。
而 PVDC 的 `NetworkPoolReferences` 與 NSX-T 關聯 **都是唯讀的**：
事後 `PUT` 回 200 但值不會生效，硬塞 `NsxTManagerReference` 則直接 schema 400。

**唯一解：刪掉 Org VDC + PVDC，重建 PVDC**，且 params 要同時包含
`NsxTManagerReference` **和** `NetworkPool`（少了 NetworkPool 會回
`A valid Network Pool is required when performing this operation.`，
而且 `AutoCreateNetworkPool` 救不了）。

正確順序（順序錯就 400）：

```xml
<vmext:VMWProviderVdcParams ... name="m02-pvdc">
  <vmext:ResourcePoolRefs>...</vmext:ResourcePoolRefs>
  <vmext:VimServer href=".../vimServer/<id>"/>
  <vmext:NsxTManagerReference href=".../nsxtManagers/<id>"/>
  <vmext:NetworkPool href=".../networkPool/<id>" id="urn:vcloud:networkpool:<id>"
                     type="application/vnd.vmware.admin.networkPool+xml" name="<pool>"/>
  <vmext:HighestSupportedHardwareVersion>vmx-20</vmext:HighestSupportedHardwareVersion>
  <vmext:StorageProfile>vSAN Default Storage Policy</vmext:StorageProfile>
</vmext:VMWProviderVdcParams>
```

> 建完一樣要 `action/enable`。

#### 小技巧：用「故意放錯的元素」把 XSD 的合法清單問出來
VCD 的錯誤訊息會列出該位置允許的所有元素，比翻文件快：

```xml
<vmext:VimServer href="..."/>
<vmext:ZZZProbe>x</vmext:ZZZProbe>   <!-- 故意亂放 -->
```
```
Invalid content was found starting with element 'ZZZProbe'. One of
'{VimServer, NsxTManagerReference, VxlanNetworkPool, NetworkPool,
  HighestSupportedHardwareVersion, IsEnabled, StorageProfile}' is expected.
```
`NetworkPool` 就是這樣找到的。

### 12. 建 Org VDC Network 要用 `ownerRef`，不是 `orgVdc`
```
400 ... Cannot specify orgVdc for network creation. Please user ownerRef to specify owner of the network.
```
```jsonc
{
  "name": "tenant01-net01",
  "ownerRef": { "id": "urn:vcloud:vdc:<vdc-id>" },   // ← 不是 orgVdc
  "networkType": "NAT_ROUTED",
  "connection": { "routerRef": { "id": "urn:vcloud:gateway:<gw-id>" }, "connectionType": "INTERNAL" },
  "subnets": { "values": [ { "gateway": "172.16.10.1", "prefixLength": 24, "enabled": true,
    "ipRanges": { "values": [ { "startAddress": "172.16.10.10", "endAddress": "172.16.10.50" } ] } } ] }
}
```

### 13. T0 剛建好時 `consolidated_status` 會是 DOWN — 那是還沒收斂
建完 T0 立刻查會看到 `DOWN`，等一兩分鐘會自己變 `SUCCESS`。
另外 **NSX T0 uplink IP 預設不回 ICMP**，ping 不通不代表壞掉；
要驗證請看 realized state 與 edge node 的 interface link status。

---

## Edge / T0 實作重點（單一 uplink VLAN）

以「只有一個 uplink VLAN」為前提，手動建（不經 SDDC Manager）：

| 物件 | 內容 |
|---|---|
| Edge trunk portgroup | VDS 上開 VLAN trunk `0-4094`，並開 promiscuous / forged / MAC changes |
| Edge TEP pool | 與 host TEP 同網段但**錯開 range**（例：host `.50-.60`，edge `.61-.70`） |
| Edge uplink profile | `transport_vlan` = host TEP VLAN，MTU 1600 |
| Edge transport node | MEDIUM；TZ 掛 **overlay（有 host 的那個）+ VLAN TZ** |
| Edge Cluster | `POST /api/v1/edge-clusters`，成員填 transport node id |
| Uplink segment | VLAN segment（VLAN 7）掛在 VLAN TZ |
| T0 | `ACTIVE_STANDBY` → locale-service 綁 edge cluster → uplink interface（`edge_path` 指到 `.../edge-nodes/0`）→ default static route |

驗證鏈：**T0 realized SUCCESS → VCD External Network → Edge Gateway（NSX 生出 T1）→ Org VDC Network（NSX 生出 segment）**。

---

## 建置順序（可直接照抄）

1. NFS transfer share（air-gap 離線裝）
2. VCD appliance：`ovftool` 匯入 → ReconfigVM 補隱藏屬性 → 開機
3. 憑證信任 → 註冊 **vCenter**（FQDN）
4. 憑證信任 → 註冊 **NSX**（legacy endpoint）
5. **Provider VDC** → `action/enable`
6. **Geneve Network Pool**（TZ 選有 host 的那個）
7. **Org** → **Org VDC**
8. NSX Edge node → Edge Cluster → T0（單一 uplink VLAN）
9. VCD External Network → **Edge Gateway** → Org VDC Network

> ⚠️ 若打算做到 Edge Gateway，**步驟 5 建 PVDC 時就要帶 `NsxTManagerReference` + `NetworkPool`**
> （見坑 #11），否則走到第 9 步才會發現要整個重建 PVDC 與 Org VDC。
> 也就是說：**network pool（步驟 6）要提前到 PVDC 之前建好**。

---

*實機驗證於 2026-08，VCF 9.1 nested lab。*
