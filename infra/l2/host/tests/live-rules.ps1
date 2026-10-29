# CI only (an elevated, disposable Windows runner): creates the five eo-l2 rules
# with the same functions steps 01 and 01b use, under a "eo-l2-ci-" name prefix,
# group "eo-l2-ci" and a real adapter, then reads them back with Get-EoRuleFacts
# from the persistent store and the active policy and checks them against the
# spec. Then it alters one filter at a time with the firewall cmdlets and checks
# that each alteration fails. Every rule it made is removed at the end.
param([string]$Alias)

$hostDir = Split-Path $PSScriptRoot
. (Join-Path $hostDir '_common.ps1')
Assert-EoAdmin

$prefix = 'eo-l2-ci-'; $group = 'eo-l2-ci'
$failures = New-Object System.Collections.Generic.List[string]
function Expect([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name $Detail"; $failures.Add($Name) } }
function Remove-CiRules { Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
function Make { Remove-CiRules; New-EoInboundRules -HostIf $Alias -Prefix $prefix -Group $group | Out-Null; New-EoGuardRules -Tag 'ci' -HostIf $Alias -Prefix $prefix -Group $group | Out-Null }
# The active policy can lag the persistent store by a moment.
function Problems([string]$Base) {
    $n = "$prefix$Base"
    $p = @(Test-EoRuleFacts $n (Get-EoRuleFacts $n 'PersistentStore') $all[$Base])
    for ($i = 0; $i -lt 20; $i++) {
        $a = @(Test-EoRuleFacts $n (Get-EoRuleFacts $n 'ActiveStore') $all[$Base] -Active)
        if (-not $a.Count) { break }
        Start-Sleep -Milliseconds 500
    }
    return @($p + $a)
}

# The first interface the firewall accepts as an InterfaceAlias (runner adapters vary).
if (-not $Alias) {
    $cands = @(@(Get-NetIPInterface -AddressFamily IPv4 | Where-Object InterfaceAlias -notlike 'Loopback*' | Sort-Object InterfaceMetric | ForEach-Object InterfaceAlias) + @(Get-NetAdapter -IncludeHidden | ForEach-Object Name) | Select-Object -Unique)
    Write-Host "candidate interfaces: $($cands -join ', ')"
    foreach ($c in $cands) {
        try {
            New-NetFirewallRule -Name "${prefix}probe" -DisplayName "${prefix}probe" -Group $group -Direction Outbound -Action Block -Enabled False -InterfaceAlias $c -ErrorAction Stop | Out-Null
            $Alias = $c; break
        } catch { Write-Host "  not usable: $c ($($_.Exception.Message))" } finally { Remove-CiRules }
    }
    if (-not $Alias) { throw 'No interface the firewall accepts as an InterfaceAlias.' }
}
Write-Host "PowerShell $($PSVersionTable.PSVersion); adapter '$Alias'"
# The spec is built for the adapter chosen above.
$specs = Get-EoRuleSpecs -HostIf $Alias
$all = [ordered]@{}; foreach ($k in $specs.Inbound.Keys) { $all[$k] = $specs.Inbound[$k] }; foreach ($k in $specs.Guard.Keys) { $all[$k] = $specs.Guard[$k] }
try {
    Make
    foreach ($b in $all.Keys) {
        $facts = Get-EoRuleFacts "$prefix$b" 'ActiveStore'
        Write-Host "facts $b (active): $(($facts.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$(@($_.Value) -join '|')" }) -join '; ')"
        $p = @(Problems $b)
        Expect "live: $b as created by the step matches its spec in both stores" ($p.Count -eq 0) ($p -join '; ')
    }
    $alter = [ordered]@{
        'tcp: port 22 no longer excluded'   = @('eo-l2-out-block-tcp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -RemotePort '1-65535' })
        'tcp: one port range dropped'       = @('eo-l2-out-block-tcp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -RemotePort '1-21' })
        'udp: limited to name-query ports'  = @('eo-l2-out-block-udp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -RemotePort '137', '5353', '5355' })
        'icmp: limited to echo requests'    = @('eo-l2-out-block-icmp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-icmp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -IcmpType 8 })
        'udp: interface scope removed'      = @('eo-l2-out-block-udp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" | Get-NetFirewallInterfaceFilter | Set-NetFirewallInterfaceFilter -InterfaceAlias Any })
        'tcp: limited to one program'       = @('eo-l2-out-block-tcp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" | Get-NetFirewallApplicationFilter | Set-NetFirewallApplicationFilter -Program 'C:\Windows\System32\curl.exe' })
        'udp: limited to an app container'  = @('eo-l2-out-block-udp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" | Get-NetFirewallApplicationFilter | Set-NetFirewallApplicationFilter -Package 'S-1-15-2-1430448594-2639229838-973813799-439329657-1197984847-4069523365-2491785580' })
        'icmp: limited to one service'      = @('eo-l2-out-block-icmp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-icmp" | Get-NetFirewallServiceFilter | Set-NetFirewallServiceFilter -Service 'Dnscache' })
        'tcp: one remote address only'      = @('eo-l2-out-block-tcp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress '192.168.250.2' })
        'udp: wireless interfaces only'     = @('eo-l2-out-block-udp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" | Get-NetFirewallInterfaceTypeFilter | Set-NetFirewallInterfaceTypeFilter -InterfaceType Wireless })
        'tcp: disabled'                     = @('eo-l2-out-block-tcp', { Set-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" -Enabled False })
        'udp: Public profile only'          = @('eo-l2-out-block-udp', { Set-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" -Profile Public })
        'icmp: turned into an allow rule'   = @('eo-l2-out-block-icmp', { Set-NetFirewallRule -Name "${prefix}eo-l2-out-block-icmp" -Action Allow })
        'icmp: protocol changed to ICMPv6'  = @('eo-l2-out-block-icmp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-icmp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol ICMPv6 })
        'subnet: widened to a /24'          = @('eo-l2-block-guest-subnet', { Get-NetFirewallRule -Name "${prefix}eo-l2-block-guest-subnet" | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress '192.168.250.0/24' })
        'interface rule: scope removed'     = @('eo-l2-block-interface', { Get-NetFirewallRule -Name "${prefix}eo-l2-block-interface" | Get-NetFirewallInterfaceFilter | Set-NetFirewallInterfaceFilter -InterfaceAlias Any })
        'tcp: rule deleted'                 = @('eo-l2-out-block-tcp', { Remove-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" })
    }
    foreach ($k in $alter.Keys) {
        Make
        $base = $alter[$k][0]
        try { & $alter[$k][1] | Out-Null } catch { Expect "live: alteration '$k' could be applied" $false $_.Exception.Message; continue }
        $p = @(Test-EoRuleFacts "$prefix$base" (Get-EoRuleFacts "$prefix$base" 'PersistentStore') $all[$base])
        Expect "live: $k fails verification" ($p.Count -gt 0) 'no problem reported'
        if ($p.Count) { Write-Host "     -> $($p[0])" }
    }
} finally {
    Remove-CiRules
    $left = @(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count
    Write-Host "cleanup: $left eo-l2-ci rules left"
}
if ($failures.Count) { Write-Host "$($failures.Count) failure(s)"; exit 1 }
Write-Host 'all live rule checks passed'
exit 0
