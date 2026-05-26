<#
.SYNOPSIS
  Phase 1 V2 (FULLY STANDALONE) - Build dest portgroups + import as Org VDC
  Networks for every source in cfg.portGroup.sources[]. Does NOT touch VMs.
  No dependency on lib/ or other step scripts.

.DESCRIPTION
  Reads config\configorg.json (produced by Build-SourcesFromOrg.ps1).
  For each entry in portGroup.sources[]:
    1. Clone the source vDS portgroup to dest vDS as <name><suffix>
       (cross-vDS auto-remaps uplink names by index, preserves teaming).
    2. Detect source Org VDC Network type (OPAQUE / DIRECT) in VCD.
    3. Create the destination Org VDC Network:
       OPAQUE -> backingNetworkId = the new portgroup moref
       DIRECT -> first create a new Provider external network using the new
                 portgroup as backing, then a DIRECT Org VDC Network
                 pointing at it (parentNetworkId).
    4. Record per-source result.

  Step 3 (NIC switch) is NOT invoked. VMs stay on source networks.

  Result file: state\step12-batch-result.json

.PARAMETER ConfigPath
  Default config\configorg.json.

.PARAMETER Limit
  Only process the first N sources.

.PARAMETER WhatIf
  Dry-run.

.PARAMETER SeparateCredentials
  Default ONE shared credential prompt; pass to prompt twice.

.EXAMPLE
  pwsh ./Step12-Import-V2.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath,
    [int]    $Limit = 0,
    [switch] $SeparateCredentials
)

$ErrorActionPreference = 'Stop'


# === Terminal-safe credential prompt (works without CredUI / over SSH) ===

# =========================================================================
# OPTIONAL: HARDCODED CREDENTIALS (filled in here means no prompt)
# ----- SECURITY WARNING -----
# If you put real values here, DO NOT commit this file to git!
# These take precedence over the Read-Host prompt below.
# Leave both blank to prompt interactively.
# =========================================================================
$DEFAULT_USERNAME = ''
$DEFAULT_PASSWORD = ''

function Get-HardcodedOrPromptCred {
    param([string] $Message)
    if ($DEFAULT_USERNAME -and $DEFAULT_PASSWORD) {
        Write-Host "[CRED] Using hardcoded credentials from script header (user=$DEFAULT_USERNAME)" -ForegroundColor DarkYellow
        $sec = ConvertTo-SecureString $DEFAULT_PASSWORD -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential($DEFAULT_USERNAME, $sec)
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

# config.local.json overrides
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $cfg.portGroup.sources -or @($cfg.portGroup.sources).Count -eq 0) {
    throw "config.portGroup.sources[] is empty. Run Build-SourcesFromOrg.ps1 first."
}
$sources = @($cfg.portGroup.sources)
if ($Limit -gt 0) { $sources = $sources | Select-Object -First $Limit }

$suffix             = $cfg.portGroup.destinationSuffix
$srcVdsName         = $cfg.vCenter.sourceVdsName
$dstVdsName         = $cfg.vCenter.destinationVdsName
$vcServer           = $cfg.vCenter.server
$vcdServer          = $cfg.vcd.server
$vcdApiVersion      = $cfg.vcd.apiVersion
$vcdOrgLogin        = $cfg.vcd.org
$vcdSkipCert        = [bool]$cfg.vcd.skipCertificateCheck
$orgName            = $cfg.tenant.orgName
$vdcName            = $cfg.tenant.orgVdcName
$OrgVdcUrn          = if ($cfg.tenant.PSObject.Properties.Name -contains 'orgVdcId') { $cfg.tenant.orgVdcId } else { $null }
$resultPath         = Join-Path $PSScriptRoot 'state\step12-batch-result.json'

Write-Host "=== Phase 1 V2 (standalone): build portgroup + import Org VDC Network ===" -ForegroundColor Cyan
Write-Host "  Config         : $ConfigPath"
Write-Host "  Sources        : $($sources.Count)"
Write-Host "  Source vDS     : $srcVdsName"
Write-Host "  Dest vDS       : $dstVdsName"
Write-Host "  Org / VDC      : $orgName / $vdcName"
Write-Host "  NIC switch     : NOT INVOKED" -ForegroundColor Yellow
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
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $irmArgs.Body = ($Body | ConvertTo-Json -Depth 20)
        $irmArgs.ContentType = "application/json;version=$($Session.ApiVersion)"
    }
    if ($Session.SkipCertificateCheck) { $irmArgs.SkipCertificateCheck = $true }
    Invoke-RestMethod @irmArgs
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
function Find-VdcNetworkOne { param($Resp, $VdcUrn)
    $Resp.values | Where-Object {
        ($_.ownerRef -and $_.ownerRef.id -eq $VdcUrn) -or
        ($_.orgVdc   -and $_.orgVdc.id   -eq $VdcUrn)
    } | Select-Object -First 1
}

# ========================================================================
# Embedded step 1 logic - build / reuse a dest portgroup
# ========================================================================
function Build-OnePortgroupClone {
    param($SrcVds, $DestVds, [string] $SourceName, [string] $DestName, [string] $Suffix)
    if (-not [string]::IsNullOrEmpty($Suffix) -and $SourceName.EndsWith($Suffix)) {
        return @{ status='skipped-suffix'; pg=$null; vlan=$null; message="source already ends with $Suffix" }
    }
    $src = Get-VDPortgroup -VDSwitch $SrcVds -Name $SourceName -ErrorAction Stop
    $vlan = $src.ExtensionData.Config.DefaultPortConfig.Vlan.VlanId

    $existing = Get-VDPortgroup -VDSwitch $DestVds -Name $DestName -ErrorAction SilentlyContinue
    if ($existing) {
        return @{ status='reused'; pg=$existing; vlan=$vlan; message='dest already exists' }
    }

    if ($SrcVds.Name -eq $DestVds.Name) {
        $pg = New-VDPortgroup -VDSwitch $DestVds -Name $DestName -ReferencePortgroup $src
        return @{ status='ok'; pg=$pg; vlan=$vlan; message='created (same vDS)' }
    }

    # Cross-vDS: remap uplink names by index, preserve teaming
    $srcCfg = $src.ExtensionData.Config
    $spec   = New-Object VMware.Vim.DVPortgroupConfigSpec
    $spec.Name              = $DestName
    $spec.Type              = $srcCfg.Type
    $spec.NumPorts          = $srcCfg.NumPorts
    $spec.AutoExpand        = $srcCfg.AutoExpand
    $spec.Description       = $srcCfg.Description
    $spec.DefaultPortConfig = $srcCfg.DefaultPortConfig
    if ($spec.DefaultPortConfig.UplinkTeamingPolicy -and
        $spec.DefaultPortConfig.UplinkTeamingPolicy.UplinkPortOrder) {
        $srcUplinks = @($SrcVds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
        $dstUplinks = @($DestVds.ExtensionData.Config.UplinkPortPolicy.UplinkPortName)
        $pairCount  = [Math]::Min($srcUplinks.Count, $dstUplinks.Count)
        $uplinkMap  = @{}
        for ($i = 0; $i -lt $pairCount; $i++) { $uplinkMap[$srcUplinks[$i]] = $dstUplinks[$i] }
        Write-Host ("    Uplink map: {0}" -f (($uplinkMap.GetEnumerator() | ForEach-Object { "'$($_.Key)'->'$($_.Value)'" }) -join ', ')) -ForegroundColor DarkGray
        $order = $spec.DefaultPortConfig.UplinkTeamingPolicy.UplinkPortOrder
        $remappedActive  = New-Object System.Collections.Generic.List[string]
        foreach ($u in @($order.ActiveUplinkPort | Where-Object { $_ })) {
            if ($uplinkMap.ContainsKey($u)) { $remappedActive.Add($uplinkMap[$u]) }
            else { Write-Warning "    Source uplink '$u' (active) has no dest counterpart; dropping" }
        }
        $remappedStandby = New-Object System.Collections.Generic.List[string]
        foreach ($u in @($order.StandbyUplinkPort | Where-Object { $_ })) {
            if ($uplinkMap.ContainsKey($u)) { $remappedStandby.Add($uplinkMap[$u]) }
            else { Write-Warning "    Source uplink '$u' (standby) has no dest counterpart; dropping" }
        }
        $order.ActiveUplinkPort  = $remappedActive.ToArray()
        $order.StandbyUplinkPort = $remappedStandby.ToArray()
    }
    $taskMoRef = $DestVds.ExtensionData.AddDVPortgroup_Task(@($spec))
    $deadline  = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $taskInfo = Get-View -Id $taskMoRef
    } while ($taskInfo.Info.State -notin @('success', 'error') -and (Get-Date) -lt $deadline)
    if ($taskInfo.Info.State -ne 'success') {
        throw "AddDVPortgroup failed: $($taskInfo.Info.Error.LocalizedMessage)"
    }
    $pg = Get-VDPortgroup -VDSwitch $DestVds -Name $DestName
    return @{ status='ok'; pg=$pg; vlan=$vlan; message='created (cross-vDS, uplinks remapped)' }
}

# ========================================================================
# Embedded step 2 v2 logic - create / reuse Org VDC Network
# ========================================================================
function Wait-OrgVdcNetworkRealized {
    param($Session, [string] $Name, [string] $VdcUrn, [int] $TimeoutMin = 5)
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    do {
        Start-Sleep -Seconds 4
        $check = Invoke-VcdOpenApi -Session $Session -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$Name"
        $net   = Find-VdcNetworkOne -Resp $check -VdcUrn $VdcUrn
    } while (-not ($net -and $net.status -eq 'REALIZED') -and (Get-Date) -lt $deadline)
    if (-not ($net -and $net.status -eq 'REALIZED')) {
        throw "Org VDC Network '$Name' did not reach REALIZED state"
    }
    $net
}

function Import-OneOrgVdcNetwork {
    param($Session, [string] $VdcUrn, [string] $VdcName,
          [string] $SourceName, [string] $DestName,
          [string] $DestPg, [string] $PgMoref, [string] $Suffix)

    # Look up source
    $srcResp = Invoke-VcdOpenApi -Session $Session -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$SourceName"
    $srcNet  = Find-VdcNetworkOne -Resp $srcResp -VdcUrn $VdcUrn
    if (-not $srcNet) { throw "Source Org VDC Network '$SourceName' not found in '$VdcName'" }
    $srcType = $srcNet.networkType
    if ($srcType -notin @('OPAQUE', 'DIRECT')) {
        throw "Source networkType must be OPAQUE or DIRECT, got '$srcType'"
    }

    # Skip if dest already exists
    $existingResp = Invoke-VcdOpenApi -Session $Session -Path "/cloudapi/1.0.0/orgVdcNetworks?filter=name==$DestName"
    $existing = Find-VdcNetworkOne -Resp $existingResp -VdcUrn $VdcUrn
    if ($existing) {
        return @{ status='reused-net'; netUrn=$existing.id; netType=$existing.networkType
                  extUrn=$(if ($existing.networkType -eq 'DIRECT' -and $existing.parentNetworkId) { $existing.parentNetworkId.id }); srcType=$srcType }
    }

    if ($srcType -eq 'OPAQUE') {
        $body = @{
            name = $DestName
            description = "Imported by Step12-Import-V1 from DV portgroup $DestPg"
            ownerRef = @{ id = $VdcUrn }
            networkType = 'OPAQUE'
            backingNetworkId = $PgMoref
            backingNetworkType = 'DV_PORTGROUP'
            subnets = $srcNet.subnets
        }
        $null = Invoke-VcdOpenApi -Session $Session -Path '/cloudapi/1.0.0/orgVdcNetworks' -Method Post -Body $body
        $net = Wait-OrgVdcNetworkRealized -Session $Session -Name $DestName -VdcUrn $VdcUrn
        return @{ status='ok-opaque'; netUrn=$net.id; netType='OPAQUE'; extUrn=$null; srcType=$srcType }
    }

    # DIRECT path
    $srcParentExtId = $srcNet.parentNetworkId.id
    if (-not $srcParentExtId) { throw "Source DIRECT network has no parentNetworkId" }
    $srcExt = Invoke-VcdOpenApi -Session $Session -Path "/cloudapi/1.0.0/externalNetworks/$srcParentExtId"
    $srcBacking = @($srcExt.networkBackings.values) | Select-Object -First 1
    if (-not $srcBacking) { throw "Source external network '$($srcExt.name)' has no networkBackings" }
    $vimServerUrn = $srcBacking.networkProvider.id
    $destExtName  = $srcExt.name + $Suffix

    # Reuse / create dest ext network
    $extQuery = Invoke-VcdOpenApi -Session $Session -Path "/cloudapi/1.0.0/externalNetworks?filter=name==$destExtName"
    $destExt  = @($extQuery.values) | Select-Object -First 1
    if (-not $destExt) {
        $extBody = @{
            name = $destExtName
            description = "Created by Step12-Import-V1 from '$($srcExt.name)'"
            subnets = $srcExt.subnets
            networkBackings = @{
                values = @( @{
                    backingId = $PgMoref
                    backingTypeValue = 'DV_PORTGROUP'
                    networkProvider = @{ id = $vimServerUrn }
                } )
            }
        }
        $null = Invoke-VcdOpenApi -Session $Session -Path '/cloudapi/1.0.0/externalNetworks' -Method Post -Body $extBody
        $deadline = (Get-Date).AddMinutes(5)
        do {
            Start-Sleep -Seconds 4
            $extCheck = Invoke-VcdOpenApi -Session $Session -Path "/cloudapi/1.0.0/externalNetworks?filter=name==$destExtName"
            $destExt  = @($extCheck.values) | Select-Object -First 1
        } while (-not $destExt -and (Get-Date) -lt $deadline)
        if (-not $destExt) { throw "External network '$destExtName' did not appear in time" }
    }
    # Create DIRECT Org VDC Network
    $body = @{
        name = $DestName
        description = "DIRECT from external network '$destExtName' (Step12-Import-V1)"
        ownerRef = @{ id = $VdcUrn }
        networkType = 'DIRECT'
        parentNetworkId = @{ id = $destExt.id }
    }
    $null = Invoke-VcdOpenApi -Session $Session -Path '/cloudapi/1.0.0/orgVdcNetworks' -Method Post -Body $body
    $net = Wait-OrgVdcNetworkRealized -Session $Session -Name $DestName -VdcUrn $VdcUrn
    return @{ status='ok-direct'; netUrn=$net.id; netType='DIRECT'; extUrn=$destExt.id; srcType=$srcType }
}

# ========================================================================
# Main: connect, loop sources, write summary
# ========================================================================

Import-Module VMware.VimAutomation.Vds -ErrorAction Stop

# Credentials
if ($SeparateCredentials) {
    $vcCred  = Get-HardcodedOrPromptCred -Message "vCenter credentials ($vcServer)"
    $vcdCred = Get-HardcodedOrPromptCred -Message "VCD System administrator credentials ($vcdServer)"
} else {
    $shared = Get-HardcodedOrPromptCred -Message "Credentials for vCenter ($vcServer) AND VCD ($vcdServer) - one prompt, shared"
    $vcCred = $shared; $vcdCred = $shared
}

$vc = Connect-VIServer -Server $vcServer -Credential $vcCred -ErrorAction Stop
Write-Host "Connected to vCenter: $($vc.Name)" -ForegroundColor Green
$session = Connect-VcdApi -Server $vcdServer -Credential $vcdCred -Org $vcdOrgLogin -ApiVersion $vcdApiVersion -SkipCertificateCheck:$vcdSkipCert
Write-Host "Logged in to VCD: $vcdServer" -ForegroundColor Green

# Resolve Org VDC URN (only if not given)
if (-not $OrgVdcUrn) {
    Write-Host "Resolving Org VDC URN..." -ForegroundColor Cyan
    $vdcRec = @(Get-VcdQuery -Session $session -Type 'adminOrgVdc' -Filter "name==$vdcName;orgName==$orgName")
    $vdcRec = @($vdcRec | Sort-Object -Property href -Unique)
    if ($vdcRec.Count -ne 1) { throw "Org VDC '$vdcName' resolution failed ($($vdcRec.Count) matches)" }
    $vdcUuid = ($vdcRec[0].href -split '/')[-1]
    $OrgVdcUrn = "urn:vcloud:vdc:$vdcUuid"
}
Write-Host "Org VDC URN: $OrgVdcUrn"

try {
    $srcVds  = Get-VDSwitch -Name $srcVdsName
    $destVds = Get-VDSwitch -Name $dstVdsName

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
        $steps = [ordered]@{}
        try {
            if (-not $PSCmdlet.ShouldProcess($sourceName, "step1 + step2 for $destName")) {
                $steps['step1'] = 'whatif'; $steps['step2'] = 'whatif'
                $results.Add([ordered]@{ source=$sourceName; dest=$destName; status='whatif'; steps=$steps; durationSec=0; error=$null })
                continue
            }

            # ----- Step 1 inline -----
            Write-Host "  -> step1 (portgroup)..." -ForegroundColor DarkGray
            $r1 = Build-OnePortgroupClone -SrcVds $srcVds -DestVds $destVds `
                    -SourceName $sourceName -DestName $destName -Suffix $suffix
            $steps['step1']      = $r1.status
            $steps['step1_msg']  = $r1.message
            if ($r1.status -eq 'skipped-suffix') {
                $status = 'skipped-step1'
                throw [System.Exception]::new("source already -new; skipping")
            }
            $pgMoref = $r1.pg.Key
            Write-Host "    portgroup: $($r1.pg.Name)  moref=$pgMoref  vlan=$($r1.vlan)" -ForegroundColor DarkGray

            # ----- Step 2 inline -----
            Write-Host "  -> step2 (org vdc network)..." -ForegroundColor DarkGray
            $r2 = Import-OneOrgVdcNetwork -Session $session -VdcUrn $OrgVdcUrn -VdcName $vdcName `
                    -SourceName $sourceName -DestName $destName -DestPg $r1.pg.Name -PgMoref $pgMoref -Suffix $suffix
            $steps['step2']        = $r2.status
            $steps['srcType']      = $r2.srcType
            $steps['destNetType']  = $r2.netType
            $steps['destNetUrn']   = $r2.netUrn
            $steps['destExtUrn']   = $r2.extUrn

            $elapsed = ((Get-Date) - $started).TotalSeconds
            Write-Host ("  [OK] {0:F1}s   srcType={1} destNet={2}" -f $elapsed, $r2.srcType, $r2.netType) -ForegroundColor Green
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($status -eq 'ok') { $status = 'failed' }
            $elapsed = ((Get-Date) - $started).TotalSeconds
            Write-Warning ("  [{0}] {1:F1}s : {2}" -f $status.ToUpper(), $elapsed, $errMsg)
        }
        $results.Add([ordered]@{
            source=$sourceName; dest=$destName; status=$status; steps=$steps
            durationSec=[math]::Round($elapsed,2); error=$errMsg
        })
    }

    # Summary
    $summary = [ordered]@{
        runAt           = (Get-Date).ToString('o')
        createdBy       = 'Step12-Import-V2.ps1 (standalone)'
        config          = $ConfigPath
        totalCandidates = $sources.Count
        processed       = $results.Count
        ok              = ($results | Where-Object { $_.status -eq 'ok' }).Count
        failed          = ($results | Where-Object { $_.status -eq 'failed' }).Count
        skipped         = ($results | Where-Object { $_.status -like 'skipped*' }).Count
        results         = $results
    }
    $outDir = Split-Path $resultPath
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $summary | ConvertTo-Json -Depth 12 | Set-Content $resultPath -Encoding UTF8

    Write-Host ""
    Write-Host "=== PHASE 1 DONE ===" -ForegroundColor Green
    Write-Host ("  OK      : {0}" -f $summary.ok)
    Write-Host ("  Failed  : {0}" -f $summary.failed) -ForegroundColor $(if ($summary.failed) { 'Red' } else { 'Green' })
    Write-Host ("  Skipped : {0}" -f $summary.skipped) -ForegroundColor $(if ($summary.skipped) { 'Yellow' } else { 'Green' })
    Write-Host ("  Result  : {0}" -f $resultPath)
    if ($summary.failed -gt 0) {
        Write-Host ""; Write-Host "Failed sources:" -ForegroundColor Red
        $results | Where-Object { $_.status -eq 'failed' } | ForEach-Object { "  - {0}: {1}" -f $_.source, $_.error }
    }
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}
