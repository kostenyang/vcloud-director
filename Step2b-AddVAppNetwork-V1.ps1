<#
.SYNOPSIS
  Step 2b V1 (FULLY STANDALONE) - For every -new Org VDC Network that
  Step12-Import already created, ADD it into matching vApps as a Direct
  (bridged) vApp Network. Lets VMs inside vApps connect to the new OVDC
  via the vApp Network layer.

.DESCRIPTION
  Reads config\configorg.json.
  Pre-requisite: Step12-Import-V* already created <source>-new Org VDC
  Networks at the provider + tenant.

  For each source in portGroup.sources[]:
    1. Resolve the dest OVDC network (<source>-new) - get its URN + href.
    2. List vApps in the target tenant.
    3. For each vApp that ALREADY has a vApp Network parented to the
       SOURCE OVDC (i.e. the vApp is currently using <source>), check if
       it already has a vApp Network parented to <source>-new. Skip if
       yes.
    4. Otherwise APPEND a new NetworkConfig to the vApp's
       networkConfigSection:
         networkName        = <source>-new (or override via -NewVAppNetName)
         ParentNetwork name = <source>-new + the constructed href
         FenceMode          = bridged (Direct mode)
       PUT the section back, wait for the task.

  Existing source vApp Network is NOT touched - keeps the old path alive
  so VMs can migrate one by one. After all VMs are off the old vApp net,
  the operator deletes it manually (VCD UI / API).

  Result file: state\step2b-batch-result.json

.PARAMETER ConfigPath
  Default config\configorg.json.

.PARAMETER Limit
  Only process the first N sources.

.PARAMETER NewVAppNetName
  Override the new vApp network's name. Default: same as the dest OVDC
  name (<source>-new). Useful when the vApp already has a network with
  that name and you need a different label.

.PARAMETER WhatIf
  Dry-run.

.EXAMPLE
  pwsh ./Step2b-AddVAppNetwork-V1.ps1 -WhatIf
  pwsh ./Step2b-AddVAppNetwork-V1.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath,
    [int]    $Limit = 0,
    [string] $NewVAppNetName
)

$ErrorActionPreference = 'Stop'

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
$resultPath     = Join-Path $PSScriptRoot 'state\step2b-batch-result.json'

Write-Host "=== Step 2b V1 (standalone): add -new OVDC as vApp Network ===" -ForegroundColor Cyan
Write-Host "  Config : $ConfigPath"
Write-Host "  Sources: $($sources.Count)"
Write-Host "  Tenant : $orgName / $vdcName"
Write-Host ""

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

# ========================================================================
# Embedded VCD REST helpers (same as other V scripts)
# ========================================================================
function Connect-VcdApi {
    param([Parameter(Mandatory)] [string] $Server, [Parameter(Mandatory)] [pscredential] $Credential,
        [string] $Org = 'System', [string] $ApiVersion = '40.0', [switch] $SkipCertificateCheck)
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
    try { $null = Invoke-RestMethod @irmArgs } catch {
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
    try { Invoke-RestMethod @irmArgs }
    catch {
        $code = $null; try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
        $vcdMsg = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $null }
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
        Start-Sleep -Seconds 2
        $task = Invoke-VcdLegacyApi -Session $Session -Uri $TaskHref
        $st = $task.Task.status
        if ($st -eq 'success') { return $true }
        if ($st -in @('error','aborted','canceled')) { throw "VCD task failed ($st): $($task.Task.Error.message)" }
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
# Core logic
# ========================================================================
function Get-DestOvdcNetInfo {
    param($Session, [string] $DestName, [string] $VdcUrn)
    $resp = Invoke-VcdOpenApi -Session $Session -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$DestName"
    $n = Find-VdcNetworkOne -Resp $resp -VdcUrn $VdcUrn
    if (-not $n) { throw "Dest network '$DestName' not found in target VDC - run Step12-Import first." }
    $uuid = ($n.id -split ':')[-1]
    @{ urn = $n.id; href = "$($Session.BaseUrl)/api/admin/network/$uuid"; name = $n.name }
}

function Add-OvdcAsVAppNetwork {
    param(
        $Session, [string] $OrgHref,
        [string] $SourceName, [string] $DestName, $DestInfo,
        [string] $NewName
    )
    if (-not $NewName) { $NewName = $DestName }

    Write-Host "  Scanning vApps with vApp Network parented to '$SourceName'..." -ForegroundColor DarkGray
    $vappRecords = @()
    try { $vappRecords = Get-VcdQuery -Session $Session -Type 'adminVApp' -Filter "org==$OrgHref" }
    catch { Write-Warning "  Failed to query vApps: $($_.Exception.Message)"; return @() }

    $results = New-Object System.Collections.Generic.List[object]
    $vcdNs = 'http://www.vmware.com/vcloud/v1.5'

    foreach ($vapp in $vappRecords) {
        $ncsUri = "$($vapp.href)/networkConfigSection/"
        $ncs = $null
        try { $ncs = Invoke-VcdLegacyApi -Session $Session -Uri $ncsUri }
        catch { Write-Warning "  Failed read networkConfigSection for vApp '$($vapp.name)': $($_.Exception.Message)"; continue }

        # Check vApp's network configs
        $hasSource = $false
        $hasDest   = $false
        foreach ($cfg in @($ncs.NetworkConfigSection.NetworkConfig)) {
            $parent = $cfg.Configuration.ParentNetwork
            if ($parent) {
                if ($parent.name -eq $SourceName) { $hasSource = $true }
                if ($parent.name -eq $DestName)   { $hasDest   = $true }
            }
        }

        if (-not $hasSource) { continue }   # not relevant to this source

        if ($hasDest) {
            Write-Host "    skip vApp '$($vapp.name)': dest vApp net (parent=$DestName) already exists" -ForegroundColor DarkGray
            $results.Add([ordered]@{ vapp = $vapp.name; result = 'AlreadyExists'; error = $null })
            continue
        }

        # Build new NetworkConfig and append
        $sectionXml = [xml]$ncs.OuterXml
        $section    = $sectionXml.DocumentElement   # NetworkConfigSection

        $newNet = $sectionXml.CreateElement('NetworkConfig', $vcdNs)
        $newNet.SetAttribute('networkName', $NewName)

        $cfgEl = $sectionXml.CreateElement('Configuration', $vcdNs)
        $parentEl = $sectionXml.CreateElement('ParentNetwork', $vcdNs)
        $parentEl.SetAttribute('href', $DestInfo.href)
        $parentEl.SetAttribute('name', $DestName)
        $cfgEl.AppendChild($parentEl) | Out-Null

        $fenceEl = $sectionXml.CreateElement('FenceMode', $vcdNs)
        $fenceEl.InnerText = 'bridged'
        $cfgEl.AppendChild($fenceEl) | Out-Null

        $newNet.AppendChild($cfgEl) | Out-Null
        $section.AppendChild($newNet) | Out-Null

        if (-not $PSCmdlet.ShouldProcess($vapp.name, "Add vApp Network '$NewName' (parent=$DestName)")) {
            $results.Add([ordered]@{ vapp = $vapp.name; vappNet = $NewName; parent = $DestName; result = 'WhatIf'; error = $null })
            continue
        }

        try {
            $putUri = $ncs.NetworkConfigSection.href
            $task = Invoke-VcdLegacyApi -Session $Session -Uri $putUri -Method Put `
                -Body $sectionXml `
                -ContentType "application/vnd.vmware.vcloud.networkConfigSection+xml;version=$($Session.ApiVersion)"
            Wait-VcdTask -Session $Session -TaskHref $task.Task.href | Out-Null
            Write-Host "    OK   vApp '$($vapp.name)': added vApp net '$NewName' (parent=$DestName)" -ForegroundColor Green
            $results.Add([ordered]@{ vapp = $vapp.name; vappNet = $NewName; parent = $DestName; result = 'Success'; error = $null })
        }
        catch {
            Write-Warning "    FAIL vApp '$($vapp.name)': $($_.Exception.Message)"
            $results.Add([ordered]@{ vapp = $vapp.name; vappNet = $NewName; parent = $DestName; result = 'Failed'; error = $_.Exception.Message })
        }
    }
    if ($results.Count -eq 0) {
        Write-Host "  No vApps with vApp Network parented to '$SourceName' - nothing to add" -ForegroundColor DarkGray
    }
    $results
}

# ========================================================================
# Main
# ========================================================================
$vcdCred = Get-VcdCred -Message "VCD System administrator credentials ($vcdServer)"
$session = Connect-VcdApi -Server $vcdServer -Credential $vcdCred `
    -Org $vcdOrgLogin -ApiVersion $vcdApiVersion -SkipCertificateCheck:$vcdSkipCert
Write-Host "Logged in to VCD: $vcdServer" -ForegroundColor Green

# Org href
$orgList = Invoke-VcdLegacyApi -Session $session -Uri '/api/org'
$orgMatch = @($orgList.OrgList.Org | Where-Object { $_.name -eq $orgName })
if (-not $orgMatch -or $orgMatch.Count -ne 1) { throw "Org '$orgName' resolution failed ($($orgMatch.Count) matches)" }
$orgHref = $orgMatch[0].href

# Org VDC URN
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
    $newName    = if ($NewVAppNetName) { $NewVAppNetName } else { $destName }
    Write-Host ""
    Write-Host ("[{0}/{1}] {2,-30} : add vApp net '{3}' (parent={2}{4})" -f $i, $sources.Count, $sourceName, $newName, $suffix) -ForegroundColor Cyan

    $status='ok'; $errMsg=$null; $elapsed=0
    $perSource = @()
    try {
        $destInfo = Get-DestOvdcNetInfo -Session $session -DestName $destName -VdcUrn $OrgVdcUrn
        $perSource = Add-OvdcAsVAppNetwork -Session $session -OrgHref $orgHref `
            -SourceName $sourceName -DestName $destName -DestInfo $destInfo `
            -NewName $newName
        $elapsed = ((Get-Date) - $started).TotalSeconds
        $okCnt   = ($perSource | Where-Object { $_.result -eq 'Success' }).Count
        $skipCnt = ($perSource | Where-Object { $_.result -eq 'AlreadyExists' }).Count
        $failCnt = ($perSource | Where-Object { $_.result -eq 'Failed' }).Count
        if ($failCnt -gt 0) { $status = 'partial' }
        Write-Host ("  [{0}] {1:F1}s   added:{2} skipped:{3} failed:{4}" -f $status.ToUpper(), $elapsed, $okCnt, $skipCnt, $failCnt) -ForegroundColor $(if ($failCnt) { 'DarkYellow' } else { 'Green' })
    }
    catch {
        $errMsg = $_.Exception.Message
        $status = 'failed'
        $elapsed = ((Get-Date) - $started).TotalSeconds
        Write-Warning ("  [FAILED] {0:F1}s : {1}" -f $elapsed, $errMsg)
    }
    $results.Add([ordered]@{
        source = $sourceName; dest = $destName; newVAppNetName = $newName
        status = $status
        vappCount = ($perSource | Measure-Object).Count
        vappResults = @($perSource)
        durationSec = [math]::Round($elapsed, 2)
        error = $errMsg
    })
}

# Summary
$summary = [ordered]@{
    runAt          = (Get-Date).ToString('o')
    createdBy      = 'Step2b-AddVAppNetwork-V1.ps1 (standalone)'
    config         = $ConfigPath
    totalSources   = $sources.Count
    processed      = $results.Count
    ok             = ($results | Where-Object { $_.status -eq 'ok' }).Count
    partial        = ($results | Where-Object { $_.status -eq 'partial' }).Count
    failed         = ($results | Where-Object { $_.status -eq 'failed' }).Count
    totalVappsAdded= ($results | ForEach-Object { ($_.vappResults | Where-Object { $_.result -eq 'Success' }).Count } | Measure-Object -Sum).Sum
    results        = $results
}
$outDir = Split-Path $resultPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$summary | ConvertTo-Json -Depth 12 | Set-Content $resultPath -Encoding UTF8

Write-Host ""
Write-Host "=== STEP 2b DONE ===" -ForegroundColor Green
Write-Host ("  OK            : {0}" -f $summary.ok)
Write-Host ("  Partial       : {0}" -f $summary.partial) -ForegroundColor $(if ($summary.partial) { 'Yellow' } else { 'Green' })
Write-Host ("  Failed        : {0}" -f $summary.failed)  -ForegroundColor $(if ($summary.failed)  { 'Red' }    else { 'Green' })
Write-Host ("  vApps updated : {0}" -f $summary.totalVappsAdded)
Write-Host ("  Result        : {0}" -f $resultPath)
