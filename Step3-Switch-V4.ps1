<#
.SYNOPSIS
  Phase 2 V4 (FULLY STANDALONE) - Switch VM NICs from each source network
  to its -new counterpart. No dependency on lib/ or other step scripts.

.DESCRIPTION
  Reads config\configorg.json (produced by Build-SourcesFromOrg.ps1).
  For each entry in portGroup.sources[]:
    1. Look up the source + dest Org VDC Networks in VCD (the dest must
       already exist - run Step12-Import-V4.ps1 first).
    2. Find every VM in the tenant whose NIC is on the source network.
    3. PUT the modified networkConnectionSection to switch each NIC to
       <source>-new, preserving IP / MAC / IP allocation.
    4. Wait for the per-VM task and record success/failure.

  No step 1 / step 2 invocation. Phase 2 is pure cut-over.

  Result file: state\step3-batch-result.json

.PARAMETER ConfigPath
  Default config\configorg.json.

.PARAMETER Limit
  Only process the first N sources.

.PARAMETER WhatIf
  Dry-run.

.EXAMPLE
  pwsh ./Step3-Switch-V4.ps1 -WhatIf
  pwsh ./Step3-Switch-V4.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath,
    [int]    $Limit = 0
)

$ErrorActionPreference = 'Stop'


# === Terminal-safe credential prompt (works without CredUI / over SSH) ===

# =========================================================================
# OPTIONAL: HARDCODED VCD CREDENTIALS (this script only talks to VCD)
# ----- SECURITY WARNING -----
# If you put real values here, DO NOT commit this file to git!
# Leave both blank to prompt interactively.
# =========================================================================
$DEFAULT_VCD_USERNAME = ''
$DEFAULT_VCD_PASSWORD = ''

function Get-VcdCred {
    param([string] $Message)
    if ($DEFAULT_VCD_USERNAME -and $DEFAULT_VCD_PASSWORD) {
        Write-Host "[CRED-VCD] Using hardcoded VCD credentials (user=$DEFAULT_VCD_USERNAME)" -ForegroundColor DarkYellow
        $sec = ConvertTo-SecureString $DEFAULT_VCD_PASSWORD -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential($DEFAULT_VCD_USERNAME, $sec)
    }
    Get-CredentialSafe -Message $Message
}

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

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config\configorg.json' }
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.portGroup.sources -or @($cfg.portGroup.sources).Count -eq 0) {
    throw "config.portGroup.sources[] is empty."
}
$sources = @($cfg.portGroup.sources)
if ($Limit -gt 0) { $sources = $sources | Select-Object -First $Limit }

$suffix         = $cfg.portGroup.destinationSuffix
$vcdServer      = $cfg.vcd.server
$vcdApiVersion  = $cfg.vcd.apiVersion
$vcdOrgLogin    = $cfg.vcd.org
$vcdSkipCert    = [bool]$cfg.vcd.skipCertificateCheck
$orgName        = $cfg.tenant.orgName
$vdcName        = $cfg.tenant.orgVdcName
$OrgVdcUrn      = if ($cfg.tenant.PSObject.Properties.Name -contains 'orgVdcId') { $cfg.tenant.orgVdcId } else { $null }
$resultPath     = Join-Path $PSScriptRoot 'state\step3-batch-result.json'

Write-Host "=== Phase 2 V4 (standalone, vApp Network aware): switch VM NICs to *-new ===" -ForegroundColor Magenta
Write-Host "  Config : $ConfigPath"
Write-Host "  Sources: $($sources.Count)"
Write-Host "  Tenant : $orgName / $vdcName"
Write-Host "  Action : VMs will move from source -> source$suffix" -ForegroundColor Yellow
Write-Host ""

# ========================================================================
# Embedded VCD REST helpers
# ========================================================================
function Connect-VcdApi {
    param(
        [Parameter(Mandatory)] [string] $Server,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [string] $Org = 'System', [string] $ApiVersion = '40.0',
        [switch] $SkipCertificateCheck
    )
    $base = "https://$Server"
    $sessionUri = if ($Org -eq 'System') { "$base/cloudapi/1.0.0/sessions/provider" } else { "$base/cloudapi/1.0.0/sessions" }
    $user = $Credential.UserName
    if ($user -notmatch '@') { $user = "$user@$Org" }
    $pair = "${user}:$($Credential.GetNetworkCredential().Password)"
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Authorization = "Basic $basic"; Accept = "application/json;version=$ApiVersion" }
    $irmArgs = @{ Uri = $sessionUri; Method = 'Post'; Headers = $headers
        ResponseHeadersVariable = 'respHeaders'; StatusCodeVariable = 'status' }
    if ($SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    try { $null = Invoke-RestMethod @irmArgs }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 401) { throw "VCD login 401 (user: $user)" }
        throw
    }
    $token = $respHeaders['X-VMWARE-VCLOUD-ACCESS-TOKEN']
    if (-not $token) { throw "Login failed: no access token (HTTP $status)" }
    [pscustomobject]@{
        BaseUrl = $base; Token = ($token -join ''); ApiVersion = $ApiVersion
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }
}
function Invoke-VcdOpenApi {
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'Get', $Body)
    $headers = @{ Authorization = "Bearer $($Session.Token)"; Accept = "application/json;version=$($Session.ApiVersion)" }
    $irmArgs = @{ Uri = "$($Session.BaseUrl)$Path"; Method = $Method; Headers = $headers }
    $bodyJson = $null
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $bodyJson = ($Body | ConvertTo-Json -Depth 20)
        $irmArgs.Body = $bodyJson
        $irmArgs.ContentType = "application/json;version=$($Session.ApiVersion)"
    }
    if ($Session.SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    try {
        Invoke-RestMethod @irmArgs
    }
    catch {
        $code = $null
        try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
        $vcdMsg = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $vcdMsg = $_.ErrorDetails.Message
        }
        $hint = "VCD $Method $Path returned HTTP $code"
        if ($vcdMsg) { $hint += "`n  VCD response: $vcdMsg" }
        if ($bodyJson -and $Method -ne 'Get') {
            $preview = if ($bodyJson.Length -gt 600) { $bodyJson.Substring(0,600) + '... (truncated)' } else { $bodyJson }
            $hint += "`n  Request body: $preview"
        }
        throw $hint
    }
}
function Invoke-VcdLegacyApi {
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string] $Uri,
        [string] $Method = 'Get', [xml] $Body, [string] $ContentType)
    if ($Uri -notmatch '^https?://') { $Uri = "$($Session.BaseUrl)$Uri" }
    $headers = @{ Authorization = "Bearer $($Session.Token)"; Accept = "application/*+xml;version=$($Session.ApiVersion)" }
    $irmArgs = @{ Uri = $Uri; Method = $Method; Headers = $headers }
    if ($Body) { $irmArgs.Body = $Body.OuterXml; $irmArgs.ContentType = $ContentType }
    if ($Session.SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    Invoke-RestMethod @irmArgs
}
function Get-VcdQuery {
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string] $Type,
        [string] $Filter, [string] $Format = 'records', [int] $PageSize = 128)
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
function Wait-VcdTask {
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string] $TaskHref, [int] $TimeoutSec = 600)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 3
        $task = Invoke-VcdLegacyApi -Session $Session -Uri $TaskHref
        $statusVal = $task.Task.status
        if ($statusVal -eq 'success') { return $true }
        if ($statusVal -in @('error','aborted','canceled')) {
            throw "VCD task failed ($statusVal): $($task.Task.Error.message)"
        }
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    throw "Timed out waiting for VCD task: $TaskHref"
}
function Find-VdcNetworkOne { param($Resp, $VdcUrn)
    $Resp.values | Where-Object {
        ($_.ownerRef -and $_.ownerRef.id -eq $VdcUrn) -or
        ($_.orgVdc   -and $_.orgVdc.id   -eq $VdcUrn)
    } | Select-Object -First 1
}


# ========================================================================
# V4: vApp Network parent switching helpers
# ========================================================================
function Get-DestOvdcNetInfo {
    param($Session, [string] $DestName, [string] $VdcUrn)
    $resp = Invoke-VcdOpenApi -Session $Session -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$DestName"
    $n = Find-VdcNetworkOne -Resp $resp -VdcUrn $VdcUrn
    if (-not $n) { throw "Dest network '$DestName' not found in target VDC" }
    $uuid = ($n.id -split ':')[-1]
    @{
        urn  = $n.id
        href = "$($Session.BaseUrl)/api/admin/network/$uuid"
        name = $n.name
    }
}

function Switch-VAppNetworkParent {
    param(
        $Session, [string] $OrgHref,
        [string] $SourceName, [string] $DestName, $DestInfo
    )
    Write-Host "  Scanning vApps for vApp Networks parented to '$SourceName'..." -ForegroundColor DarkGray
    $vappRecords = @()
    try { $vappRecords = Get-VcdQuery -Session $Session -Type 'adminVApp' -Filter "isVAppTemplate==false;org==$OrgHref" }
    catch { Write-Warning "  Failed to query vApps: $($_.Exception.Message)"; return @() }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($vapp in $vappRecords) {
        $ncsUri = "$($vapp.href)/networkConfigSection/"
        $ncs = $null
        try { $ncs = Invoke-VcdLegacyApi -Session $Session -Uri $ncsUri }
        catch {
            Write-Warning "  Failed read networkConfigSection for vApp '$($vapp.name)': $($_.Exception.Message)"
            continue
        }
        $matched = New-Object System.Collections.Generic.List[string]
        $configs = @($ncs.NetworkConfigSection.NetworkConfig)
        foreach ($cfg in $configs) {
            $parent = $cfg.Configuration.ParentNetwork
            if (-not $parent) { continue }
            if ($parent.name -eq $SourceName) {
                $parent.SetAttribute('name', $DestName)
                $parent.SetAttribute('href', $DestInfo.href)
                $matched.Add($cfg.networkName)
            }
        }
        if ($matched.Count -gt 0) {
            try {
                $putUri = $ncs.NetworkConfigSection.href
                $task = Invoke-VcdLegacyApi -Session $Session -Uri $putUri -Method Put `
                    -Body ([xml]$ncs.OuterXml) `
                    -ContentType "application/vnd.vmware.vcloud.networkConfigSection+xml;version=$($Session.ApiVersion)"
                Wait-VcdTask -Session $Session -TaskHref $task.Task.href | Out-Null
                Write-Host ("    OK   vApp '{0}': vApp networks [{1}] parent -> {2}" -f $vapp.name, ($matched -join ','), $DestName) -ForegroundColor Green
                $results.Add([ordered]@{ vapp = $vapp.name; vappNetworks = @($matched); result = 'Success'; error = $null })
            }
            catch {
                Write-Warning "    FAIL vApp '$($vapp.name)': $($_.Exception.Message)"
                $results.Add([ordered]@{ vapp = $vapp.name; vappNetworks = @($matched); result = 'Failed'; error = $_.Exception.Message })
            }
        }
    }
    if ($results.Count -eq 0) {
        Write-Host "  No vApp Networks parented to '$SourceName' (skipping vApp net switch)" -ForegroundColor DarkGray
    }
    $results
}

# ========================================================================
# Main: connect, loop sources, switch NICs per source
# ========================================================================

$vcdCred = Get-VcdCred -Message "VCD System administrator credentials ($vcdServer)"
$session = Connect-VcdApi -Server $vcdServer -Credential $vcdCred `
    -Org $vcdOrgLogin -ApiVersion $vcdApiVersion -SkipCertificateCheck:$vcdSkipCert
Write-Host "Logged in to VCD: $vcdServer" -ForegroundColor Green

# Resolve Org URN and href, Org VDC URN
$orgList = Invoke-VcdLegacyApi -Session $session -Uri '/api/org'
$orgMatch = @($orgList.OrgList.Org | Where-Object { $_.name -eq $orgName })
if (-not $orgMatch) { throw "Org not found: $orgName" }
if ($orgMatch.Count -gt 1) { throw "Org name '$orgName' is ambiguous" }
$org     = $orgMatch[0]
$orgHref = $org.href
Write-Host "Org href: $orgHref"

if (-not $OrgVdcUrn) {
    $vdcRec = @(Get-VcdQuery -Session $session -Type 'adminOrgVdc' -Filter "name==$vdcName;orgName==$orgName")
    $vdcRec = @($vdcRec | Sort-Object -Property href -Unique)
    if ($vdcRec.Count -ne 1) { throw "Org VDC '$vdcName' resolution failed ($($vdcRec.Count) matches)" }
    $vdcUuid = ($vdcRec[0].href -split '/')[-1]
    $OrgVdcUrn = "urn:vcloud:vdc:$vdcUuid"
}
Write-Host "Org VDC URN: $OrgVdcUrn"

$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($src in $sources) {
    $i++
    $started    = Get-Date
    $sourceName = $src.name
    $destName   = $sourceName + $suffix
    Write-Host ""
    Write-Host ("[{0}/{1}] {2,-30} -> {3}" -f $i, $sources.Count, $sourceName, $destName) -ForegroundColor Cyan

    $status='ok'; $errMsg=$null; $elapsed=0
    $vmReport = New-Object System.Collections.Generic.List[object]
    try {
        if (-not $PSCmdlet.ShouldProcess($sourceName, "Switch VM NICs to $destName")) {
            $results.Add([ordered]@{ source=$sourceName; dest=$destName; status='whatif'; vmCount=0; vmResults=@(); durationSec=0; error=$null })
            continue
        }

        # Sanity + fetch dest info for vApp net parent switch
        $destInfo = Get-DestOvdcNetInfo -Session $session -DestName $destName -VdcUrn $OrgVdcUrn

        # === V4 step A: switch vApp Network parent (for VMs whose NIC connects via vApp net) ===
        $vappNetResults = Switch-VAppNetworkParent -Session $session -OrgHref $orgHref `
            -SourceName $sourceName -DestName $destName -DestInfo $destInfo

        # Find VMs in the tenant on the source network
        Write-Host "  Scanning Org for VMs on '$sourceName'..." -ForegroundColor DarkGray
        $vmRecords = Get-VcdQuery -Session $session -Type 'adminVM' -Filter "isVAppTemplate==false;org==$orgHref"
        $targets = New-Object System.Collections.Generic.List[object]
        foreach ($vm in $vmRecords) {
            $ncsUri = "$($vm.href)/networkConnectionSection/"
            try { $ncs = Invoke-VcdLegacyApi -Session $session -Uri $ncsUri }
            catch { Write-Warning "  read NIC failed: $($vm.name) - $($_.Exception.Message)"; continue }
            $hit = $ncs.NetworkConnectionSection.NetworkConnection |
                Where-Object { $_.network -eq $sourceName }
            if ($hit) {
                $targets.Add([pscustomobject]@{
                    Name       = $vm.name
                    Href       = $vm.href
                    NicIndexes = ($hit.NetworkConnectionIndex -join ',')
                    Section    = $ncs
                })
            }
        }

        if ($targets.Count -eq 0) {
            Write-Host "  No VMs attached to '$sourceName'; nothing to switch." -ForegroundColor Yellow
            $status = 'ok'
            $elapsed = ((Get-Date) - $started).TotalSeconds
            $results.Add([ordered]@{
                source=$sourceName; dest=$destName; status=$status; vmCount=0; vmResults=@()
                vappNetworkResults=$vappNetResults
                durationSec=[math]::Round($elapsed,2); error=$null
            })
            continue
        }

        Write-Host "  Found $($targets.Count) VM(s) to reconnect:" -ForegroundColor Yellow
        $targets | ForEach-Object { "    {0}  (nic={1})" -f $_.Name, $_.NicIndexes }

        # Reconnect each VM
        foreach ($t in $targets) {
            try {
                $section = $t.Section
                foreach ($nc in $section.NetworkConnectionSection.NetworkConnection) {
                    if ($nc.network -eq $sourceName) { $nc.network = $destName }
                }
                $putUri = $section.NetworkConnectionSection.href
                $task = Invoke-VcdLegacyApi -Session $session -Uri $putUri -Method Put `
                    -Body ([xml]$section.OuterXml) `
                    -ContentType "application/vnd.vmware.vcloud.networkConnectionSection+xml;version=$($session.ApiVersion)"
                Wait-VcdTask -Session $session -TaskHref $task.Task.href | Out-Null
                Write-Host "    OK   $($t.Name)" -ForegroundColor Green
                $vmReport.Add([ordered]@{ vm=$t.Name; nicIndexes=$t.NicIndexes; result='Success'; error=$null })
            }
            catch {
                Write-Warning "    FAIL $($t.Name): $($_.Exception.Message)"
                $vmReport.Add([ordered]@{ vm=$t.Name; nicIndexes=$t.NicIndexes; result='Failed'; error=$_.Exception.Message })
            }
        }

        $elapsed = ((Get-Date) - $started).TotalSeconds
        $okCnt   = ($vmReport | Where-Object { $_.result -eq 'Success' }).Count
        $failCnt = ($vmReport | Where-Object { $_.result -eq 'Failed' }).Count
        if ($failCnt -gt 0) { $status = 'partial' }
        Write-Host ("  [{0}] {1:F1}s   {2} VM ok, {3} VM failed" -f $status.ToUpper(), $elapsed, $okCnt, $failCnt) -ForegroundColor $(if ($failCnt -gt 0) { 'DarkYellow' } else { 'Green' })
    }
    catch {
        $errMsg = $_.Exception.Message
        $status = 'failed'
        $elapsed = ((Get-Date) - $started).TotalSeconds
        Write-Warning ("  [{0}] {1:F1}s : {2}" -f $status.ToUpper(), $elapsed, $errMsg)
    }
    $results.Add([ordered]@{
        source=$sourceName; dest=$destName; status=$status
        vmCount=$vmReport.Count
        vmResults=$vmReport
        vappNetworkResults=$vappNetResults
        durationSec=[math]::Round($elapsed,2)
        error=$errMsg
    })
}

# Summary
$summary = [ordered]@{
    runAt          = (Get-Date).ToString('o')
    createdBy      = 'Step3-Switch-V4.ps1 (standalone)'
    config         = $ConfigPath
    totalSources   = $sources.Count
    processed      = $results.Count
    ok             = ($results | Where-Object { $_.status -eq 'ok' }).Count
    partial        = ($results | Where-Object { $_.status -eq 'partial' }).Count
    failed         = ($results | Where-Object { $_.status -eq 'failed' }).Count
    whatif         = ($results | Where-Object { $_.status -eq 'whatif' }).Count
    totalVmSwitched= ($results | ForEach-Object { ($_.vmResults | Where-Object { $_.result -eq 'Success' }).Count } | Measure-Object -Sum).Sum
    results        = $results
}
$outDir = Split-Path $resultPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$summary | ConvertTo-Json -Depth 12 | Set-Content $resultPath -Encoding UTF8

Write-Host ""
Write-Host "=== PHASE 2 DONE ===" -ForegroundColor Green
Write-Host ("  Sources OK       : {0}" -f $summary.ok)
Write-Host ("  Sources partial  : {0}" -f $summary.partial) -ForegroundColor $(if ($summary.partial) { 'Yellow' } else { 'Green' })
Write-Host ("  Sources failed   : {0}" -f $summary.failed)  -ForegroundColor $(if ($summary.failed)  { 'Red' }    else { 'Green' })
Write-Host ("  Total VM moved   : {0}" -f $summary.totalVmSwitched)
Write-Host ("  Result file      : {0}" -f $resultPath)
