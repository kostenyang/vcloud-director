# chunghwa-vcd

中華電信 vCloud Director 10.6.1 — 租戶 VM 網卡切換工具。

把租戶 (Org) 內的 VM 網卡,從「來源 portgroup」切換到「目的 portgroup」。
拆成兩支 script:先在 vCenter 把 portgroup 建好,再從 VCD 租戶端匯入並重接網卡。

## 環境

- vCloud Director **10.6.1** (REST API version **40.0**)
- portgroup 類型:**vDS 分散式 portgroup**
- PowerShell 7+,需安裝 VMware PowerCLI (`Install-Module VMware.PowerCLI`)

## 設定

編輯 [config/config.json](config/config.json)。若不想把實際環境資訊 commit,
複製成 `config/config.local.json`(已被 `.gitignore` 忽略),script 會自動優先採用。

| 欄位 | 說明 |
|------|------|
| `vCenter.server` | vCenter FQDN |
| `vCenter.vdsName` | 來源/目的 portgroup 所在的 vDS 名稱 |
| `vcd.server` | VCD FQDN |
| `vcd.apiVersion` | API 版本,10.6.1 為 `40.0` |
| `vcd.org` | 登入用 org,provider 管理員填 `System` |
| `vcd.skipCertificateCheck` | 自簽憑證環境設 `true` |
| `tenant.orgName` | 租戶 Org 名稱 |
| `tenant.orgVdcName` | 要匯入網路的 Org VDC 名稱 |
| `portGroup.source` | 來源 portgroup 名稱 |
| `portGroup.destinationSuffix` | 目的名稱後綴,預設 `-new` |

> 命名規則:目的 portgroup / 目的 Org VDC Network 名稱 = 來源名稱 + 後綴。
> 例:來源 `PG-Tenant-VLAN100` → 目的 `PG-Tenant-VLAN100-new`。

## 使用流程

### 步驟 1 — 在 vCenter 建立目的 portgroup

```powershell
pwsh ./scripts/1-New-DistributedPortGroup.ps1
```

從來源 portgroup 複製設定(VLAN、teaming、binding),在同一個 vDS 上建立
`<來源>-new`。只動 vCenter。

### 步驟 2 — 匯入租戶並重接 VM 網卡

```powershell
# 先演練,只列出會被影響的 VM,不做任何變更
pwsh ./scripts/2-Import-And-Switch-TenantNic.ps1 -WhatIf

# 確認清單沒問題後正式執行
pwsh ./scripts/2-Import-And-Switch-TenantNic.ps1
```

1. 以 System 管理員登入 VCD
2. 在指定 Org VDC 建立「已匯入 (imported)」的 Org VDC Network,backing 為步驟 1 的 portgroup
3. 掃描該 Org 內所有網卡接在「來源網路」的 VM
4. 改寫每台 VM 的 `networkConnectionSection`,把網卡重接到新網路

## 檔案結構

```
chunghwa-vcd/
├── config/
│   └── config.json                       # 環境設定(可用 config.local.json 覆蓋)
├── lib/
│   └── VcdRest.ps1                        # VCD REST API 共用函式
├── scripts/
│   ├── 1-New-DistributedPortGroup.ps1     # 步驟 1:建 portgroup (PowerCLI)
│   └── 2-Import-And-Switch-TenantNic.ps1  # 步驟 2:匯入 + 重接網卡 (VCD REST)
└── README.md
```

## 注意事項

- **先用 `-WhatIf` 跑步驟 2**,確認受影響的 VM 清單。
- 步驟 2 假設租戶端「來源網路」名稱與 `portGroup.source` 相同;
  若不同,用 `-SourceNetworkName` 參數指定。
- 重接網卡會保留原本的 IP / MAC / 配置模式,只改變網卡連接的網路。
- 匯入網路 (imported / DV_PORTGROUP backing) 屬 provider 操作,需 System 權限。
