# Read-only: writes the target list for guest/b9-probe.py from the host's current
# addresses, routes, listening ports and firewall rules. Changes nothing. Normal
# PowerShell is enough. Run it right before each B9 run (the probe refuses a file
# older than 6 hours) and copy the file into the guest, because the lists change
# with every reboot, Windows update and VPN connect.
#   positive:    what the guest must reach while the setup NIC is attached
#   negative:    host and management addresses that must never be reachable, on
#                the usual service ports plus every port the host listens on
#   controls:    on each negative target, the checks that another enabled inbound
#                Allow rule would let through on the Public profile, so their
#                being unreachable is the eo-l2 rules' doing, not the default policy
#   subnets:     host-side subnets the B9 attack puts on, or spoofs from, the guest
#   hostMac:     MAC of the host vNIC on eo-l2-int, for the guest-side capture
#   hvsockPorts: vsock ports of the Hyper-V socket services registered on the host
param([string]$Out = (Join-Path $env:USERPROFILE 'eo-l2-evidence\b9-targets.json'))

. (Join-Path $PSScriptRoot '_common.ps1')

$basePorts = 22, 53, 80, 135, 139, 443, 445, 2375, 2376, 3389, 5985, 5986, 7680
$fixedUdp = 137, 5353, 5355
$hostIf = Get-NetAdapter -Name $EO.HostIf -ErrorAction SilentlyContinue
if (-not $hostIf) { throw "Host interface '$($EO.HostIf)' is missing; run 01-switch.ps1 first." }

$v4 = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })
$hostIps = @($v4 | ForEach-Object IPAddress)

# What the host listens on, wildcard or on one of its IPv4 addresses.
$wild = @('0.0.0.0', '::')
$tcpListen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -in $wild -or $_.LocalAddress -in $hostIps })
$udpListen = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { ($_.LocalAddress -in $wild -or $_.LocalAddress -in $hostIps) -and $_.LocalPort -lt 49152 })

# Ports that some enabled inbound Allow rule opens on the Public profile.
$rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Allow | Where-Object { "$($_.Profile)" -match 'Public|Any' })
$ports = @{}; foreach ($f in Get-NetFirewallPortFilter -PolicyStore ActiveStore -All) { $ports[$f.InstanceID] = $f }
$apps = @{}; foreach ($f in Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -All) { $apps[$f.InstanceID] = $f }
$procPath = @{}
foreach ($l in @($tcpListen) + @($udpListen)) {
    if (-not $procPath.ContainsKey([int]$l.OwningProcess)) {
        $procPath[[int]$l.OwningProcess] = try { (Get-Process -Id $l.OwningProcess -ErrorAction Stop).Path } catch { $null }
    }
}
function PortIn([string[]]$Spec, [int]$Port) {
    foreach ($p in $Spec) {
        if ($p -eq 'Any') { return $true }
        if ($p -match '^\d+$' -and [int]$p -eq $Port) { return $true }
        if ($p -match '^(\d+)-(\d+)$' -and $Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return $true }
    }
    return $false
}
function Allowed([string]$Proto, [int]$Port, $Listener) {
    foreach ($r in $rules) {
        $pf = $ports[$r.InstanceID]; $af = $apps[$r.InstanceID]
        if (-not $pf) { continue }
        if ("$($pf.Protocol)" -notin @($Proto, 'Any')) { continue }
        if (-not (PortIn @($pf.LocalPort) $Port)) { continue }
        $prog = if ($af) { "$($af.Program)" } else { 'Any' }
        if ($prog -eq 'Any' -or $prog -eq 'System') { return $true }
        if ($Listener) {
            $path = $procPath[[int]$Listener.OwningProcess]
            if ($path -and ([Environment]::ExpandEnvironmentVariables($prog) -ieq $path)) { return $true }
        }
    }
    return $false
}

function HostChecks([string]$Ip) {
    $checks = New-Object System.Collections.Generic.List[string]
    $controls = New-Object System.Collections.Generic.List[string]
    $tcp = @($basePorts) + @($tcpListen | Where-Object { $_.LocalAddress -in $wild -or $_.LocalAddress -eq $Ip } | ForEach-Object { [int]$_.LocalPort })
    foreach ($p in ($tcp | Sort-Object -Unique)) {
        $checks.Add("tcp/$p")
        $l = $tcpListen | Where-Object { [int]$_.LocalPort -eq $p } | Select-Object -First 1
        if (Allowed 'TCP' $p $l) { $controls.Add("tcp/$p") }
    }
    $udp = @($fixedUdp) + @($udpListen | Where-Object { $_.LocalAddress -in $wild -or $_.LocalAddress -eq $Ip } | ForEach-Object { [int]$_.LocalPort })
    foreach ($p in ($udp | Sort-Object -Unique)) {
        $c = if ($p -eq 53) { 'udp-dns' } else { "udp/$p" }
        $checks.Add($c)
        $l = $udpListen | Where-Object { [int]$_.LocalPort -eq $p } | Select-Object -First 1
        if (Allowed 'UDP' $p $l) { $controls.Add($c) }
    }
    if (-not ($checks -contains 'udp-dns')) { $checks.Add('udp-dns') }
    $checks.Add('icmp')
    return @{ checks = [string[]]$checks; controls = [string[]]$controls }
}

$defaultSwitch = $v4 | Where-Object InterfaceAlias -eq 'vEthernet (Default Switch)' | Select-Object -First 1
# The LAN gateway: the lowest-metric default route with a real next hop, not on a
# Hyper-V or VPN adapter. An on-link default route (next hop 0.0.0.0) is no gateway.
$lanRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -ne '0.0.0.0' -and (Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue).InterfaceDescription -notmatch 'Hyper-V|OpenVPN|TAP|PIA|WireGuard|Wintun' } |
    Sort-Object RouteMetric | Select-Object -First 1

# Checks are plain strings ("tcp/445", "udp/5353", "udp-dns", "icmp"): nested
# arrays do not survive ConvertTo-Json reliably in Windows PowerShell 5.1.
$positive = @()
if ($defaultSwitch) { $positive += [ordered]@{ name = 'Default Switch gateway'; ip = $defaultSwitch.IPAddress; required = $true; checks = [string[]]@('udp-dns', 'icmp') } }
if ($lanRoute) { $positive += [ordered]@{ name = 'LAN gateway'; ip = $lanRoute.NextHop; required = $true; checks = [string[]]@('tcp/80', 'tcp/443', 'udp-dns', 'icmp') } }
$positive += [ordered]@{ name = 'public HTTPS 1.1.1.1'; ip = '1.1.1.1'; required = $true; checks = [string[]]@('tcp/443') }
$positive += [ordered]@{ name = 'public DNS 9.9.9.9'; ip = '9.9.9.9'; required = $true; checks = [string[]]@('udp-dns') }

$negative = @()
foreach ($a in $v4) {
    $hc = HostChecks $a.IPAddress
    $negative += [ordered]@{ name = "host $($a.InterfaceAlias)"; ip = $a.IPAddress; required = $false; checks = $hc.checks; controls = $hc.controls }
}
$negative += [ordered]@{ name = 'link-local metadata'; ip = '169.254.169.254'; required = $false; checks = [string[]]@('tcp/80', 'icmp') }
$negative += [ordered]@{ name = 'guest subnet broadcast'; ip = $EO.SubnetHigh; required = $false; checks = [string[]]@('icmp') }
# Multicast replies come back unicast from the host, which the guest-side capture counts.
$negative += [ordered]@{ name = 'mDNS group'; ip = '224.0.0.251'; required = $false; checks = [string[]]@('udp/5353') }
$negative += [ordered]@{ name = 'LLMNR group'; ip = '224.0.0.252'; required = $false; checks = [string[]]@('udp/5355') }
$negative += [ordered]@{ name = 'public DNS 8.8.8.8'; ip = '8.8.8.8'; required = $false; checks = [string[]]@('udp-dns') }
$negative += [ordered]@{ name = 'public HTTPS 9.9.9.9'; ip = '9.9.9.9'; required = $false; checks = [string[]]@('tcp/443') }

$subnets = @()
foreach ($a in $v4) {
    if ($a.InterfaceAlias -eq $EO.HostIf) { continue }
    $subnets += [ordered]@{ name = $a.InterfaceAlias; cidr = (Get-EoNetwork $a.IPAddress $a.PrefixLength) }
}

# Hyper-V socket services: a service GUID of the form xxxxxxxx-facb-11e6-bd58-64006a7986d3
# is reachable from a Linux guest as vsock port 0xxxxxxxxx.
$gcs = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices'
$hvGuids = @(try { Get-ChildItem $gcs -ErrorAction Stop | ForEach-Object PSChildName } catch { })
$hvPorts = @($hvGuids | Where-Object { $_ -match '^([0-9a-fA-F]{8})-facb-11e6-bd58-64006a7986d3$' } | ForEach-Object { [Convert]::ToInt64($Matches[1], 16) })

$spec = [ordered]@{ generatedAt = (Get-Date).ToUniversalTime().ToString('o'); computer = $env:COMPUTERNAME
    hostMac = ($hostIf.MacAddress -replace '-', ':').ToLower()
    vpnAdapters = @(Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match 'OpenVPN|TAP|PIA|WireGuard|Wintun' } | ForEach-Object { "$($_.Name)=$($_.Status)" })
    hvsockServices = [string[]]$hvGuids; hvsockPorts = [int64[]]$hvPorts
    positive = $positive; negative = $negative; subnets = $subnets }
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
$spec | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $Out
Write-Host "wrote $Out"
Write-Host "positive: $(($positive | ForEach-Object { "$($_.name)=$($_.ip)" }) -join ', ')"
Write-Host "negative: $($negative.Count) targets, $(($negative | ForEach-Object { $_.checks.Count } | Measure-Object -Sum).Sum) checks, $(($negative | Where-Object { $_.Contains('controls') } | ForEach-Object { $_.controls.Count } | Measure-Object -Sum).Sum) of them on ports another rule allows"
Write-Host "subnets: $(($subnets | ForEach-Object cidr) -join ', '); hvsocket services: $($hvGuids.Count) ($($hvPorts.Count) reachable as vsock ports)"
