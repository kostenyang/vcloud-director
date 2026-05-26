<#
.SYNOPSIS
  Step 0 - Parse a vDS export (unzipped backup directory) and emit a JSON
  config that step 1 (New-DistributedPortGroup-v1.1.ps1) can read directly,
  with a portGroup.sources[] array for batch processing.

.DESCRIPTION
  Reads METADATA only: <BackupRoot>\META-INF\data.xml. The .bak files in
  data\ are gzipped binaries and are not needed - data.xml contains every
  portgroup's name, type, binding, and VLAN reference.

  The generator merges the existing config\config.json (if present) as the
  TEMPLATE for vCenter / vcd / tenant sections, overrides
  vCenter.sourceVdsName with the vDS name found in the backup, and adds a
  portGroup.sources[] array of every filtered portgroup. portGroup.source
  is set to the FIRST source so v1.1 can be run against the output file
  directly (it will process source[0]) - the batch wrapper iterates
  sources[] to cover the rest.

  Output JSON (default OutFile = ..\config\config-batch.json):

    {
      "vCenter": { "server": "...", "sourceVdsName": "vDS-TPE-Resource", ... },
      "vcd":     { ...from template... },
      "tenant":  { ...from template... },
      "portGroup": {
        "source": "ds-10-190-025",         <-- v1.1 reads this (sources[0])
        "destinationSuffix": "-new",
        "sources": [                        <-- batch wrapper iterates this
          { "name": "ds-10-190-025", "vlan": 2525, "id": "dvportgroup-1641" },
          ...
        ]
      }
    }

  No _meta block - shape matches exactly what step 1 / 2 / 3 read; sources[]
  is the only addition for the batch wrapper. Anomalies are reported to
  stdout but not written to the file.

.PARAMETER BackupRoot
  Path to the unzipped vDS export directory (must contain META-INF\data.xml).
  Defaults to ..\backup.

.PARAMETER OutFile
  Output JSON path. Defaults to ..\config\config-batch.json. Does NOT overwrite
  ..\config\config.json by default - the operator can rename it after review.

.PARAMETER TemplateConfig
  Path to an existing config.json to copy vCenter / vcd / tenant sections from.
  Defaults to ..\config\config.json. If missing, baked-in defaults are used.

.PARAMETER NamePattern
  Regex applied as an INCLUDE filter. Default '^ds-' skips infra portgroups
  like FT-*, vDS-*, VMotion-* and the uplink portgroup. Pass '' to disable.

.PARAMETER ExcludePattern
  Regex applied as an EXCLUDE filter AFTER NamePattern. Default skips:
    -new$  : already-migrated portgroups (suffix matches destinationSuffix)
    -vlan  : VLAN-named annotations (operator marker, not real source)
    -1$    : duplicate / secondary copies like '<base>-1'
  Pass '' to disable the exclude filter.

.PARAMETER AnomalyPattern
  Names matching NamePattern + not matching ExcludePattern + not matching this
  "typical shape" regex are emitted but ALSO listed at the end as anomalies
  for operator review. Default ds-NN-NNN-NNN style:
    '^ds-\d+-\d+-\d+$'

.PARAMETER IncludeAllTypes
  Off by default - only type=standard binding=static portgroups are emitted
  (skips uplink and ephemeral). Pass -IncludeAllTypes to include everything.

.PARAMETER DestinationSuffix
  String written into the output JSON's destinationSuffix field. Default '-new'
  matches the existing portGroup.destinationSuffix in config\config.json.

.EXAMPLE
  pwsh ./00-build-config/Build-SourcesFromVdsBackup.ps1
  # Defaults: ..\backup, write ..\config\sources.json, only ds-* standard/static

.EXAMPLE
  pwsh ./00-build-config/Build-SourcesFromVdsBackup.ps1 -NamePattern '^ds-10-190-' -OutFile .\preview.json
  # Preview a narrower selection without touching config\
#>
[CmdletBinding()]
param(
    [string] $BackupRoot,
    [string] $OutFile,
    [string] $TemplateConfig,
    [string] $NamePattern    = '',
    [string] $ExcludePattern = '-new$|FT|VMotion|vtep|vsan',
    [string] $AnomalyPattern = '',
    [switch] $IncludeAllTypes,
    [string] $DestinationSuffix = '-new'
)

$ErrorActionPreference = 'Stop'

# --- Auto-detect repo layout (flat vs nested) ---------------------------
$baseDir = if (Test-Path (Join-Path $PSScriptRoot 'config')) { $PSScriptRoot }
           else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $BackupRoot)     { $BackupRoot     = Join-Path $baseDir 'backup' }
if (-not $OutFile)        { $OutFile        = Join-Path $baseDir 'config\config-batch.json' }
if (-not $TemplateConfig) { $TemplateConfig = Join-Path $baseDir 'config\config.json' }

$xmlPath = Join-Path $BackupRoot 'META-INF\data.xml'
if (-not (Test-Path $xmlPath)) {
    throw "vDS export metadata not found: $xmlPath`nUnzip the backup so the layout is <BackupRoot>\META-INF\data.xml + <BackupRoot>\data\..."
}

Write-Host "Reading: $xmlPath" -ForegroundColor Cyan
[xml]$doc = Get-Content $xmlPath -Raw
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace('n', 'http://vmware.com/vds/envelope/1')

# --- vDS name -----------------------------------------------------------
$vdsNode = $doc.SelectSingleNode('//n:DistributedSwitch', $ns)
$sourceVdsName = if ($vdsNode) { $vdsNode.Attributes['ns1:name'].Value } else { $null }

# --- Build vlanRef -> vlan map (access + trunk + pvlan) -----------------
$vlanMap = @{}
foreach ($v in $doc.SelectNodes('//n:VlanAccess', $ns)) {
    $vlanMap[$v.Attributes['ns1:id'].Value] = [int]$v.Attributes['ns1:vlan'].Value
}
foreach ($v in $doc.SelectNodes('//n:VlanTrunk', $ns)) {
    # Trunk VLANs carry a range; preserve as a string to flag for the operator.
    $vlanMap[$v.Attributes['ns1:id'].Value] = 'trunk:' + $v.Attributes['ns1:vlan'].Value
}
foreach ($v in $doc.SelectNodes('//n:VlanPvlan', $ns)) {
    $vlanMap[$v.Attributes['ns1:id'].Value] = 'pvlan:' + $v.Attributes['ns1:vlan'].Value
}

# --- Filter portgroups --------------------------------------------------
$pgs = $doc.SelectNodes('//n:DistributedPortGroup', $ns)
$total = $pgs.Count
$skippedType    = 0
$skippedName    = 0
$skippedExclude = New-Object System.Collections.Generic.List[string]
$anomalies      = New-Object System.Collections.Generic.List[object]
$sources        = New-Object System.Collections.Generic.List[object]
foreach ($pg in $pgs) {
    $name    = $pg.Attributes['ns1:name'].Value
    $type    = $pg.Attributes['ns1:type'].Value
    $binding = $pg.Attributes['ns1:binding'].Value
    $vlanRef = $pg.Attributes['ns1:vlanRef'].Value
    $id      = $pg.Attributes['ns1:id'].Value

    if (-not $IncludeAllTypes -and ($type -ne 'standard' -or $binding -ne 'static')) {
        $skippedType++
        continue
    }
    if ($NamePattern -and $name -notmatch $NamePattern) {
        $skippedName++
        continue
    }
    if ($ExcludePattern -and $name -match $ExcludePattern) {
        $skippedExclude.Add($name)
        continue
    }

    $entry = [ordered]@{
        name = $name
        vlan = $vlanMap[$vlanRef]
        id   = $id
    }
    $sources.Add($entry)
    if ($AnomalyPattern -and $name -notmatch $AnomalyPattern) {
        $anomalies.Add($entry)
    }
}

# --- Load template config (for vCenter / vcd / tenant) ------------------
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
    Write-Warning "Template config not found at $TemplateConfig - using baked defaults for vCenter / vcd / tenant."
}

$vCenter = _PSObjectToOrdered $template.vCenter
if (-not $vCenter) {
    $vCenter = [ordered]@{ server = ''; sourceVdsName = ''; destinationVdsName = '' }
}
# Override sourceVdsName with what the backup actually says.
$vCenter['sourceVdsName'] = $sourceVdsName

$vcd = _PSObjectToOrdered $template.vcd
if (-not $vcd) {
    $vcd = [ordered]@{ server = ''; apiVersion = '40.0'; org = 'System'; skipCertificateCheck = $true }
}

$tenant = _PSObjectToOrdered $template.tenant
if (-not $tenant) {
    $tenant = [ordered]@{ orgName = ''; orgVdcName = ''; orgVdcId = $null }
}

$firstSource = if ($sources.Count -gt 0) { $sources[0].name } else { '' }

# --- Compose output (v1.1-compatible config + sources[] extension) ------
# No _meta block - keeps the file minimal and matches the exact shape the
# step 1 / 2 / 3 scripts read. Anomalies are still reported in stdout below.
$out = [ordered]@{
    vCenter = $vCenter
    vcd     = $vcd
    tenant  = $tenant
    portGroup = [ordered]@{
        source            = $firstSource
        destinationSuffix = $DestinationSuffix
        sources           = $sources
    }
}

$outDir = Split-Path $OutFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$out | ConvertTo-Json -Depth 10 | Set-Content -Path $OutFile -Encoding UTF8

# --- Summary ------------------------------------------------------------
Write-Host ""
Write-Host "Summary" -ForegroundColor Green
Write-Host ("  vDS                 : {0}" -f $sourceVdsName)
Write-Host ("  Total portgroups    : {0}" -f $total)
Write-Host ("  Filtered by type    : {0}" -f $skippedType)
Write-Host ("  Filtered by name    : {0}" -f $skippedName)
Write-Host ("  Filtered by exclude : {0}" -f $skippedExclude.Count)
Write-Host ("  Emitted             : {0}" -f $sources.Count) -ForegroundColor Yellow
Write-Host ("  Anomalies (emitted) : {0}" -f $anomalies.Count) -ForegroundColor $(if ($anomalies.Count) { 'Magenta' } else { 'Green' })
Write-Host ("  Output              : {0}" -f $OutFile)
if ($skippedExclude.Count) {
    Write-Host ""
    Write-Host "Excluded by ExcludePattern ('$ExcludePattern'):" -ForegroundColor DarkYellow
    $skippedExclude | ForEach-Object { "  - $_" }
}
if ($anomalies.Count) {
    Write-Host ""
    Write-Host "ANOMALIES emitted but unusual shape (review these!):" -ForegroundColor Magenta
    $anomalies | ForEach-Object { "  - {0,-30}  vlan={1}" -f $_.name, $_.vlan }
}
Write-Host ""
Write-Host "First 5 emitted:" -ForegroundColor Cyan
$sources | Select-Object -First 5 | ForEach-Object { "  - {0,-30}  vlan={1}" -f $_.name, $_.vlan }
