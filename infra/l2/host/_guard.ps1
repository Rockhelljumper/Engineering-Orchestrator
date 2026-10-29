# Firewall rule and host guard (01b) checks for the eo-l2 host scripts. Dot-sourced
# by _common.ps1. The Test-* functions are pure: they take plain facts and return
# a list of problems (empty when all is well), so tests/selftest.ps1 can feed them
# altered facts and show that each change is caught.

# A value set in one canonical form: lower case, sorted, comma-joined.
function ConvertTo-EoCanon($Values) { (@($Values) | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Sort-Object) -join ',' }

# The exact shape of each eo-l2 rule. Every filter Windows can use to narrow a
# rule is listed, so a rule that has been limited to one program, package, user,
# machine, port, address or interface fails. Each filter lists its accepted
# canonical forms (Windows may write 192.168.250.0/29 as 192.168.250.0/255.255.255.248;
# '' is an empty value). -HostIf lets the CI test check real rules on another adapter.
function Get-EoRuleSpecs([string]$HostIf = $EO.HostIf) {
    $any = @('any')
    $common = @{
        Enabled = @('true'); Action = @('block'); Profile = $any; Owner = @(''); Platform = @('')
        EdgeTraversalPolicy = @('block'); LooseSourceMapping = @('false'); LocalOnlyMapping = @('false')
        Program = $any; Package = @('', 'any'); Service = $any; InterfaceType = $any
        LocalAddress = $any; LocalPort = $any; DynamicTarget = $any
        Authentication = @('notrequired'); Encryption = @('notrequired'); OverrideBlockRules = @('false')
        LocalUser = $any; RemoteUser = $any; RemoteMachine = $any
    }
    $if = @((ConvertTo-EoCanon $HostIf))
    $inbound = [ordered]@{
        'eo-l2-block-guest-subnet' = $common + @{ Direction = @('inbound'); Protocol = $any; RemotePort = $any; IcmpType = $any; InterfaceAlias = $any; RemoteAddress = @('192.168.250.0/29', '192.168.250.0/255.255.255.248') }
        'eo-l2-block-interface'    = $common + @{ Direction = @('inbound'); Protocol = $any; RemotePort = $any; IcmpType = $any; InterfaceAlias = $if; RemoteAddress = $any }
    }
    $guard = [ordered]@{
        'eo-l2-out-block-tcp'  = $common + @{ Direction = @('outbound'); Protocol = @('tcp'); RemotePort = @((ConvertTo-EoCanon @('1-21', '23-65535'))); IcmpType = $any; InterfaceAlias = $if; RemoteAddress = $any }
        'eo-l2-out-block-udp'  = $common + @{ Direction = @('outbound'); Protocol = @('udp'); RemotePort = $any; IcmpType = $any; InterfaceAlias = $if; RemoteAddress = $any }
        'eo-l2-out-block-icmp' = $common + @{ Direction = @('outbound'); Protocol = @('icmpv4'); RemotePort = $any; IcmpType = $any; InterfaceAlias = $if; RemoteAddress = $any }
    }
    return @{ Inbound = $inbound; Guard = $guard }
}

# Creates the two inbound rules of step 01 (and of the CI live test, with a prefix and group).
function New-EoInboundRules([string]$HostIf = $EO.HostIf, [string]$Prefix = '', [string]$Group = $EO.FwGroup) {
    $fw = @{ Group = $Group; Direction = 'Inbound'; Action = 'Block'; Profile = 'Any'; Enabled = 'True' }
    New-NetFirewallRule @fw -Name "${Prefix}eo-l2-block-guest-subnet" -DisplayName "${Prefix}eo-l2: block inbound from guest subnet" -RemoteAddress "$($EO.SubnetLow)/$($EO.PrefixLength)" | Format-List Name, Action, Direction, Profile
    New-NetFirewallRule @fw -Name "${Prefix}eo-l2-block-interface" -DisplayName "${Prefix}eo-l2: block all inbound on eo-l2-int" -InterfaceAlias $HostIf | Format-List Name, Action, Direction, Profile
}

# Creates the three outbound rules of step 01b, tagged with its instance.
function New-EoGuardRules([string]$Tag, [string]$HostIf = $EO.HostIf, [string]$Prefix = '', [string]$Group = $EO.FwGroup) {
    $out = @{ Group = $Group; Direction = 'Outbound'; Action = 'Block'; Profile = 'Any'; Enabled = 'True'; InterfaceAlias = $HostIf; Description = $Tag }
    New-NetFirewallRule @out -Name "${Prefix}eo-l2-out-block-tcp" -DisplayName "${Prefix}eo-l2: host sends the guest only SSH (TCP)" -Protocol TCP -RemotePort '1-21', '23-65535' | Format-List Name, Action, Direction
    New-NetFirewallRule @out -Name "${Prefix}eo-l2-out-block-udp" -DisplayName "${Prefix}eo-l2: host sends the guest no UDP" -Protocol UDP | Format-List Name, Action, Direction
    New-NetFirewallRule @out -Name "${Prefix}eo-l2-out-block-icmp" -DisplayName "${Prefix}eo-l2: host sends the guest no ICMPv4" -Protocol ICMPv4 | Format-List Name, Action, Direction
}

# Problems with one rule's facts against its spec. Facts come from Get-EoRuleFacts
# (or a test). With -Active the rule must also be in force (PrimaryStatus OK).
function Test-EoRuleFacts([string]$Name, $Facts, $Spec, [switch]$Active) {
    $p = New-Object System.Collections.Generic.List[string]
    if (-not $Facts -or -not $Facts.Present) { $p.Add("${Name}: missing"); return $p }
    foreach ($k in $Spec.Keys) {
        if (-not $Facts.ContainsKey($k)) { $p.Add("${Name}: $k was not read"); continue }
        $have = ConvertTo-EoCanon $Facts[$k]
        if ($have -notin @($Spec[$k])) { $p.Add("${Name}: $k is '$have', want '$(@($Spec[$k]) -join "' or '")'") }
    }
    if ($Active -and "$($Facts.PrimaryStatus)" -ne 'OK') { $p.Add("${Name}: not in force (PrimaryStatus $($Facts.PrimaryStatus))") }
    return $p
}

# Plain facts about one rule in one policy store, read with the firewall cmdlets.
function Get-EoRuleFacts([string]$Name, [string]$Store) {
    $r = Get-NetFirewallRule -PolicyStore $Store -Name $Name -ErrorAction SilentlyContinue
    if (-not $r) { return @{ Present = $false } }
    $pf = $r | Get-NetFirewallPortFilter
    $af = $r | Get-NetFirewallAddressFilter
    $ap = $r | Get-NetFirewallApplicationFilter
    $sf = $r | Get-NetFirewallSecurityFilter
    return @{
        Present = $true; Enabled = "$($r.Enabled)"; Action = "$($r.Action)"; Direction = "$($r.Direction)"; Profile = "$($r.Profile)"
        PrimaryStatus = "$($r.PrimaryStatus)"; EnforcementStatus = "$($r.EnforcementStatus)"; Description = "$($r.Description)"
        Owner = "$($r.Owner)"; Platform = @($r.Platform); EdgeTraversalPolicy = "$($r.EdgeTraversalPolicy)"
        LooseSourceMapping = "$($r.LooseSourceMapping)"; LocalOnlyMapping = "$($r.LocalOnlyMapping)"
        Protocol = "$($pf.Protocol)"; LocalPort = @($pf.LocalPort); RemotePort = @($pf.RemotePort); IcmpType = @($pf.IcmpType); DynamicTarget = "$($pf.DynamicTarget)"
        RemoteAddress = @($af.RemoteAddress); LocalAddress = @($af.LocalAddress)
        InterfaceAlias = @(($r | Get-NetFirewallInterfaceFilter).InterfaceAlias)
        InterfaceType = "$(($r | Get-NetFirewallInterfaceTypeFilter).InterfaceType)"
        Program = "$($ap.Program)"; Package = "$($ap.Package)"
        Service = "$(($r | Get-NetFirewallServiceFilter).Service)"
        Authentication = "$($sf.Authentication)"; Encryption = "$($sf.Encryption)"; OverrideBlockRules = "$($sf.OverrideBlockRules)"
        LocalUser = "$($sf.LocalUser)"; RemoteUser = "$($sf.RemoteUser)"; RemoteMachine = "$($sf.RemoteMachine)"
    }
}

# --- host guard state --------------------------------------------------------
# 01b records what it changed, in one file, before it changes anything. The undo
# restores NetBIOS only from that record, and only on the same adapter, switch
# and computer; anything missing, malformed or different stops it.

$EoGuardSchema = 'eo-l2-host-guard/1'

# A property of a JSON object, or $null when it has none (strict mode throws on a
# missing property).
function Get-EoProp($Obj, [string]$Name) {
    if ($null -eq $Obj -or $Obj -isnot [psobject] -or $Name -notin @($Obj.PSObject.Properties.Name)) { return $null }
    return $Obj.$Name
}

function Get-EoGuardInstanceTag([string]$InstanceId) { "eo-l2 host guard instance $InstanceId" }

# Problems with a guard state record (as read from JSON) against the current host.
# $Current: @{ Computer; SwitchId (or $null); Adapter = @{ InterfaceGuid; MacAddress; SettingId } (or $null);
#              RuleDescriptions = @{ <rule name> = <description> } for guard rules present now }
function Test-EoGuardState($State, $Current) {
    $p = New-Object System.Collections.Generic.List[string]
    if ($null -eq $State) { $p.Add("no host guard state record at $($EO.GuardState); the NetBIOS value before 01b is unknown"); return $p }
    $names = @($State.PSObject.Properties.Name)
    foreach ($k in 'schema', 'instanceId', 'computer', 'switchId', 'adapter', 'netbiosBefore', 'rules') { if ($k -notin $names) { $p.Add("state record has no '$k'") } }
    if ($p.Count) { return $p }
    foreach ($k in 'schema', 'instanceId', 'computer', 'switchId') { if ($State.$k -isnot [string]) { $p.Add("state record $k is not a single string") } }
    if ($p.Count) { return $p }
    if ($State.schema -cne $EoGuardSchema) { $p.Add("state record schema is '$($State.schema)', want '$EoGuardSchema'") }
    if ($State.instanceId -cnotmatch '\A[0-9a-f]{32}\z') { $p.Add("state record instanceId '$($State.instanceId)' is malformed") }
    if ((ConvertTo-EoCanon $State.rules) -cne (ConvertTo-EoCanon $EO.GuardRules)) { $p.Add("state record rules are '$(@($State.rules) -join ',')', want '$($EO.GuardRules -join ',')'") }
    $nb = $State.netbiosBefore
    if (-not ($nb -is [int] -or $nb -is [long]) -or $nb -lt 0 -or $nb -gt 2) { $p.Add("state record netbiosBefore '$nb' is not 0, 1 or 2") }
    if ($State.computer -ne $Current.Computer) { $p.Add("state record is for computer '$($State.computer)', this is '$($Current.Computer)'") }
    $a = $State.adapter
    foreach ($k in 'interfaceGuid', 'macAddress', 'settingId') { $v = Get-EoProp $a $k; if ($v -isnot [string] -or -not $v) { $p.Add("state record adapter has no $k") } }
    if ($Current.Adapter) {
        if ("$($State.switchId)" -ne "$($Current.SwitchId)") { $p.Add("switch id is $($Current.SwitchId), the record has $($State.switchId): another provisioning instance") }
        foreach ($k in 'InterfaceGuid', 'MacAddress', 'SettingId') {
            $rec = "$(Get-EoProp $a $k)"
            if ($rec -ne "$($Current.Adapter[$k])") { $p.Add("adapter $k is '$($Current.Adapter[$k])', the record has '$rec': another adapter") }
        }
    } elseif ($Current.SwitchId) {
        $p.Add("switch $($EO.SwitchName) exists but its host adapter was not found; cannot tell which adapter to restore")
    }
    $tag = Get-EoGuardInstanceTag "$($State.instanceId)"
    foreach ($n in @($Current.RuleDescriptions.Keys)) {
        if ($Current.RuleDescriptions[$n] -ne $tag) { $p.Add("rule $n belongs to another instance ('$($Current.RuleDescriptions[$n])')") }
    }
    return $p
}

function Read-EoGuardState {
    if (-not (Test-Path -LiteralPath $EO.GuardState)) { return $null }
    return (Get-Content -LiteralPath $EO.GuardState -Raw | ConvertFrom-Json)
}

# The current host facts Test-EoGuardState compares against.
function Get-EoGuardCurrent {
    $sw = Get-VMSwitch -Name $EO.SwitchName -ErrorAction SilentlyContinue
    $nic = Get-NetAdapter -Name $EO.HostIf -ErrorAction SilentlyContinue
    $adapter = $null
    if ($nic) {
        $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $($nic.ifIndex)"
        $adapter = @{ InterfaceGuid = "$($nic.InterfaceGuid)"; MacAddress = "$($nic.MacAddress)"; SettingId = "$($cfg.SettingID)"; Netbios = $cfg.TcpipNetbiosOptions; Config = $cfg }
    }
    $desc = @{}
    foreach ($n in $EO.GuardRules) {
        $r = Get-NetFirewallRule -PolicyStore PersistentStore -Name $n -ErrorAction SilentlyContinue
        if ($r) { $desc[$n] = "$($r.Description)" }
    }
    return @{ Computer = $env:COMPUTERNAME; SwitchId = $(if ($sw) { "$($sw.Id)" } else { $null }); Adapter = $adapter; RuleDescriptions = $desc }
}
