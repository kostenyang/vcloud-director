<#
.SYNOPSIS
  Step 0b - Compare the candidate sources in config-batch.json against the
  current state of vCenter (dest vDS portgroups) and VCD (Org VDC Networks),
  emit state\todo.json listing only the sources that still have work pending.

.DESCRIPTION
  For each source in $cfg.portGroup.sources[], checks:
    - Step 1 done? : does dest portgroup '<name><suffix>' exist on the dest vDS?
    - Step 2 done? : does dest Org VDC Network '<name><suffix>' exist in the
                     target Org VDC?
    - Step 3 done? : (optional, -CheckVms) does the SOURCE Org VDC Network
                     still have VMs connected? If 0 VMs, step 3 is done.

  The expensive VM check is OFF by default; pass -CheckVms to enable it
  (one VCD query per source - 307 queries can take a few minutes).

  All other checks are O(1) per source after one batch fetch:
    - One PowerCLI call to list every portgroup on the dest vDS
    - One paginated VCD call to list every Org VDC Network in the target VDC

  Output JSON shape:

    {
      "checkedAt"        : "2026-05-26T...",
      "config"           : "...\\config\\config-batch.json",
      "destVdsName"      : "vDS-TPE-vCD",
      "orgVdcUrn"        : "urn:vcloud:vdc:...",
      "totalCandidates"  : 307,
      "alreadyDone"      : 245,
      "pendingCount"     : 60,
      "anomalies"        : [ ... ],
      "pending": [
        { "name": "ds-10-190-013", "vlan": 2513,
          "destPortgroupExists": false, "destNetworkExists": false,
          "sourceVmCount": null, "needs": ["step1","step2","step3"] },
        ...
      ]
    }

  The downstream batch wrapper reads `pending[]` and runs only the steps
  listed in `needs[]` for each source. Re-run this script after migration to
  shrink the pending list and pick up any failures.

.PARAMETER ConfigPath
  Input config (default ..\config\config-batch.json). Must contain
  vCenter.*, vcd.*, tenant.*, portGroup.destinationSuffix, portGroup.sources[].

.PARAMETER OutFile
  Output todo file (default ..\state\todo.json).

.PARAMETER OrgVdcUrn
  Optional URN override (urn:vcloud:vdc:<uuid>) - skips name-based VDC lookup.

.PARAMETER CheckVms
  Off by default. When set, also queries each source Org VDC Network for VM
  count. Enables the step3-done detection. Adds one VCD round-trip per source.

.EXAMPLE
  pwsh ./00-build-config/Compare-MigrationState.ps1
  # Fast scan, only checks portgroup + network existence

.EXAMPLE
  pwsh ./00-build-config/Compare-MigrationState.ps1 -CheckVms
  # Adds per-source VM count; slower but step3-done aware

.EXAMPLE
  pwsh ./00-build-config/Compare-MigrationState.ps1 -OrgVdcUrn 'urn:vcloud:vdc:abc...'
  # Skip name-based VDC resolution
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $OutFile,
    [string] $OrgVdcUrn,
    [switch] $CheckVms
)

$ErrorActionPreference = 'Stop'

# --- Auto-detect repo layout (flat vs nested) ---------------------------
$baseDir = if (Test-Path (Join-Path $PSScriptRoot 'config')) { $PSScriptRoot }
           else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $baseDir 'config\config-batch.json' }
if (-not $OutFile)    { $OutFile    = Join-Path $baseDir 'state\todo.json' }

# Honour config.local.json if present (consistent with step 1 / 2 / 3).
$localCfg = Join-Path (Split-Path $ConfigPath) 'config.local.json'
if (Test-Path $localCfg) { $ConfigPath = $localCfg }
Write-Host "Loading config: $ConfigPath" -ForegroundColor Cyan
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json

if (-not $cfg.portGroup.sources) {
    throw "Config has no portGroup.sources[] - run Build-SourcesFromVdsBackup.ps1 first to populate it."
}
$suffix    = $cfg.portGroup.destinationSuffix
$destVdsName = $cfg.vCenter.destinationVdsName
Write-Host ("Candidates: {0}  |  dest vDS: {1}  |  suffix: '{2}'" -f $cfg.portGroup.sources.Count, $destVdsName, $suffix)

. (Join-Path $baseDir 'lib\VcdRest.ps1')

# =======================================================================
# 1. vCenter: list every portgroup on the dest vDS, index by name
# =======================================================================
Import-Module VMware.VimAutomation.Vds -ErrorAction Stop
$viCred = Get-Credential -Message "vCenter credentials ($($cfg.vCenter.server))"
$vc = Connect-VIServer -Server $cfg.vCenter.server -Credential $viCred
Write-Host "Connected to vCenter: $($vc.Name)" -ForegroundColor Green

try {
    $destVds = Get-VDSwitch -Name $destVdsName
    Write-Host "Listing portgroups on dest vDS '$destVdsName'..." -ForegroundColor Cyan
    $destPgIndex = @{}
    foreach ($pg in (Get-VDPortgroup -VDSwitch $destVds)) {
        $destPgIndex[$pg.Name] = $pg
    }
    Write-Host ("  found {0} portgroup(s) on {1}" -f $destPgIndex.Count, $destVdsName)
}
finally {
    Disconnect-VIServer -Server $vc -Confirm:$false -ErrorAction SilentlyContinue
}

# =======================================================================
# 2. VCD: list every Org VDC Network in the target Org VDC, index by name
# =======================================================================
$vcdCred = Get-Credential -Message "VCD System administrator credentials ($($cfg.vcd.server))"
$session = Connect-VcdApi -Server $cfg.vcd.server -Credential $vcdCred `
    -Org $cfg.vcd.org -ApiVersion $cfg.vcd.apiVersion `
    -SkipCertificateCheck:$cfg.vcd.skipCertificateCheck
Write-Host "Logged in to VCD: $($cfg.vcd.server)" -ForegroundColor Green

# Resolve Org VDC URN (re-uses step 2's logic)
if (-not $OrgVdcUrn) {
    $vdcRec = @(Get-VcdQuery -Session $session -Type 'adminOrgVdc' `
        -Filter "name==$($cfg.tenant.orgVdcName);orgName==$($cfg.tenant.orgName)")
    $vdcRec = @($vdcRec | Sort-Object -Property href -Unique)
    if ($vdcRec.Count -eq 0) {
        throw "Org VDC not found: '$($cfg.tenant.orgVdcName)' in org '$($cfg.tenant.orgName)'"
    }
    if ($vdcRec.Count -gt 1) {
        throw "Org VDC '$($cfg.tenant.orgVdcName)' is ambiguous in '$($cfg.tenant.orgName)'. Re-run with -OrgVdcUrn."
    }
    $vdcUuid  = ($vdcRec[0].href -split '/')[-1]
    $OrgVdcUrn = "urn:vcloud:vdc:$vdcUuid"
}
Write-Host "Org VDC URN: $OrgVdcUrn"

# Fetch every Org VDC Network in this VDC, paginated. Filter server-side
# by ownerRef.id (newer API) and fall back via Find on client side too.
function Find-VdcNetwork {
    param($Resp, $VdcUrn)
    $Resp.values | Where-Object {
        ($_.ownerRef -and $_.ownerRef.id -eq $VdcUrn) -or
        ($_.orgVdc   -and $_.orgVdc.id   -eq $VdcUrn)
    }
}

Write-Host "Listing Org VDC Networks..." -ForegroundColor Cyan
$destNetIndex = @{}
$sourceNetIndex = @{}
$pageSize = 128
$page = 1
$pageCount = 1
while ($page -le $pageCount) {
    $resp = Invoke-VcdOpenApi -Session $session `
        -Path "/cloudapi/1.0.0/orgVdcNetworks?pageSize=$pageSize&page=$page"
    foreach ($n in (Find-VdcNetwork -Resp $resp -VdcUrn $OrgVdcUrn)) {
        # Same name can theoretically appear in a different VDC; we already
        # filtered to $OrgVdcUrn so a name is unique here.
        if ($n.name.EndsWith($suffix)) { $destNetIndex[$n.name] = $n }
        else                            { $sourceNetIndex[$n.name] = $n }
    }
    $pageCount = [int]$resp.pageCount
    $page++
}
Write-Host ("  found {0} network(s) ending with '{1}' (potential dests), {2} other (potential sources)" `
    -f $destNetIndex.Count, $suffix, $sourceNetIndex.Count)

# =======================================================================
# 3. Walk the candidate sources, determine needs[] per source
# =======================================================================
$pending    = New-Object System.Collections.Generic.List[object]
$alreadyDoneCount = 0
$anomalies  = New-Object System.Collections.Generic.List[object]
foreach ($src in $cfg.portGroup.sources) {
    $destPgName  = $src.name + $suffix
    $destNetName = $src.name + $suffix
    $hasDestPg   = $destPgIndex.ContainsKey($destPgName)
    $hasDestNet  = $destNetIndex.ContainsKey($destNetName)

    # Optional source-VM check
    $sourceVmCount = $null
    if ($CheckVms) {
        $srcNet = $sourceNetIndex[$src.name]
        if ($srcNet) {
            # /orgVdcNetworks/{id}/ipAllocations?type=VM - count entries
            try {
                $alloc = Invoke-VcdOpenApi -Session $session `
                    -Path "/cloudapi/1.0.0/orgVdcNetworks/$($srcNet.id)/allocatedIpAddresses?pageSize=1"
                $sourceVmCount = [int]$alloc.resultTotal
            }
            catch {
                $sourceVmCount = -1   # query failed
            }
        }
        else {
            # source network not found - either renamed during a prior migration,
            # or never existed. Cannot count VMs.
            $sourceVmCount = -1
        }
    }

    # Decide needs[]
    $needs = New-Object System.Collections.Generic.List[string]
    if (-not $hasDestPg)  { $needs.Add('step1') }
    if (-not $hasDestNet) { $needs.Add('step2') }
    if ($CheckVms) {
        # step 3 only "done" when sourceVmCount == 0 AND dest network exists.
        # Anything else (count > 0, query failed -1, dest missing) -> pending.
        if (-not ($hasDestNet -and $sourceVmCount -eq 0)) { $needs.Add('step3') }
    }
    else {
        # No VM check - if dest network is missing, definitely need step 3
        # after step 2. If dest network exists, we don't know if VMs moved,
        # so conservatively mark step 3 as needed.
        $needs.Add('step3')
    }

    # Anomalies (inconsistent state)
    if ($hasDestNet -and -not $hasDestPg) {
        $anomalies.Add([ordered]@{
            name  = $src.name
            issue = "dest Org VDC Network exists but dest portgroup does not - inconsistent"
        })
    }

    if ($needs.Count -eq 0) {
        $alreadyDoneCount++
        continue
    }
    $pending.Add([ordered]@{
        name                = $src.name
        vlan                = $src.vlan
        destPortgroupExists = $hasDestPg
        destNetworkExists   = $hasDestNet
        sourceVmCount       = $sourceVmCount
        needs               = @($needs)
    })
}

# =======================================================================
# 4. Emit todo.json
# =======================================================================
$todo = [ordered]@{
    checkedAt         = (Get-Date).ToString('o')
    config            = $ConfigPath
    destVdsName       = $destVdsName
    orgVdcUrn         = $OrgVdcUrn
    destinationSuffix = $suffix
    vmCheckEnabled    = [bool]$CheckVms
    totalCandidates   = $cfg.portGroup.sources.Count
    alreadyDone       = $alreadyDoneCount
    pendingCount      = $pending.Count
    anomalies         = $anomalies
    pending           = $pending
}
$outDir = Split-Path $OutFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$todo | ConvertTo-Json -Depth 12 | Set-Content -Path $OutFile -Encoding UTF8

# =======================================================================
# 5. Summary
# =======================================================================
Write-Host ""
Write-Host "Summary" -ForegroundColor Green
Write-Host ("  Total candidates : {0}" -f $cfg.portGroup.sources.Count)
Write-Host ("  Already done     : {0}" -f $alreadyDoneCount) -ForegroundColor Green
Write-Host ("  Pending          : {0}" -f $pending.Count)    -ForegroundColor Yellow
Write-Host ("  Anomalies        : {0}" -f $anomalies.Count)  -ForegroundColor $(if ($anomalies.Count) { 'Magenta' } else { 'Green' })
Write-Host ("  Output           : {0}" -f $OutFile)

# Breakdown of pending by what they need
if ($pending.Count) {
    Write-Host ""
    Write-Host "Pending breakdown by needs[]:" -ForegroundColor Cyan
    $pending | Group-Object { ($_.needs -join ',') } | Sort-Object Count -Descending |
        ForEach-Object { "  {0,4} x [{1}]" -f $_.Count, $_.Name }
}
if ($anomalies.Count) {
    Write-Host ""
    Write-Host "Anomalies (review!):" -ForegroundColor Magenta
    $anomalies | ForEach-Object { "  - {0}: {1}" -f $_.name, $_.issue }
}
