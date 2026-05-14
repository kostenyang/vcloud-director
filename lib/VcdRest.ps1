<#
.SYNOPSIS
  vCloud Director 10.6.1 REST API 共用函式 (API version 40.0)。
  由 scripts\2-Import-And-Switch-TenantNic.ps1 dot-source 載入。

  提供:
    Connect-VcdApi      - 登入 VCD,取得 bearer token,回傳 session 物件
    Invoke-VcdOpenApi   - 呼叫 /cloudapi (OpenAPI, JSON)
    Invoke-VcdLegacyApi - 呼叫 /api (legacy, XML)
    Get-VcdQuery        - 呼叫 query service (/api/query)
#>

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
    # System (provider) 管理員走 /sessions/provider,租戶管理員走 /sessions
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
        Uri             = $sessionUri
        Method          = 'Post'
        Headers         = $headers
        ResponseHeadersVariable = 'respHeaders'
        StatusCodeVariable      = 'status'
    }
    if ($SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }

    $null = Invoke-RestMethod @irmArgs
    $token = $respHeaders['X-VMWARE-VCLOUD-ACCESS-TOKEN']
    if (-not $token) { throw "登入失敗,沒有取得 access token (HTTP $status)" }

    [pscustomobject]@{
        BaseUrl              = $base
        Token                = ($token -join '')
        ApiVersion           = $ApiVersion
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }
}

function Invoke-VcdOpenApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $Path,          # 例如 /cloudapi/1.0.0/orgVdcNetworks
        [string] $Method = 'Get',
        $Body
    )
    $headers = @{
        Authorization = "Bearer $($Session.Token)"
        Accept        = "application/json;version=$($Session.ApiVersion)"
    }
    $irmArgs = @{
        Uri     = "$($Session.BaseUrl)$Path"
        Method  = $Method
        Headers = $headers
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $irmArgs.Body        = ($Body | ConvertTo-Json -Depth 20)
        $irmArgs.ContentType = "application/json;version=$($Session.ApiVersion)"
    }
    if ($Session.SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    Invoke-RestMethod @irmArgs
}

function Invoke-VcdLegacyApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $Uri,           # 完整 URL 或 /api/... 路徑
        [string] $Method = 'Get',
        [xml] $Body,
        [string] $ContentType
    )
    if ($Uri -notmatch '^https?://') { $Uri = "$($Session.BaseUrl)$Uri" }
    $headers = @{
        Authorization = "Bearer $($Session.Token)"
        Accept        = "application/*+xml;version=$($Session.ApiVersion)"
    }
    $irmArgs = @{
        Uri     = $Uri
        Method  = $Method
        Headers = $headers
    }
    if ($Body) {
        $irmArgs.Body        = $Body.OuterXml
        $irmArgs.ContentType = $ContentType
    }
    if ($Session.SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    Invoke-RestMethod @irmArgs
}

function Get-VcdQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $Type,          # 例如 vm, orgVdcNetwork
        [string] $Filter,
        [string] $Format = 'records',
        [int] $PageSize = 128
    )
    $results = New-Object System.Collections.Generic.List[object]
    $page = 1
    do {
        $q = "/api/query?type=$Type&format=$Format&pageSize=$PageSize&page=$page"
        if ($Filter) { $q += "&filter=$([uri]::EscapeDataString($Filter))" }
        $resp = Invoke-VcdLegacyApi -Session $Session -Uri $q
        $records = $resp.QueryResultRecords.ChildNodes | Where-Object { $_.NodeType -eq 'Element' }
        foreach ($r in $records) { $results.Add($r) }
        $hasNext = $resp.QueryResultRecords.Link.rel -contains 'nextPage'
        $page++
    } while ($hasNext)
    $results
}

function Wait-VcdTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $TaskHref,
        [int] $TimeoutSec = 600
    )
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 3
        $task = Invoke-VcdLegacyApi -Session $Session -Uri $TaskHref
        $statusVal = $task.Task.status
        if ($statusVal -eq 'success') { return $true }
        if ($statusVal -in @('error','aborted','canceled')) {
            throw "VCD task 失敗 ($statusVal): $($task.Task.Error.message)"
        }
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    throw "VCD task 等待逾時 ($TimeoutSec 秒): $TaskHref"
}
