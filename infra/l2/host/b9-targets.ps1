# Read-only: writes the target list for guest/b9-probe.py from the host's current
# addresses and routes. Changes nothing. Normal PowerShell is enough. Rerun it
# after a Windows update or a VPN connect, because the lists change.
#   positive: what the guest must reach while the setup NIC is attached
#   negative: host and management addresses that must never be reachable
#   subnets:  host-side subnets the B9 attack adds to the guest's interface
param([string]$Out = (Join-Path $env:USERPROFILE 'eo-l2-evidence\b9-targets.json'))

. (Join-Path $PSScriptRoot '_common.ps1')

$hostPorts = 22, 53, 80, 135, 139, 443, 445, 2375, 2376, 3389, 5985, 5986
# Checks are plain strings ("tcp/445", "udp-dns", "icmp"): nested arrays do not
# survive ConvertTo-Json reliably in Windows PowerShell 5.1.
function HostChecks { [string[]](@($hostPorts | ForEach-Object { "tcp/$_" }) + 'udp-dns', 'icmp') }

$v4 = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })
$defaultSwitch = $v4 | Where-Object InterfaceAlias -eq 'vEthernet (Default Switch)' | Select-Object -First 1
$lanRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { (Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue).InterfaceDescription -notmatch 'Hyper-V|OpenVPN|TAP|PIA|WireGuard|Wintun' } |
    Sort-Object RouteMetric | Select-Object -First 1

$positive = @()
if ($defaultSwitch) { $positive += [ordered]@{ name = 'Default Switch gateway'; ip = $defaultSwitch.IPAddress; required = $true; checks = [string[]]@('udp-dns', 'icmp') } }
if ($lanRoute) { $positive += [ordered]@{ name = 'LAN gateway'; ip = $lanRoute.NextHop; required = $true; checks = [string[]]@('tcp/80', 'tcp/443', 'udp-dns', 'icmp') } }
$positive += [ordered]@{ name = 'public HTTPS 1.1.1.1'; ip = '1.1.1.1'; required = $true; checks = [string[]]@('tcp/443') }
$positive += [ordered]@{ name = 'public DNS 9.9.9.9'; ip = '9.9.9.9'; required = $true; checks = [string[]]@('udp-dns') }

$negative = @()
foreach ($a in $v4) { $negative += [ordered]@{ name = "host $($a.InterfaceAlias)"; ip = $a.IPAddress; required = $false; checks = (HostChecks) } }
if (-not ($v4 | Where-Object IPAddress -eq $EO.HostIp)) { $negative += [ordered]@{ name = 'host eo-l2-int'; ip = $EO.HostIp; required = $false; checks = (HostChecks) } }
$negative += [ordered]@{ name = 'link-local metadata'; ip = '169.254.169.254'; required = $false; checks = [string[]]@('tcp/80', 'icmp') }
$negative += [ordered]@{ name = 'guest subnet broadcast'; ip = $EO.SubnetHigh; required = $false; checks = [string[]]@('icmp') }
$negative += [ordered]@{ name = 'public DNS 8.8.8.8'; ip = '8.8.8.8'; required = $false; checks = [string[]]@('udp-dns') }
$negative += [ordered]@{ name = 'public HTTPS 9.9.9.9'; ip = '9.9.9.9'; required = $false; checks = [string[]]@('tcp/443') }

$subnets = @()
foreach ($a in $v4) {
    if ($a.InterfaceAlias -eq $EO.HostIf) { continue }
    $subnets += [ordered]@{ name = $a.InterfaceAlias; cidr = (Get-EoNetwork $a.IPAddress $a.PrefixLength) }
}

$spec = [ordered]@{ generatedAt = (Get-Date).ToUniversalTime().ToString('o'); computer = $env:COMPUTERNAME
    vpnAdapters = @(Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match 'OpenVPN|TAP|PIA|WireGuard|Wintun' } | ForEach-Object { "$($_.Name)=$($_.Status)" })
    positive = $positive; negative = $negative; subnets = $subnets }
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
$spec | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $Out
Write-Host "wrote $Out"
Write-Host "positive: $(($positive | ForEach-Object { "$($_.name)=$($_.ip)" }) -join ', ')"
Write-Host "negative: $($negative.Count) targets; subnets: $(($subnets | ForEach-Object cidr) -join ', ')"
