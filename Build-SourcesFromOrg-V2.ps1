<#
.SYNOPSIS
  Standalone - Query a tenant Org VDC and emit configorg.json with
  sources[] populated from existing DIRECT Org VDC Networks.

.DESCRIPTION
  Self-contained: no dependency on lib/, other step scripts, or
  Invoke-MigrationBatch.ps1. Embed everything needed:
    - VCD REST helpers (Connect-VcdApi, Invoke-VcdOpenApi, etc.)
    - Org / Org VDC URN resolution
    - paginated Org VDC Network listing
    - configorg.json emission

  Output: cfg.json shape compatible with Step12-Import-V2.ps1 and
  Step3-Switch-V2.ps1.

.PARAMETER OrgName
  Required. Tenant org name (e.g. 'viqa.qa').

.PARAMETER OrgVdcName
  Org VDC inside OrgName. Defaults to OrgName (same-name convention).

.PARAMETER OrgVdcUrn
  Optional URN override (urn:vcloud:vdc:...). Skips name lookup.

.PARAMETER OutFile
  Default config\configorg.json.

.PARAMETER VcdServer / VcdApiVersion / VcdLoginOrg
  VCD connection info. Defaults to the chunghwa customer values.

.PARAMETER VCenterServer / SourceVdsName / DestinationVdsName
  vCenter info written into the configorg.json (Step12-Import-V1
  uses these). Defaults to the chunghwa customer values.

.PARAMETER DestinationSuffix
  -new is the convention.

.EXAMPLE
  pwsh ./Build-SourcesFromOrg.ps1 -OrgName 'viqa.qa'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OrgName,
    [string] $OrgVdcName,
    [string] $OrgVdcUrn,
    [string] $OutFile,

    [string] $VcdServer          = 'ecloud.cht.com.tw',
    [string] $VcdApiVersion      = '39.1',
    [string] $VcdLoginOrg        = 'System',
    [switch] $VcdSkipCertCheck   = $true,

    [string] $VCenterServer      = 'tpe-vcha022.vs.local',
    [string] $SourceVdsName      = 'vDS-TPE-Resource',
    [string] $DestinationVdsName = 'vDS-TPE-vcd',

    [string] $DestinationSuffix  = '-new'
)

$ErrorActionPreference = 'Stop'


# === Terminal-safe credential prompt (works without CredUI / over SSH) ===
function Get-CredentialSafe {
    param([string] $Message)
    Write-Host ''
    Write-Host "[CRED] $Message" -ForegroundColor Cyan
    $user = Read-Host '  Username'
    if ([string]::IsNullOrEmpty($user)) { throw 'Username empty - aborting' }
    $pw = Read-Host '  Password' -AsSecureString
    if (-not $pw -or $pw.Length -eq 0) { throw 'Password empty - aborting' }
    New-Object System.Management.Automation.PSCredential($user, $pw)
}

if (-not $OrgVdcName) { $OrgVdcName = $OrgName }
if (-not $OutFile)    { $OutFile    = Join-Path $PSScriptRoot 'config\configorg.json' }

# ========================================================================
# Embedded VCD REST helpers (originally lib\VcdRest.ps1)
# ========================================================================

function Connect-VcdApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [string] $Org = 'System',
        [string] $ApiVersion = '40.0',
        [switch] $SkipCertificateCheck
    )
    $base = "https://$Server"
    $sessionUri = if ($Org -eq 'System') {
        "$base/cloudapi/1.0.0/sessions/provider"
    } else {
        "$base/cloudapi/1.0.0/sessions"
    }
    $user = $Credential.UserName
    if ($user -notmatch '@') { $user = "$user@$Org" }
    $pair = "${user}:$($Credential.GetNetworkCredential().Password)"
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{
        Authorization = "Basic $basic"
        Accept        = "application/json;version=$ApiVersion"
    }
    $irmArgs = @{
        Uri = $sessionUri; Method = 'Post'; Headers = $headers
        ResponseHeadersVariable = 'respHeaders'
        StatusCodeVariable      = 'status'
    }
    if ($SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    try { $null = Invoke-RestMethod @irmArgs }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 401) { throw "VCD login 401 at $sessionUri (user: $user)" }
        throw
    }
    $token = $respHeaders['X-VMWARE-VCLOUD-ACCESS-TOKEN']
    if (-not $token) { throw "Login failed: no access token returned (HTTP $status)" }
    [pscustomobject]@{
        BaseUrl              = $base
        Token                = ($token -join '')
        ApiVersion           = $ApiVersion
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }
}

function Invoke-VcdOpenApi {
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'Get',
        $Body
    )
    $headers = @{
        Authorization = "Bearer $($Session.Token)"
        Accept        = "application/json;version=$($Session.ApiVersion)"
    }
    $irmArgs = @{ Uri = "$($Session.BaseUrl)$Path"; Method = $Method; Headers = $headers }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $irmArgs.Body        = ($Body | ConvertTo-Json -Depth 20)
        $irmArgs.ContentType = "application/json;version=$($Session.ApiVersion)"
    }
    if ($Session.SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    Invoke-RestMethod @irmArgs
}

function Invoke-VcdLegacyApi {
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Method = 'Get',
        [xml] $Body, [string] $ContentType
    )
    if ($Uri -notmatch '^https?://') { $Uri = "$($Session.BaseUrl)$Uri" }
    $headers = @{
        Authorization = "Bearer $($Session.Token)"
        Accept        = "application/*+xml;version=$($Session.ApiVersion)"
    }
    $irmArgs = @{ Uri = $Uri; Method = $Method; Headers = $headers }
    if ($Body) { $irmArgs.Body = $Body.OuterXml; $irmArgs.ContentType = $ContentType }
    if ($Session.SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    Invoke-RestMethod @irmArgs
}

function Get-VcdQuery {
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $Type,
        [string] $Filter, [string] $Format = 'records', [int] $PageSize = 128
    )
    $results = New-Object System.Collections.Generic.List[object]
    $page = 1
    do {
        $q = "/api/query?type=$Type&format=$Format&pageSize=$PageSize&page=$page"
        if ($Filter) { $q += "&filter=$([uri]::EscapeDataString($Filter))" }
        $resp = Invoke-VcdLegacyApi -Session $Session -Uri $q
        foreach ($child in $resp.QueryResultRecords.ChildNodes) {
            if ($child.NodeType -ne 'Element') { continue }
            $name = $child.LocalName; if (-not $name) { $name = $child.Name }
            if ($name -eq 'Link') { continue }
            if ($name -notmatch 'Record$') { continue }
            $results.Add($child)
        }
        $hasNext = $resp.QueryResultRecords.Link.rel -contains 'nextPage'
        $page++
    } while ($hasNext)
    $results
}

# ========================================================================
# Main
# ========================================================================

Write-Host "Build-SourcesFromOrg - tenant: $OrgName / VDC: $OrgVdcName" -ForegroundColor Cyan

$vcdCred = Get-CredentialSafe -Message "VCD System administrator credentials ($VcdServer)"
$session = Connect-VcdApi -Server $VcdServer -Credential $vcdCred `
    -Org $VcdLoginOrg -ApiVersion $VcdApiVersion `
    -SkipCertificateCheck:$VcdSkipCertCheck
Write-Host "Logged in to VCD: $VcdServer" -ForegroundColor Green

# Resolve Org VDC URN
if (-not $OrgVdcUrn) {
    Write-Host "Resolving Org VDC URN..." -ForegroundColor Cyan
    $vdcRec = @(Get-VcdQuery -Session $session -Type 'adminOrgVdc' `
        -Filter "name==$OrgVdcName;orgName==$OrgName")
    $vdcRec = @($vdcRec | Sort-Object -Property href -Unique)
    if ($vdcRec.Count -eq 0) {
        throw "Org VDC not found: '$OrgVdcName' in org '$OrgName'"
    }
    if ($vdcRec.Count -gt 1) {
        Write-Host "Multiple matches:" -ForegroundColor Yellow
        $vdcRec | ForEach-Object {
            $u = ($_.href -split '/')[-1]
            "  urn:vcloud:vdc:$u  ($($_.href))"
        }
        throw "Org VDC '$OrgVdcName' is ambiguous; pass -OrgVdcUrn."
    }
    $vdcUuid = ($vdcRec[0].href -split '/')[-1]
    $OrgVdcUrn = "urn:vcloud:vdc:$vdcUuid"
}
Write-Host "Org VDC URN: $OrgVdcUrn" -ForegroundColor Green

# List paginated Org VDC Networks scoped to this VDC, keep DIRECT
function Find-VdcNetworks { param($Resp, $VdcUrn)
    $Resp.values | Where-Object {
        ($_.ownerRef -and $_.ownerRef.id -eq $VdcUrn) -or
        ($_.orgVdc   -and $_.orgVdc.id   -eq $VdcUrn)
    }
}

Write-Host "Listing Org VDC Networks..." -ForegroundColor Cyan
$pageSize = 128; $page = 1; $pageCount = 1
$allNets = New-Object System.Collections.Generic.List[object]
while ($page -le $pageCount) {
    $resp = Invoke-VcdOpenApi -Session $session `
        -Path "/cloudapi/1.0.0/orgVdcNetworks?pageSize=$pageSize&page=$page"
    foreach ($n in (Find-VdcNetworks -Resp $resp -VdcUrn $OrgVdcUrn)) {
        $allNets.Add($n)
    }
    $pageCount = [int]$resp.pageCount
    $page++
}
$total      = $allNets.Count
$directNets = @($allNets | Where-Object { $_.networkType -eq 'DIRECT' })
$other      = $total - $directNets.Count
Write-Host ("  Total in this VDC : {0}" -f $total)
Write-Host ("  DIRECT (kept)     : {0}" -f $directNets.Count) -ForegroundColor Yellow
Write-Host ("  Skipped (other)   : {0}" -f $other)
if ($directNets.Count -eq 0) {
    Write-Warning "No DIRECT networks found - nothing to write."
    return
}

# Skip already-migrated (-new suffix)
$candidates = @($directNets | Where-Object { -not $_.name.EndsWith($DestinationSuffix) })
$skippedNew = $directNets.Count - $candidates.Count
if ($skippedNew -gt 0) {
    Write-Host ("  Skipped -new      : {0}" -f $skippedNew) -ForegroundColor DarkYellow
}

# Build sources[]
$sources = New-Object System.Collections.Generic.List[object]
foreach ($n in $candidates) {
    $subnet = @($n.subnets.values) | Select-Object -First 1
    $gw = if ($subnet) { "$($subnet.gateway)/$($subnet.prefixLength)" } else { '' }
    $sources.Add([ordered]@{
        name              = $n.name
        gateway           = $gw
        networkType       = $n.networkType
        parentNetworkName = $n.parentNetworkId.name
        parentNetworkUrn  = $n.parentNetworkId.id
    })
}

# Compose output config
$out = [ordered]@{
    vCenter = [ordered]@{
        server             = $VCenterServer
        sourceVdsName      = $SourceVdsName
        destinationVdsName = $DestinationVdsName
    }
    vcd = [ordered]@{
        server               = $VcdServer
        apiVersion           = $VcdApiVersion
        org                  = $VcdLoginOrg
        skipCertificateCheck = [bool]$VcdSkipCertCheck
    }
    tenant = [ordered]@{
        orgName    = $OrgName
        orgVdcName = $OrgVdcName
        orgVdcId   = $OrgVdcUrn
    }
    portGroup = [ordered]@{
        source            = $sources[0].name
        destinationSuffix = $DestinationSuffix
        sources           = $sources
    }
}

$outDir = Split-Path $OutFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$out | ConvertTo-Json -Depth 12 | Set-Content -Path $OutFile -Encoding UTF8

Write-Host ""
Write-Host "=== Generated ===" -ForegroundColor Green
Write-Host ("  Tenant         : {0} / {1}" -f $OrgName, $OrgVdcName)
Write-Host ("  Sources emitted: {0}" -f $sources.Count)
Write-Host ("  Output         : {0}" -f $OutFile)
Write-Host ""
Write-Host "Preview:" -ForegroundColor Cyan
$sources | Select-Object -First 10 | ForEach-Object {
    "  - {0,-30}  parent={1}" -f $_.name, $_.parentNetworkName
}
if ($sources.Count -gt 10) { "  ... and $($sources.Count - 10) more" }

Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "  pwsh ./Step12-Import-V2.ps1   # phase 1: build + import"
Write-Host "  pwsh ./Step3-Switch-V2.ps1    # phase 2: switch NICs"
