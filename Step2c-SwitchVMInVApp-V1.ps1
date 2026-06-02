<#
.SYNOPSIS
  Step 2c V1 (FULLY STANDALONE) - Inside each vApp, move VM NICs from the
  OLD vApp Network (parent = source OVDC) to the NEW vApp Network
  (parent = dest OVDC, added earlier by Step2b-AddVAppNetwork-V1.ps1).

.DESCRIPTION
  Reads config\configorg.json.

  Prerequisites:
    - Step12-Import already created <source>-new OVDC networks.
    - Step2b-AddVAppNetwork already appended the new vApp Network entry
      (default name = <source>-new) into vApps that had a vApp net
      parented to source OVDC.

  For each source in portGroup.sources[]:
    Look at every vApp in the tenant.
      a. Find vApp Networks (NetworkConfig) whose ParentNetwork.name ==
         source OVDC name. Collect their networkName(s); that is the
         OLD vApp net name list for this vApp (could be more than one).
      b. Confirm a vApp Network named <source>-new (or -NewVAppNetName)
         exists in this vApp. Skip vApp with a warning if not (Step2b
         was not run, or vApp didn't qualify).
      c. For each VM in this vApp:
           - Read networkConnectionSection.
           - For every NIC whose .network is in the OLD list, change
             .network = the NEW vApp net name.
           - If any NIC was changed, PUT the section, Wait-VcdTask.
      d. Record per-VM result.

  Existing source vApp Network is NOT deleted. After all VMs are moved,
  the operator can clean it up manually (or via the planned cleanup
  script).

  Result file: state\step2c-batch-result.json

.PARAMETER ConfigPath
  Default config\configorg.json.

.PARAMETER Limit
  Only process the first N sources.

.PARAMETER NewVAppNetName
  Override the new vApp net name expected inside vApps. Default: same as
  the dest OVDC name (<source>-new). Must match whatever was used in
  Step2b. If Step2b used the default, this also stays default.

.PARAMETER WhatIf
  Dry-run.

.EXAMPLE
  pwsh ./Step2c-SwitchVMInVApp-V1.ps1 -WhatIf
  pwsh ./Step2c-SwitchVMInVApp-V1.ps1
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
$resultPath     = Join-Path $PSScriptRoot 'state\step2c-batch-result.json'

Write-Host "=== Step 2c V1 (standalone): switch VM NICs inside vApps ===" -ForegroundColor Magenta
Write-Host "  Config : $ConfigPath"
Write-Host "  Sources: $($sources.Count)"
Write-Host "  Tenant : $orgName / $vdcName"
Write-Host "  Action : VM NICs move from old vApp net (parent=source) -> new vApp net (parent=dest)" -ForegroundColor Yellow
Write-Host ""

# =========================================================================
# OPTIONAL: HARDCODED VCD CREDENTIALS
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

# ========================================================================
# Embedded VCD REST helpers
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

# ========================================================================
# Core: per-vApp switch
# ========================================================================
function Invoke-VAppVmNicSwitch {
    param(
        $Session, $VAppRecord,
        [string] $SourceOvdcName, [string] $NewVAppNetName
    )
    # Returns list of per-VM result objects for this vApp
    $vappName = $VAppRecord.name
    $ncsConfigUri = "$($VAppRecord.href)/networkConfigSection/"
    try {
        $ncsConfig = Invoke-VcdLegacyApi -Session $Session -Uri $ncsConfigUri
    }
    catch {
        return @( [ordered]@{ vapp = $vappName; vm = $null; status = 'vapp-cfg-read-failed'; error = $_.Exception.Message } )
    }

    # Find OLD vApp net names whose ParentNetwork = source OVDC
    $oldVAppNetNames = New-Object System.Collections.Generic.List[string]
    $hasNewName = $false
    foreach ($cfg in @($ncsConfig.NetworkConfigSection.NetworkConfig)) {
        if ($cfg.networkName -eq $NewVAppNetName) { $hasNewName = $true }
        $parent = $cfg.Configuration.ParentNetwork
        if ($parent -and $parent.name -eq $SourceOvdcName) {
            $oldVAppNetNames.Add($cfg.networkName)
        }
    }

    if ($oldVAppNetNames.Count -eq 0) {
        return @()   # this vApp doesn't have anything parented to source - skip silently
    }
    if (-not $hasNewName) {
        Write-Warning "  vApp '$vappName': old vApp nets [$($oldVAppNetNames -join ',')] but new vApp net '$NewVAppNetName' not present. Run Step2b first."
        return @( [ordered]@{ vapp = $vappName; vm = $null; status = 'new-vappnet-missing'; oldVAppNets = $oldVAppNetNames.ToArray(); error = $null } )
    }

    Write-Host ("  vApp '{0}': old vApp net(s) [{1}] -> '{2}'" -f $vappName, ($oldVAppNetNames -join ','), $NewVAppNetName) -ForegroundColor DarkGray

    # Now find VMs in this vApp by parsing the vApp XML's <Children>
    # Easier: query adminVM filtered by vApp href
    $vmRecords = @()
    try {
        $vmRecords = Get-VcdQuery -Session $Session -Type 'adminVM' `
            -Filter "isVAppTemplate==false;container==$($VAppRecord.href)"
    }
    catch {
        return @( [ordered]@{ vapp = $vappName; vm = $null; status = 'vm-list-failed'; error = $_.Exception.Message } )
    }

    $oldSet = @{}
    foreach ($n in $oldVAppNetNames) { $oldSet[$n] = $true }

    $vmReports = New-Object System.Collections.Generic.List[object]
    foreach ($vm in $vmRecords) {
        $ncsUri = "$($vm.href)/networkConnectionSection/"
        $ncs = $null
        try { $ncs = Invoke-VcdLegacyApi -Session $Session -Uri $ncsUri }
        catch {
            $vmReports.Add([ordered]@{ vapp = $vappName; vm = $vm.name; status = 'nic-read-failed'; error = $_.Exception.Message })
            continue
        }

        $changed = $false
        $changedNicIdx = @()
        foreach ($nc in @($ncs.NetworkConnectionSection.NetworkConnection)) {
            if ($oldSet.ContainsKey($nc.network)) {
                $changedNicIdx += $nc.NetworkConnectionIndex
                $nc.network = $NewVAppNetName
                $changed = $true
            }
        }

        if (-not $changed) { continue }   # this VM has no NIC on the old vApp net

        if (-not $PSCmdlet.ShouldProcess($vm.name, "Switch NIC(s) [$($changedNicIdx -join ',')] -> $NewVAppNetName")) {
            $vmReports.Add([ordered]@{ vapp = $vappName; vm = $vm.name; nicIndexes = ($changedNicIdx -join ','); status = 'whatif'; error = $null })
            continue
        }

        try {
            $putUri = $ncs.NetworkConnectionSection.href
            $task = Invoke-VcdLegacyApi -Session $Session -Uri $putUri -Method Put `
                -Body ([xml]$ncs.OuterXml) `
                -ContentType "application/vnd.vmware.vcloud.networkConnectionSection+xml;version=$($Session.ApiVersion)"
            Wait-VcdTask -Session $Session -TaskHref $task.Task.href | Out-Null
            Write-Host "    OK   $($vm.name) [nic=$($changedNicIdx -join ',')]" -ForegroundColor Green
            $vmReports.Add([ordered]@{ vapp = $vappName; vm = $vm.name; nicIndexes = ($changedNicIdx -join ','); status = 'ok'; error = $null })
        }
        catch {
            Write-Warning "    FAIL $($vm.name): $($_.Exception.Message)"
            $vmReports.Add([ordered]@{ vapp = $vappName; vm = $vm.name; nicIndexes = ($changedNicIdx -join ','); status = 'failed'; error = $_.Exception.Message })
        }
    }
    return $vmReports.ToArray()
}

# ========================================================================
# Main
# ========================================================================
$vcdCred = Get-VcdCred -Message "VCD System administrator credentials ($vcdServer)"
$session = Connect-VcdApi -Server $vcdServer -Credential $vcdCred `
    -Org $vcdOrgLogin -ApiVersion $vcdApiVersion -SkipCertificateCheck:$vcdSkipCert
Write-Host "Logged in to VCD: $vcdServer" -ForegroundColor Green

# Resolve org href
$orgList  = Invoke-VcdLegacyApi -Session $session -Uri '/api/org'
$orgMatch = @($orgList.OrgList.Org | Where-Object { $_.name -eq $orgName })
if (-not $orgMatch -or $orgMatch.Count -ne 1) { throw "Org '$orgName' resolution failed ($($orgMatch.Count) matches)" }
$orgHref = $orgMatch[0].href

# Resolve Org VDC URN (informational - we don't actually filter networks per VDC here)
if (-not $OrgVdcUrn) {
    $vdcRec = @(Get-VcdQuery -Session $session -Type 'adminOrgVdc' -Filter "name==$vdcName;orgName==$orgName")
    $vdcRec = @($vdcRec | Sort-Object -Property href -Unique)
    if ($vdcRec.Count -ne 1) { throw "Org VDC '$vdcName' resolution failed ($($vdcRec.Count) matches)" }
    $vdcUuid = ($vdcRec[0].href -split '/')[-1]
    $OrgVdcUrn = "urn:vcloud:vdc:$vdcUuid"
}
Write-Host "Org VDC URN: $OrgVdcUrn"

# Cache all vApps in the org ONCE (per-source loop reuses)
Write-Host "Listing vApps in org..." -ForegroundColor Cyan
$allVApps = @()
try { $allVApps = Get-VcdQuery -Session $session -Type 'adminVApp' -Filter "org==$orgHref" }
catch { throw "Failed to list vApps: $($_.Exception.Message)" }
Write-Host ("  Found {0} vApp(s)" -f $allVApps.Count)

$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($src in $sources) {
    $i++
    $started     = Get-Date
    $sourceName  = $src.name
    $destName    = $sourceName + $suffix
    $effectiveNewName = if ($NewVAppNetName) { $NewVAppNetName } else { $destName }
    Write-Host ""
    Write-Host ("[{0}/{1}] {2,-30} : VMs use vApp net '{3}' (parent={4})" -f $i, $sources.Count, $sourceName, $effectiveNewName, $destName) -ForegroundColor Cyan

    $status='ok'; $errMsg=$null; $elapsed=0
    $allVmReports = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($vapp in $allVApps) {
            $perVApp = Invoke-VAppVmNicSwitch -Session $session -VAppRecord $vapp `
                -SourceOvdcName $sourceName -NewVAppNetName $effectiveNewName
            foreach ($r in $perVApp) { $allVmReports.Add($r) }
        }
        $okCnt   = ($allVmReports | Where-Object { $_.status -eq 'ok' }).Count
        $failCnt = ($allVmReports | Where-Object { $_.status -eq 'failed' }).Count
        $missCnt = ($allVmReports | Where-Object { $_.status -eq 'new-vappnet-missing' }).Count
        if ($failCnt -gt 0) { $status = 'partial' }
        $elapsed = ((Get-Date) - $started).TotalSeconds
        Write-Host ("  [{0}] {1:F1}s   ok:{2} failed:{3} new-vappnet-missing:{4}" -f $status.ToUpper(), $elapsed, $okCnt, $failCnt, $missCnt) -ForegroundColor $(if ($failCnt) { 'DarkYellow' } else { 'Green' })
    }
    catch {
        $errMsg = $_.Exception.Message
        $status = 'failed'
        $elapsed = ((Get-Date) - $started).TotalSeconds
        Write-Warning ("  [FAILED] {0:F1}s : {1}" -f $elapsed, $errMsg)
    }
    $results.Add([ordered]@{
        source         = $sourceName
        dest           = $destName
        newVAppNetName = $effectiveNewName
        status         = $status
        vmCount        = ($allVmReports | Where-Object { $_.vm }).Count
        vmResults      = @($allVmReports)
        durationSec    = [math]::Round($elapsed, 2)
        error          = $errMsg
    })
}

# Summary
$summary = [ordered]@{
    runAt           = (Get-Date).ToString('o')
    createdBy       = 'Step2c-SwitchVMInVApp-V1.ps1 (standalone)'
    config          = $ConfigPath
    totalSources    = $sources.Count
    processed       = $results.Count
    ok              = ($results | Where-Object { $_.status -eq 'ok' }).Count
    partial         = ($results | Where-Object { $_.status -eq 'partial' }).Count
    failed          = ($results | Where-Object { $_.status -eq 'failed' }).Count
    totalVmSwitched = ($results | ForEach-Object { ($_.vmResults | Where-Object { $_.status -eq 'ok' }).Count } | Measure-Object -Sum).Sum
    results         = $results
}
$outDir = Split-Path $resultPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$summary | ConvertTo-Json -Depth 12 | Set-Content $resultPath -Encoding UTF8

Write-Host ""
Write-Host "=== STEP 2c DONE ===" -ForegroundColor Green
Write-Host ("  OK sources       : {0}" -f $summary.ok)
Write-Host ("  Partial sources  : {0}" -f $summary.partial) -ForegroundColor $(if ($summary.partial) { 'Yellow' } else { 'Green' })
Write-Host ("  Failed sources   : {0}" -f $summary.failed)  -ForegroundColor $(if ($summary.failed)  { 'Red' }    else { 'Green' })
Write-Host ("  Total VM moved   : {0}" -f $summary.totalVmSwitched)
Write-Host ("  Result file      : {0}" -f $resultPath)
