<#
.SYNOPSIS
    新增 VCD + NFS VM 的 DNS A 記錄 (forward + reverse PTR)
    到 rtolab.local zone @ 192.168.114.200

.EXAMPLE
    pwsh E:\VCD\04-Add-VcdDns.ps1
    pwsh E:\VCD\04-Add-VcdDns.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string] $DnsServer = '192.168.114.200',
    [string] $ZoneName  = 'rtolab.local',
    [PSCredential] $Credential
)

$ErrorActionPreference = 'Stop'
Import-Module DnsServer -ErrorAction Stop

$records = @(
    @{ Name = 'kosten-vcd';     Ip = '192.168.114.60'; Comment = 'VCD 10.6.1 appliance' },
    @{ Name = 'kosten-vcd-nfs'; Ip = '192.168.114.61'; Comment = 'NFS server for VCD transfer' }
)

if (-not $Credential) {
    $Credential = Get-Credential -Message "rtolab AD admin (rtolab\administrator)"
}

$opt     = New-CimSessionOption -Protocol Wsman
$cimSess = New-CimSession -ComputerName $DnsServer -Credential $Credential -SessionOption $opt -Authentication Negotiate
$zArgs   = @{ CimSession = $cimSess }

function Get-RevZone  { param([string]$ip) $o=$ip.Split('.'); "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa" }
function Get-PtrLabel { param([string]$ip) ($ip.Split('.'))[3] }

# 確保反向 zone 存在
foreach ($ip in ($records.Ip)) {
    $rz = Get-RevZone $ip
    $ex = $null; try { $ex = Get-DnsServerZone -Name $rz @zArgs -ErrorAction Stop } catch {}
    if (-not $ex) {
        $parts = $rz.Replace('.in-addr.arpa','').Split('.'); [array]::Reverse($parts)
        $netId = "$($parts -join '.').0/24"
        Write-Host "[add reverse zone] $rz ($netId)" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($rz,'Add-DnsServerPrimaryZone')) {
            Add-DnsServerPrimaryZone -NetworkId $netId -ReplicationScope Domain -DynamicUpdate Secure @zArgs
        }
    }
}

# Forward A + Reverse PTR
foreach ($r in $records) {
    $name = $r.Name; $ip = $r.Ip

    # Forward
    $ex = $null; try { $ex = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $name -RRType A @zArgs -ErrorAction Stop } catch {}
    if ($ex) {
        $curIp = $ex.RecordData.IPv4Address.IPAddressToString
        if ($curIp -eq $ip) {
            Write-Host "[skip] $name.$ZoneName -> $ip" -ForegroundColor DarkGray
        } else {
            Write-Host "[update] ${name}: $curIp -> $ip" -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess("$name -> $ip",'Update A')) {
                Remove-DnsServerResourceRecord -ZoneName $ZoneName -InputObject $ex -Force @zArgs
                Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $name -IPv4Address $ip @zArgs
            }
        }
    } else {
        Write-Host "[add]  $name.$ZoneName -> $ip  ($($r.Comment))" -ForegroundColor Green
        if ($PSCmdlet.ShouldProcess("$name -> $ip",'Add A')) {
            Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $name -IPv4Address $ip @zArgs
        }
    }

    # Reverse PTR
    $rz      = Get-RevZone $ip
    $ptrLabel = Get-PtrLabel $ip
    $ptrFqdn = "$name.$ZoneName."
    $exPtr = $null; try { $exPtr = Get-DnsServerResourceRecord -ZoneName $rz -Name $ptrLabel -RRType Ptr @zArgs -ErrorAction Stop } catch {}
    if ($exPtr) {
        if ($exPtr.RecordData.PtrDomainName -eq $ptrFqdn) {
            Write-Host "[skip] PTR $ptrLabel.$rz -> $ptrFqdn" -ForegroundColor DarkGray
        } else {
            Write-Host "[update PTR] $ptrLabel.${rz}: $($exPtr.RecordData.PtrDomainName) -> $ptrFqdn" -ForegroundColor Yellow
            if ($PSCmdlet.ShouldProcess("$ptrLabel.$rz -> $ptrFqdn",'Update PTR')) {
                Remove-DnsServerResourceRecord -ZoneName $rz -InputObject $exPtr -Force @zArgs
                Add-DnsServerResourceRecordPtr -ZoneName $rz -Name $ptrLabel -PtrDomainName $ptrFqdn @zArgs
            }
        }
    } else {
        Write-Host "[add]  PTR $ptrLabel.$rz -> $ptrFqdn" -ForegroundColor Green
        if ($PSCmdlet.ShouldProcess("$ptrLabel.$rz -> $ptrFqdn",'Add PTR')) {
            Add-DnsServerResourceRecordPtr -ZoneName $rz -Name $ptrLabel -PtrDomainName $ptrFqdn @zArgs
        }
    }
}

Remove-CimSession $cimSess

Write-Host ""
Write-Host "DNS records done. Verify:" -ForegroundColor Cyan
Write-Host "  Resolve-DnsName -Server $DnsServer kosten-vcd.$ZoneName"
Write-Host "  Resolve-DnsName -Server $DnsServer kosten-vcd-nfs.$ZoneName"
Write-Host "  Resolve-DnsName -Server $DnsServer 192.168.114.60 -Type PTR"
Write-Host "  Resolve-DnsName -Server $DnsServer 192.168.114.61 -Type PTR"
