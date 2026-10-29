# CI only (an elevated, disposable Windows runner): creates the five eo-l2 rules
# with the same functions steps 01 and 01b use, under a "eo-l2-ci-" name prefix,
# group "eo-l2-ci" and a real adapter, then reads them back with Get-EoRuleFacts
# from the persistent store and the active policy and checks them against the
# spec. Then it alters one filter at a time with the firewall cmdlets and checks
# that each alteration fails, for the altered filter, in the persistent store and
# in the active policy. It also exempts the adapter from the Public profile and
# checks that the profile check fails. Every rule, keyword address and profile
# setting it changed is put back at the end.
param([string]$Alias)

$hostDir = Split-Path $PSScriptRoot
. (Join-Path $hostDir '_common.ps1')
Assert-EoAdmin

$prefix = 'eo-l2-ci-'; $group = 'eo-l2-ci'
$failures = New-Object System.Collections.Generic.List[string]
function Expect([string]$Name, [bool]$Ok, [string]$Detail = '') { if ($Ok) { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name $Detail"; $failures.Add($Name) } }
function Remove-CiRules { Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule; Get-NetFirewallRule -Group "$group-other" -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
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
$specs = Get-EoRuleSpecs -HostIf $Alias -Group $group
$all = [ordered]@{}; foreach ($k in $specs.Inbound.Keys) { $all[$k] = $specs.Inbound[$k] }; foreach ($k in $specs.Guard.Keys) { $all[$k] = $specs.Guard[$k] }
# A dynamic keyword address for the keyword alteration, where Windows has them.
$kwSupported = [bool](Get-Command New-NetFirewallDynamicKeywordAddress -ErrorAction SilentlyContinue)
$kwId = '{' + [guid]::NewGuid().ToString() + '}'
$profChanged = $false; $savedAliases = $null
try {
    if ($kwSupported) { New-NetFirewallDynamicKeywordAddress -Id $kwId -Keyword 'eo-l2-ci' -Addresses '192.168.250.2' | Out-Null }
    Make
    foreach ($b in $all.Keys) {
        $facts = Get-EoRuleFacts "$prefix$b" 'ActiveStore'
        Write-Host "facts $b (active): $(($facts.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$(@($_.Value) -join '|')" }) -join '; ')"
        $p = @(Problems $b)
        Expect "live: $b as created by the step matches its spec in both stores" ($p.Count -eq 0) ($p -join '; ')
    }
    $alter = [ordered]@{
        'tcp: port 22 no longer excluded'   = @('eo-l2-out-block-tcp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -RemotePort '1-65535' }, 'RemotePort')
        'tcp: one port range dropped'       = @('eo-l2-out-block-tcp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -RemotePort '1-21' }, 'RemotePort')
        'udp: limited to name-query ports'  = @('eo-l2-out-block-udp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -RemotePort '137', '5353', '5355' }, 'RemotePort')
        'icmp: limited to echo requests'    = @('eo-l2-out-block-icmp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-icmp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -IcmpType 8 }, 'IcmpType')
        'udp: interface scope removed'      = @('eo-l2-out-block-udp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" | Get-NetFirewallInterfaceFilter | Set-NetFirewallInterfaceFilter -InterfaceAlias Any }, 'InterfaceAlias')
        'tcp: limited to one program'       = @('eo-l2-out-block-tcp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" | Get-NetFirewallApplicationFilter | Set-NetFirewallApplicationFilter -Program 'C:\Windows\System32\curl.exe' }, 'Program')
        'udp: limited to an app container'  = @('eo-l2-out-block-udp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" | Get-NetFirewallApplicationFilter | Set-NetFirewallApplicationFilter -Package 'S-1-15-2-1430448594-2639229838-973813799-439329657-1197984847-4069523365-2491785580' }, 'Package')
        'icmp: limited to one service'      = @('eo-l2-out-block-icmp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-icmp" | Get-NetFirewallServiceFilter | Set-NetFirewallServiceFilter -Service 'Dnscache' }, 'Service')
        'tcp: one remote address only'      = @('eo-l2-out-block-tcp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress '192.168.250.2' }, 'RemoteAddress')
        'udp: wireless interfaces only'     = @('eo-l2-out-block-udp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" | Get-NetFirewallInterfaceTypeFilter | Set-NetFirewallInterfaceTypeFilter -InterfaceType Wireless }, 'InterfaceType')
        'tcp: disabled'                     = @('eo-l2-out-block-tcp', { Set-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" -Enabled False }, 'Enabled')
        'udp: Public profile only'          = @('eo-l2-out-block-udp', { Set-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp" -Profile Public }, 'Profile')
        'icmp: turned into an allow rule'   = @('eo-l2-out-block-icmp', { Set-NetFirewallRule -Name "${prefix}eo-l2-out-block-icmp" -Action Allow }, 'Action')
        'icmp: protocol changed to ICMPv6'  = @('eo-l2-out-block-icmp', { Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-icmp" | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol ICMPv6 }, 'Protocol')
        'subnet: widened to a /24'          = @('eo-l2-block-guest-subnet', { Get-NetFirewallRule -Name "${prefix}eo-l2-block-guest-subnet" | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress '192.168.250.0/24' }, 'RemoteAddress')
        'interface rule: scope removed'     = @('eo-l2-block-interface', { Get-NetFirewallRule -Name "${prefix}eo-l2-block-interface" | Get-NetFirewallInterfaceFilter | Set-NetFirewallInterfaceFilter -InterfaceAlias Any }, 'InterfaceAlias')
        'tcp: rule deleted'                 = @('eo-l2-out-block-tcp', { Remove-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" }, 'missing')
        'udp: moved to another group'       = @('eo-l2-out-block-udp', { $r = Get-NetFirewallRule -Name "${prefix}eo-l2-out-block-udp"; $r.Group = "$group-other"; $r | Set-NetFirewallRule }, 'Group')
    }
    if ($kwSupported) {
        $alter['tcp: limited to a dynamic keyword address'] = @('eo-l2-out-block-tcp', { Set-NetFirewallRule -Name "${prefix}eo-l2-out-block-tcp" -RemoteDynamicKeywordAddresses $kwId }, 'RemoteDynamicKeywordAddresses')
    } else { Write-Host 'dynamic keyword addresses not supported here; that alteration is skipped' }
    foreach ($k in $alter.Keys) {
        Make
        $base = $alter[$k][0]
        try { & $alter[$k][1] | Out-Null } catch { Expect "live: alteration '$k' could be applied" $false $_.Exception.Message; continue }
        $want = $alter[$k][2]
        $p = @(Test-EoRuleFacts "$prefix$base" (Get-EoRuleFacts "$prefix$base" 'PersistentStore') $all[$base])
        $hit = @($p | Where-Object { $_ -match "^$([regex]::Escape("$prefix$base")): $want\b" })
        Expect "live: $k fails verification for $want (persistent store)" ($hit.Count -gt 0) "reported: $($p -join '; ')"
        # In the active policy a disabled or deleted rule may be absent; either way it must fail.
        for ($i = 0; $i -lt 20; $i++) {
            $a = @(Test-EoRuleFacts "$prefix$base" (Get-EoRuleFacts "$prefix$base" 'ActiveStore') $all[$base] -Active)
            $ahit = @($a | Where-Object { $_ -match "^$([regex]::Escape("$prefix$base")): ($want\b|missing|not in force)" })
            if ($ahit.Count) { break }
            Start-Sleep -Milliseconds 500
        }
        Expect "live: $k fails verification (active policy)" ($ahit.Count -gt 0) "reported: $($a -join '; ')"
        if ($hit.Count) { Write-Host "     -> $($hit[0]) | active: $($ahit[0])" }
    }

    # The firewall turned off on the adapter for one profile: the rules still read
    # as in force, so the profile check has to catch it.
    $before = @(Test-EoProfileFacts (Get-EoProfileFacts) $Alias | Where-Object { $_ -match 'DisabledInterfaceAliases' })
    Expect 'live: profile check reports no exemption before' ($before.Count -eq 0) ($before -join '; ')
    $savedAliases = @((Get-NetFirewallProfile -Profile Public -PolicyStore PersistentStore).DisabledInterfaceAliases)
    Write-Host "Public profile DisabledInterfaceAliases before: $($savedAliases -join '|')"
    $profChanged = $true
    Set-NetFirewallProfile -Profile Public -DisabledInterfaceAliases $Alias
    for ($i = 0; $i -lt 20; $i++) {
        $pp = @(Test-EoProfileFacts (Get-EoProfileFacts) $Alias | Where-Object { $_ -match '^profile Public: DisabledInterfaceAliases exempts' })
        if ($pp.Count) { break }
        Start-Sleep -Milliseconds 500
    }
    Expect 'live: adapter exempted from the Public profile fails the profile check' ($pp.Count -gt 0) 'no problem reported'
    if ($pp.Count) { Write-Host "     -> $($pp[0])" }
} finally {
    Remove-CiRules
    Get-NetFirewallRule -Group "$group-other" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if ($kwSupported) { Remove-NetFirewallDynamicKeywordAddress -Id $kwId -ErrorAction SilentlyContinue }
    if ($profChanged) {
        $restore = if ($savedAliases.Count) { $savedAliases } else { @('NotConfigured') }
        Set-NetFirewallProfile -Profile Public -DisabledInterfaceAliases $restore
        Write-Host "Public profile DisabledInterfaceAliases restored: $(@((Get-NetFirewallProfile -Profile Public -PolicyStore PersistentStore).DisabledInterfaceAliases) -join '|')"
    }
    $left = @(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count
    Write-Host "cleanup: $left eo-l2-ci rules left"
}
# The record folder protection, on real folders under %ProgramData%.
$ciDir = Join-Path $env:ProgramData "eo-l2-ci-$([guid]::NewGuid().ToString('N'))"
$junction = "$ciDir-junction"; $plain = "$ciDir-plain"
try {
    Initialize-EoGuardDir $ciDir
    $df = Get-EoAclFacts $ciDir
    Write-Host "acl facts (new folder): owner=$($df.Owner) protected=$($df.Protected) allow=$(@($df.Allow) -join '|')"
    $p = @(Test-EoAclFacts $df -Container)
    Expect 'live acl: a folder made by Initialize-EoGuardDir passes' ($p.Count -eq 0) ($p -join '; ')
    $file = Join-Path $ciDir 'host-guard-state.json'
    '{}' | Set-Content -Encoding UTF8 -LiteralPath $file
    Invoke-EoNative icacls.exe @($file, '/setowner', '*S-1-5-32-544') | Out-Null
    $p = @(Test-EoAclFacts (Get-EoAclFacts $file))
    Expect 'live acl: a record written in it passes' ($p.Count -eq 0) ($p -join '; ')
    $threw = $false; try { Initialize-EoGuardDir $ciDir } catch { $threw = $_.Exception.Message -match 'is not empty' }
    Expect 'live acl: a folder that is not empty is refused' $threw
    New-Item -ItemType Directory -Path $plain | Out-Null
    $p = @(Test-EoAclFacts (Get-EoAclFacts $plain) -Container)
    Expect 'live acl: a folder made without the ACL (as a user could) fails' (@($p | Where-Object { $_ -match 'inherits permissions|grants access' }).Count -gt 0) ($p -join '; ')
    $threw = $false; try { Initialize-EoGuardDir $plain } catch { $threw = $true }
    Expect 'live acl: Initialize-EoGuardDir refuses a folder made without the ACL' $threw
    Invoke-EoNative cmd.exe @('/c', 'mklink', '/J', $junction, $ciDir) | Out-Null
    $p = @(Test-EoAclFacts (Get-EoAclFacts $junction) -Container)
    Expect 'live acl: a junction to the protected folder fails' (@($p | Where-Object { $_ -match 'is a link' }).Count -gt 0) ($p -join '; ')
    Invoke-EoNative icacls.exe @($ciDir, '/grant', '*S-1-5-32-545:(OI)(CI)M') | Out-Null
    $p = @(Test-EoAclFacts (Get-EoAclFacts $ciDir) -Container)
    Expect 'live acl: the folder with Users granted write fails' (@($p | Where-Object { $_ -match 'grants access to S-1-5-32-545' }).Count -gt 0) ($p -join '; ')
} finally {
    # rmdir removes a junction without touching its target.
    if (Test-Path -LiteralPath $junction) { cmd.exe /c rmdir "$junction" | Out-Null }
    foreach ($d in $ciDir, $plain) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
    Write-Host "cleanup: acl test folders left: $(@($ciDir, $plain, $junction | Where-Object { Test-Path -LiteralPath $_ }).Count)"
}

if ($failures.Count) { Write-Host "$($failures.Count) failure(s)"; exit 1 }
Write-Host 'all live rule checks passed'
exit 0
