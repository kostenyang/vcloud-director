<#
.SYNOPSIS
    VCF 5.2.1 bringup 完成後，把 VCF 5.2.1 的 vCenter 接入 VCD 10.6.1:
      1. 新增 vCenter Server (Provider resource)
      2. 建立 Provider VDC (pvdc)
      3. 建立 Network Pool (NSX-T 的 VXLAN/Geneve overlay)

.DESCRIPTION
    Prerequisites:
      - VCD wizard 已完成 (https://192.168.114.60/ui)
      - VCF 5.2.1 bringup completed:
          vCenter : kosten-vcf521-vc.rtolab.local @ 192.168.114.56
          NSX VIP : kosten-vcf521-nsx.rtolab.local @ 192.168.114.58
      - DNS: kosten-vcf521-vc, kosten-vcf521-nsx resolvable

.EXAMPLE
    pwsh E:\VCD\05-Connect-Vcf521.ps1
    pwsh E:\VCD\05-Connect-Vcf521.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $VcdFqdn      = 'kosten-vcd.rtolab.local',
    [string] $VcdUser      = 'administrator',
    [string] $VcdPw        = 'VMware1!VMware1!',   # wizard 時設的 admin pw
    [string] $VcdOrg       = 'System',

    [string] $VcFqdn       = 'kosten-vcf521-vc.rtolab.local',
    [string] $VcIp         = '192.168.114.56',
    [string] $VcUser       = 'administrator@vsphere.local',
    [string] $VcPw         = 'VMware1!VMware1!',

    [string] $NsxFqdn      = 'kosten-vcf521-nsx.rtolab.local',
    [string] $NsxUser      = 'admin',
    [string] $NsxPw        = 'VMware1!VMware1!',

    [string] $PvdcName     = 'pvdc-vcf521',
    [string] $ResourcePoolPath = '*/Resources',   # vCenter RP path
    [string] $StoragePolicyName = '*',             # 留空=全抓

    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'

$baseUrl = "https://$VcdFqdn/cloudapi"
$sysUrl  = "https://$VcdFqdn/api"
$headers = @{ Accept = 'application/json;version=36.3'; 'Content-Type' = 'application/json' }

# ---- 取 Bearer Token ----
Write-Host "Authenticating to VCD $VcdFqdn ..." -ForegroundColor Cyan
$authBytes  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${VcdUser}@${VcdOrg}:${VcdPw}"))
$authHeader = @{ Authorization = "Basic $authBytes"; Accept = 'application/*+xml;version=36.3' }
$loginResp = Invoke-WebRequest -Uri "https://$VcdFqdn/api/sessions" -Method Post -Headers $authHeader -SkipCertificateCheck -UseBasicParsing
$token = $loginResp.Headers['X-VMWARE-VCLOUD-ACCESS-TOKEN'] ?? $loginResp.Headers['x-vcloud-authorization']
if (-not $token) { Write-Error "Cannot get VCD token. Check credentials and wizard completion." }
$headers['Authorization'] = "Bearer $token"
Write-Host "  Authenticated (token obtained)." -ForegroundColor Green

# ---- 取 VCenter 的 thumbprint ----
Write-Host "Getting vCenter SSL thumbprint ($VcFqdn) ..." -ForegroundColor Cyan
$tcp = [System.Net.Sockets.TcpClient]::new($VcFqdn, 443)
$ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
$ssl.AuthenticateAsClient($VcFqdn)
$certBytes = $ssl.RemoteCertificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$thumbprint = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$certBytes)).Thumbprint
$thumbColons = ($thumbprint -split '(.{2})' | Where-Object { $_ }) -join ':'
$ssl.Close(); $tcp.Close()
Write-Host "  thumbprint: $thumbColons" -ForegroundColor DarkGray

# ---- 新增 vCenter (vimServer) ----
Write-Host ""
Write-Host "Adding vCenter $VcFqdn to VCD ..." -ForegroundColor Cyan
$vcBody = @{
    name         = "vcf521-vc"
    displayName  = "VCF 5.2.1 vCenter"
    vcType       = "vCenter"
    url          = "https://$VcFqdn"
    username     = $VcUser
    password     = $VcPw
    thumbprint   = $thumbColons
} | ConvertTo-Json

if ($PSCmdlet.ShouldProcess("$VcFqdn","Add vCenter to VCD")) {
    $vcResp = Invoke-RestMethod -Uri "$sysUrl/admin/extension/vimServer" -Method Post `
        -Headers $headers -Body $vcBody -SkipCertificateCheck
    $vcUrn = $vcResp.id ?? $vcResp.href
    Write-Host "  vCenter registered: $vcUrn" -ForegroundColor Green
} else {
    $vcUrn = 'urn:vcloud:vimserver:DRYRUN'
    Write-Host "  [WhatIf] would register vCenter $VcFqdn" -ForegroundColor DarkGray
}

# ---- 建 Provider VDC ----
Write-Host ""
Write-Host "Creating Provider VDC '$PvdcName' ..." -ForegroundColor Cyan
$pvdcBody = @{
    name           = $PvdcName
    isEnabled      = $true
    vimServer      = @( @{ id = $vcUrn } )
    resourcePoolRefs = @{ vmFolder = @( @{ moRef = $ResourcePoolPath; vimObjectType = "RESOURCE_POOL" } ) }
    computeCapacity = @{
        cpu    = @{ units = "MHz"; allocated = 0; limit = 0 }
        memory = @{ units = "MB";  allocated = 0; limit = 0 }
    }
} | ConvertTo-Json -Depth 5

if ($PSCmdlet.ShouldProcess($PvdcName,'Create Provider VDC')) {
    try {
        $pvdcResp = Invoke-RestMethod -Uri "$sysUrl/admin/extension/providervdc" -Method Post `
            -Headers $headers -Body $pvdcBody -SkipCertificateCheck
        Write-Host "  Provider VDC created: $($pvdcResp.id)" -ForegroundColor Green
    } catch {
        Write-Warning "Provider VDC creation failed: $_"
        Write-Host "  Tip: Provider VDC 通常要在 VCD UI -> Infrastructure -> vCenters 先 refresh 再建." -ForegroundColor Yellow
    }
} else {
    Write-Host "  [WhatIf] would create Provider VDC $PvdcName" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  VCF 5.2.1 接 VCD 後續步驟 (建議 UI 操作)" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "VCD UI: https://$VcdFqdn/ui" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Infrastructure > vCenters > Add"
Write-Host "   - URL: https://$VcFqdn"
Write-Host "   - User: $VcUser"
Write-Host "   - thumbprint: $thumbColons"
Write-Host ""
Write-Host "2. 等 vCenter 同步完成 (Enabled/Active)"
Write-Host ""
Write-Host "3. Infrastructure > Provider VDCs > Add"
Write-Host "   - Name: $PvdcName"
Write-Host "   - vCenter: vcf521-vc"
Write-Host "   - Resource pool: vcf-m02 (或 Resources)"
Write-Host "   - Storage: vcf-m01-vsan01 (vSAN datastore)"
Write-Host "   - Network pool: NSX-T Transport Zone"
Write-Host ""
Write-Host "4. 建 Org + Org VDC (消費資源)" -ForegroundColor DarkGray
