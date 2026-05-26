<#
.SYNOPSIS
  Step 0c - Query a tenant Org VDC and emit configorg.json with sources[]
  populated from the existing DIRECT Org VDC Networks. One tenant per run.

.DESCRIPTION
  Lets you migrate tenants one at a time without touching vDS exports:
    1. Connects to VCD as provider admin.
    2. Resolves the org / Org VDC URN by name (or accepts -OrgVdcUrn).
    3. Lists every Org VDC Network in that VDC, keeps only networkType =
       DIRECT (the OPAQUE / NAT_ROUTED / ISOLATED ones are skipped).
    4. For each DIRECT network captures:
         name, gateway/prefix, parentExternalNetwork name + URN
    5. Writes a config JSON in the shape step 2 v2 expects:
         vCenter / vcd / tenant sections copied from the template config
         portGroup.sources[] = the discovered DIRECT networks
         portGroup.source    = sources[0].name (so single-source runs work)

  Defaults match the rest of the pipeline:
    -OutFile        config\configorg.json    (the new step 2 v2 default)
    -TemplateConfig config\config.json       (carries vCenter / vcd block)

  Per-tenant workflow:
    pwsh ./00-build-config/Build-SourcesFromOrg.ps1 -OrgName 'viqa.qa'
    pwsh ./Invoke-MigrationBatch.ps1 -ConfigPath ./config/configorg.json -All
    # next tenant
    pwsh ./00-build-config/Build-SourcesFromOrg.ps1 -OrgName 'other-tenant'
    pwsh ./Invoke-MigrationBatch.ps1 -ConfigPath ./config/configorg.json -All

.PARAMETER OrgName
  Required. Target tenant org name (e.g. 'viqa.qa').

.PARAMETER OrgVdcName
  Org VDC name inside OrgName. Defaults to OrgName (your environment uses
  the same name for both).

.PARAMETER OrgVdcUrn
  Optional URN override (urn:vcloud:vdc:...). Skips name-based lookup -
  useful when multiple VDCs share the same name across orgs.

.PARAMETER OutFile
  Where to write the JSON. Default config\configorg.json (= step 2 v2's
  new default ConfigPath, so step 2 v2 will read it without an explicit
  -ConfigPath flag).

.PARAMETER TemplateConfig
  Config file to copy vCenter / vcd sections from. Default config\config.json.

.PARAMETER DestinationSuffix
  Written to the output JSON's portGroup.destinationSuffix. Default '-new'.

.EXAMPLE
  pwsh ./00-build-config/Build-SourcesFromOrg.ps1 -OrgName 'viqa.qa'

.EXAMPLE
  pwsh ./00-build-config/Build-SourcesFromOrg.ps1 -OrgName 'viqa.qa' `
       -OrgVdcUrn 'urn:vcloud:vdc:abcd-1234-...'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OrgName,
    [string] $OrgVdcName,
    [string] $OrgVdcUrn,
    [string] $OutFile,
    [string] $TemplateConfig,
    [string] $DestinationSuffix = '-new'
)

$ErrorActionPreference = 'Stop'

if (-not $OrgVdcName) { $OrgVdcName = $OrgName }

# --- Auto-detect repo layout (flat vs nested) ---------------------------
$baseDir = if (Test-Path (Join-Path $PSScriptRoot 'config')) { $PSScriptRoot }
           else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $OutFile)        { $OutFile        = Join-Path $baseDir 'config\configorg.json' }
if (-not $TemplateConfig) { $TemplateConfig = Join-Path $baseDir 'config\config.json' }

. (Join-Path $baseDir 'lib\VcdRest.ps1')

# --- Load template (vCenter / vcd blocks come from here) ---------------
function _PSObjectToOrdered {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = _PSObjectToOrdered $p.Value }
        return $h
    }
    if ($Obj -is [System.Collections.IList] -and $Obj -isnot [string]) {
        return @($Obj | ForEach-Object { _PSObjectToOrdered $_ })
    }
    return $Obj
}

$template = $null
if (Test-Path $TemplateConfig) {
    Write-Host "Template: $TemplateConfig" -ForegroundColor Cyan
    $template = Get-Content $TemplateConfig -Raw | ConvertFrom-Json
}
else {
    Write-Warning "Template config not found: $TemplateConfig - using baked defaults."
}
$vCenter = _PSObjectToOrdered $template.vCenter
if (-not $vCenter) {
    $vCenter = [ordered]@{ server = ''; sourceVdsName = ''; destinationVdsName = '' }
}
$vcd = _PSObjectToOrdered $template.vcd
if (-not $vcd) {
    $vcd = [ordered]@{ server = ''; apiVersion = '39.1'; org = 'System'; skipCertificateCheck = $true }
}

# --- Connect to VCD -----------------------------------------------------
$vcdCred = Get-Credential -Message "VCD System administrator credentials ($($vcd.server))"
$session = Connect-VcdApi -Server $vcd.server -Credential $vcdCred `
    -Org $vcd.org -ApiVersion $vcd.apiVersion `
    -SkipCertificateCheck:$vcd.skipCertificateCheck
Write-Host "Logged in to VCD: $($vcd.server)" -ForegroundColor Green

# --- Resolve Org / Org VDC URN -----------------------------------------
if (-not $OrgVdcUrn) {
    Write-Host "Resolving Org VDC '$OrgVdcName' in org '$OrgName'..." -ForegroundColor Cyan
    $vdcRec = @(Get-VcdQuery -Session $session -Type 'adminOrgVdc' `
        -Filter "name==$OrgVdcName;orgName==$OrgName")
    $vdcRec = @($vdcRec | Sort-Object -Property href -Unique)
    if ($vdcRec.Count -eq 0) {
        throw "Org VDC not found: '$OrgVdcName' in org '$OrgName'"
    }
    if ($vdcRec.Count -gt 1) {
        $rows = $vdcRec | ForEach-Object {
            $u = ($_.href -split '/')[-1]
            [pscustomobject]@{
                Name = $_.name
                Urn  = "urn:vcloud:vdc:$u"
                Href = $_.href
            }
        }
        throw "Org VDC '$OrgVdcName' is ambiguous in '$OrgName'. Found $($vdcRec.Count) match(es):`n$((($rows | Format-Table -AutoSize | Out-String).Trim()))`nRe-run with -OrgVdcUrn 'urn:vcloud:vdc:...'."
    }
    $vdcUuid  = ($vdcRec[0].href -split '/')[-1]
    $OrgVdcUrn = "urn:vcloud:vdc:$vdcUuid"
}
Write-Host "Org VDC URN: $OrgVdcUrn" -ForegroundColor Green

# --- List Org VDC Networks (paginated) and keep only DIRECT ------------
function Find-VdcNetworks {
    param($Resp, $VdcUrn)
    $Resp.values | Where-Object {
        ($_.ownerRef -and $_.ownerRef.id -eq $VdcUrn) -or
        ($_.orgVdc   -and $_.orgVdc.id   -eq $VdcUrn)
    }
}

Write-Host "Listing Org VDC Networks (paginated)..." -ForegroundColor Cyan
$pageSize = 128
$page = 1
$pageCount = 1
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
Write-Host ("  Other types skipped: {0}" -f $other)

if ($directNets.Count -eq 0) {
    Write-Warning "No DIRECT networks found in this Org VDC - nothing to write."
    return
}

# --- Skip already-migrated (-new suffix) -------------------------------
$candidates = @($directNets | Where-Object { -not $_.name.EndsWith($DestinationSuffix) })
$skippedNew = $directNets.Count - $candidates.Count
if ($skippedNew -gt 0) {
    Write-Host ("  Skipping already-migrated (-new suffix) : {0}" -f $skippedNew) -ForegroundColor DarkYellow
}

# --- Build sources[] ----------------------------------------------------
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

# --- Compose output -----------------------------------------------------
$out = [ordered]@{
    vCenter = $vCenter
    vcd     = $vcd
    tenant  = [ordered]@{
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
Write-Host "  pwsh ./Invoke-MigrationBatch.ps1 -ConfigPath $OutFile -All -WhatIf"
Write-Host "  pwsh ./Invoke-MigrationBatch.ps1 -ConfigPath $OutFile -All"
