# Firewall rule and host guard (01b) checks for the eo-l2 host scripts. Dot-sourced
# by _common.ps1. The Test-* functions are pure: they take plain facts and return
# a list of problems (empty when all is well), so tests/selftest.ps1 can feed them
# altered facts and show that each change is caught.

# A value set in one canonical form: lower case, sorted, comma-joined.
function ConvertTo-EoCanon($Values) { (@($Values) | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Sort-Object) -join ',' }

# The exact shape of each eo-l2 rule. The filters the firewall cmdlets expose for
# narrowing a rule are listed (program, package, service, user, machine, port,
# address, dynamic keyword address, interface, interface type, platform, owner),
# so a rule limited by any of them fails; so does one moved to another group. Each
# filter lists its accepted canonical forms (Windows may write 192.168.250.0/29 as
# 192.168.250.0/255.255.255.248; '' is an empty value). -HostIf and -Group let the
# CI test check real rules on another adapter and in its own group.
function Get-EoRuleSpecs([string]$HostIf = $EO.HostIf, [string]$Group = $EO.FwGroup) {
    $any = @('any')
    $common = @{
        Enabled = @('true'); Action = @('block'); Profile = $any; Owner = @(''); Platform = @(''); Group = @((ConvertTo-EoCanon $Group))
        RemoteDynamicKeywordAddresses = @('')
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
    $f = @{
        Present = $true; Group = "$($r.Group)"; Enabled = "$($r.Enabled)"; Action = "$($r.Action)"; Direction = "$($r.Direction)"; Profile = "$($r.Profile)"
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
    # Dynamic keyword addresses (Windows 10 21H2 and later) narrow a rule without
    # showing in RemoteAddress. Where Windows has them but the property is not found,
    # the key stays out and the check reports it as not read.
    $kw = @($af, $r) | Where-Object { $_ -and 'RemoteDynamicKeywordAddresses' -in @($_.PSObject.Properties.Name) } | Select-Object -First 1
    if ($kw) { $f.RemoteDynamicKeywordAddresses = @($kw.RemoteDynamicKeywordAddresses) }
    elseif (-not (Get-Command New-NetFirewallRule).Parameters.ContainsKey('RemoteDynamicKeywordAddresses')) { $f.RemoteDynamicKeywordAddresses = @() }
    return $f
}

# Problems with the firewall profiles (active policy) for rules on $HostIf: each of
# the three must be on, block inbound by default, apply local rules, and not exempt
# the host vNIC (DisabledInterfaceAliases switches the firewall off on an interface,
# and every eo-l2 rule on it with it, while the rules still read as in force).
# $Profiles: @{ Name; Enabled; DefaultInboundAction; AllowLocalFirewallRules; DisabledInterfaceAliases }
function Test-EoProfileFacts($Profiles, [string]$HostIf = $EO.HostIf) {
    $p = New-Object System.Collections.Generic.List[string]
    $all = @($Profiles)
    if ($all.Count -ne 3) { $p.Add("$($all.Count) firewall profiles read, want 3") }
    foreach ($f in $all) {
        if ("$($f.Enabled)" -ne 'True') { $p.Add("profile $($f.Name): Enabled is '$($f.Enabled)'") }
        if ("$($f.DefaultInboundAction)" -notin @('Block', 'NotConfigured')) { $p.Add("profile $($f.Name): DefaultInboundAction is '$($f.DefaultInboundAction)'") }
        if ("$($f.AllowLocalFirewallRules)" -eq 'False') { $p.Add("profile $($f.Name): AllowLocalFirewallRules is False") }
        if (-not $f.ContainsKey('DisabledInterfaceAliases')) { $p.Add("profile $($f.Name): DisabledInterfaceAliases was not read"); continue }
        $off = @(@($f.DisabledInterfaceAliases) | Where-Object { "$_".Trim() -ieq $HostIf -or "$_".Trim() -ieq 'Any' })
        if ($off.Count) { $p.Add("profile $($f.Name): DisabledInterfaceAliases exempts '$($off -join "', '")' from the firewall") }
    }
    return $p
}

function Get-EoProfileFacts {
    @(Get-NetFirewallProfile -PolicyStore ActiveStore | ForEach-Object {
            @{ Name = "$($_.Name)"; Enabled = "$($_.Enabled)"; DefaultInboundAction = "$($_.DefaultInboundAction)"
                AllowLocalFirewallRules = "$($_.AllowLocalFirewallRules)"; DisabledInterfaceAliases = @($_.DisabledInterfaceAliases) }
        })
}

# Enabled rules in the active policy that may override block rules (an IPsec
# authenticated bypass would let traffic past the eo-l2 blocks).
function Get-EoOverrideRules {
    $ids = @(Get-NetFirewallSecurityFilter -PolicyStore ActiveStore -All | Where-Object { "$($_.OverrideBlockRules)" -eq 'True' } | ForEach-Object InstanceID)
    if (-not $ids.Count) { return @() }
    return @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True | Where-Object { $_.InstanceID -in $ids })
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

# The record's folder and file must be writable by Administrators and SYSTEM only,
# owned by one of them, and not a link, or a standard-user process could rewrite
# the value the elevated undo restores.
$EoAdminSids = @('S-1-5-32-544', 'S-1-5-18')

# Problems with plain ACL facts. $Facts: @{ Path; Reparse; Container; Owner (SID);
# Protected (inheritance off); Allow = @(SIDs of Allow entries) }. The folder must
# have inheritance off; the file inherits from it.
function Test-EoAclFacts($Facts, [switch]$Container) {
    $p = New-Object System.Collections.Generic.List[string]
    if ($Facts.Reparse) { $p.Add("$($Facts.Path) is a link (reparse point)") }
    if ([bool]$Facts.Container -ne [bool]$Container) { $p.Add("$($Facts.Path) is $(if ($Facts.Container) { 'a folder' } else { 'a file' }), want $(if ($Container) { 'a folder' } else { 'a file' })") }
    if ("$($Facts.Owner)" -notin $EoAdminSids) { $p.Add("$($Facts.Path) is owned by $($Facts.Owner), want Administrators or SYSTEM") }
    if ($Container -and -not $Facts.Protected) { $p.Add("$($Facts.Path) inherits permissions from its parent") }
    if (-not @(@($Facts.Allow) | Where-Object { "$_" }).Count) { $p.Add("$($Facts.Path) has no access entries (an empty or null ACL)") }
    $others = @(@($Facts.Allow) | Where-Object { "$_" -notin $EoAdminSids } | Sort-Object -Unique)
    if ($others.Count) { $p.Add("$($Facts.Path) grants access to $($others -join ', ')") }
    return $p
}

function Get-EoAclFacts([string]$Path) {
    $i = Get-Item -LiteralPath $Path -Force
    $acl = Get-Acl -LiteralPath $Path
    $sid = [System.Security.Principal.SecurityIdentifier]
    return @{ Path = $Path; Reparse = [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint); Container = [bool]$i.PSIsContainer
        Owner = "$($acl.GetOwner($sid).Value)"; Protected = [bool]$acl.AreAccessRulesProtected
        Allow = @($acl.GetAccessRules($true, $true, $sid) | Where-Object { "$($_.AccessControlType)" -eq 'Allow' } | ForEach-Object { "$($_.IdentityReference.Value)" }) }
}

# Makes the record folder (Administrators and SYSTEM only, owned by Administrators)
# and checks it, or checks the one already there. It must be empty: anything in it
# that this step did not write is not trusted.
function Initialize-EoGuardDir([string]$Path = $EO.GuardDir) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
        Invoke-EoNative icacls.exe @($Path, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F') | Write-Host
        Invoke-EoNative icacls.exe @($Path, '/setowner', '*S-1-5-32-544') | Write-Host
    }
    $p = @(Test-EoAclFacts (Get-EoAclFacts $Path) -Container)
    $items = @(Get-ChildItem -LiteralPath $Path -Force)
    if ($items.Count) { $p += "$Path is not empty: $(($items | ForEach-Object Name) -join ', ')" }
    if ($p.Count) { throw "Refusing to use $Path for the host guard record: $($p -join '; '). Check who made it, remove it, and rerun." }
}

# The record, or $null when there is none. Throws when the folder or file is not
# protected as above, so a record anyone else could have written is never used.
function Read-EoGuardState {
    if (-not (Test-Path -LiteralPath $EO.GuardState)) { return $null }
    $p = @(Test-EoAclFacts (Get-EoAclFacts $EO.GuardDir) -Container) + @(Test-EoAclFacts (Get-EoAclFacts $EO.GuardState))
    if ($p.Count) { throw "the host guard record is not protected: $($p -join '; ')" }
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

# --- filter guard (01c, B9-R1) -------------------------------------------------
# 01c unbinds the Npcap and VirtualBox NDIS filters, PPPoE and NDIS user-mode I/O
# ($EO.FilterTargets) from the host vNIC only, and disables the NDIS Capture extension ($EO.SwitchExtTargets) on
# the eo-l2-int switch only. Like 01b, it records every target's state before it changes
# anything, in a protected file next to the host guard record; the undo restores
# only from that record, only those components, and only on the same adapter,
# switch and computer, built on the same 01b instance. Pure Test-*/Get-*Plan
# functions take plain facts so tests/selftest.ps1 can drive them.

# /2 added switchExtensions; /3 adds the ms_pppoe and ms_ndisuio targets, so a record
# of another target set is refused by its schema as well as by its entries. No /1 or
# /2 record was ever written on a host (01c has not run yet).
$EoFilterSchema = 'eo-l2-filter-guard/3'

# The filter-guard facts of the host now: the host guard facts (so the same read
# serves Test-EoGuardState) plus the host vNIC's bindings as @{ <ComponentID> =
# Enabled }. Bindings holds every binding (-AllBindings, hidden ones included) and
# is what the target checks use; VisibleBindings holds the default view, the one the
# allowed list was taken from. Both are empty without the adapter. Extensions lists
# the switch's vSwitch extensions (@{ Name; Vendor; Enabled }) and ExtensionStates
# maps each name to Enabled; both are empty without the switch.
function Get-EoFilterCurrent {
    $g = Get-EoGuardCurrent
    $b = @{}; $v = @{}; $names = @{}; $ext = @(); $es = @{}
    if ($g.SwitchId) {
        # A read error stops the caller, as for the bindings.
        try { $raw = @(Get-VMSwitchExtension -VMSwitchName $EO.SwitchName -ErrorAction Stop) } catch { throw "the vSwitch extensions of $($EO.SwitchName) could not be read ($($_.Exception.Message))" }
        $ext = @($raw | ForEach-Object { @{ Name = "$($_.Name)"; Vendor = "$($_.Vendor)"; Enabled = "$($_.Enabled)" } })
        foreach ($x in $ext) { $es[$x.Name] = ($x.Enabled -eq 'True') }
    }
    if ($g.Adapter) {
        # A read error stops the caller: empty bindings would read as "targets absent".
        foreach ($x in @(Get-NetAdapterBinding -Name $EO.HostIf -AllBindings -ErrorAction Stop)) {
            $b["$($x.ComponentID)"] = [bool]$x.Enabled; $names["$($x.ComponentID)"] = "$($x.DisplayName)"
        }
        foreach ($x in @(Get-NetAdapterBinding -Name $EO.HostIf -ErrorAction Stop)) { $v["$($x.ComponentID)"] = [bool]$x.Enabled }
        # IPv4 is always bound to the host vNIC; without it in both views the read is not trusted.
        if (-not $b.ContainsKey('ms_tcpip') -or -not $v.ContainsKey('ms_tcpip')) { throw "the bindings of '$($EO.HostIf)' did not read completely (ms_tcpip missing)" }
    }
    return @{ Computer = $g.Computer; SwitchId = $g.SwitchId; Adapter = $g.Adapter; RuleDescriptions = $g.RuleDescriptions
        Bindings = $b; VisibleBindings = $v; BindingNames = $names; Extensions = $ext; ExtensionStates = $es }
}

# What 01c would do to each target: disable (present and enabled), already-off
# (present and disabled) or absent. One entry per target, in $Targets order.
# $Bindings maps a target to Enabled: the host vNIC bindings with the default
# targets, or ExtensionStates with -Targets $EO.SwitchExtTargets. ComponentId holds
# the target (a binding's ComponentID or an extension's name).
function Get-EoFilterApplyPlan($Bindings, [string[]]$Targets = $EO.FilterTargets) {
    $p = New-Object System.Collections.Generic.List[object]
    foreach ($id in $Targets) {
        $action = if (-not $Bindings.ContainsKey($id)) { 'absent' } elseif ($Bindings[$id]) { 'disable' } else { 'already-off' }
        $p.Add([pscustomobject]@{ ComponentId = $id; Present = $Bindings.ContainsKey($id); EnabledBefore = ($Bindings.ContainsKey($id) -and [bool]$Bindings[$id]); Action = $action })
    }
    return $p
}

# What the undo would do with each recorded target, given the bindings now:
#   enable    was enabled before 01c, is disabled now: re-enable it
#   skip      was enabled, is enabled now (already restored, or 01c stopped before it)
#   leave-off was not enabled before 01c and is not enabled now: no change
#   missing   was enabled, is no longer bound to the adapter: cannot be restored
#   drifted   was not enabled before 01c, is enabled now: someone else changed it
# The undo refuses before any change on missing or drifted (Test-EoFilterRestorePlan).
# -Extensions plans the record's switchExtensions entries against ExtensionStates.
function Get-EoFilterRestorePlan($State, $Bindings, [switch]$Extensions) {
    $p = New-Object System.Collections.Generic.List[object]
    $entries = if ($Extensions) { Get-EoProp $State 'switchExtensions' } else { Get-EoProp $State 'bindings' }
    foreach ($r in @($entries)) {
        $id = "$(Get-EoProp $r $(if ($Extensions) { 'name' } else { 'componentId' }))"
        $was = (Get-EoProp $r 'enabledBefore') -eq $true
        $on = $Bindings.ContainsKey($id) -and [bool]$Bindings[$id]
        $action = if (-not $was) { if ($on) { 'drifted' } else { 'leave-off' } } elseif (-not $Bindings.ContainsKey($id)) { 'missing' } elseif ($on) { 'skip' } else { 'enable' }
        $p.Add([pscustomobject]@{ ComponentId = $id; EnabledBefore = $was; Action = $action })
    }
    return $p
}

# Problems that stop the undo before any change, from a restore plan.
function Test-EoFilterRestorePlan($Plan) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($Plan)) {
        if ($e.Action -eq 'missing') { $p.Add("$($e.ComponentId) was enabled before 01c but is no longer present on '$($EO.HostIf)' or $($EO.SwitchName); it cannot be restored (was it uninstalled?)") }
        if ($e.Action -eq 'drifted') { $p.Add("$($e.ComponentId) was off before 01c but is enabled now; something other than 01c changed it, so the undo will not decide its value") }
    }
    return $p
}

# Problems that stop 01c before any change. Pure: $GuardState is the 01b record (or
# $null), $Current comes from Get-EoFilterCurrent, $RecordPresent says whether a 01c
# record exists, $DirNames lists the names in the record folder, $Extensions the
# vSwitch extensions of eo-l2-int (an enabled one that is neither allowed nor a
# 01c target stops it). 01c also checks the folder's ACL and runs verify-host
# -SwitchOnly first.
function Test-EoFilterPreconditions($GuardState, $Current, [bool]$RecordPresent, $DirNames, $Extensions) {
    $p = New-Object System.Collections.Generic.List[string]
    if ($RecordPresent) { $p.Add("$($EO.FilterState) exists: an earlier 01c was not undone. Run undo-01c-filter-guard.ps1 first") }
    if ($null -eq $GuardState) { $p.Add("no host guard (01b) record at $($EO.GuardState); 01c runs only after 01b") }
    else { foreach ($x in @(Test-EoGuardState $GuardState $Current)) { $p.Add("host guard record: $x") } }
    if (-not $Current.SwitchId -or -not $Current.Adapter) { $p.Add("switch $($EO.SwitchName) or its host adapter is missing") }
    $leaf = Split-Path -Leaf $EO.GuardState
    foreach ($n in @($DirNames)) {
        if ("$n" -ceq (Split-Path -Leaf $EO.FilterVerified)) { $p.Add("$($EO.GuardDir) holds '$n', the completion stamp of an earlier 01c that was not undone. Run undo-01c-filter-guard.ps1 first") }
        elseif ("$n" -ceq "$(Split-Path -Leaf $EO.FilterVerified).tmp") { $p.Add("$($EO.GuardDir) holds '$n', left by an interrupted 01c after its changes but before its completion stamp was in place. Review that 01c transcript; delete the file (elevated) only after undo-01c-filter-guard.ps1 has closed the record") }
        elseif ("$n" -ceq "$(Split-Path -Leaf $EO.FilterState).tmp") { $p.Add("$($EO.GuardDir) holds '$n', left by an interrupted 01c before its record was in place; no binding or extension was changed then. Check its contents and delete it (elevated), then rerun") }
        elseif ("$n" -cne $leaf) { $p.Add("$($EO.GuardDir) holds '$n', which no step wrote") }
    }
    foreach ($x in @(Test-EoUnknownBindings $Current.VisibleBindings)) { $p.Add($x) }
    foreach ($x in @(Test-EoSwitchExtensions $Extensions)) { $p.Add($x) }
    # The plan matches targets case-insensitively (hashtable keys) but every later
    # check case-exactly, so a target reported in another case would be changed and
    # then read as collateral: refuse it here, before any change.
    foreach ($k in @(@($Current.Bindings.Keys) | Where-Object { "$_" -in $EO.FilterTargets -and "$_" -cnotin $EO.FilterTargets })) { $p.Add("binding '$k' on '$($EO.HostIf)' differs in case from its filter target; review before running 01c") }
    foreach ($k in @(@($Current.ExtensionStates.Keys) | Where-Object { "$_" -in $EO.SwitchExtTargets -and "$_" -cnotin $EO.SwitchExtTargets })) { $p.Add("switch extension '$k' on $($EO.SwitchName) differs in case from its filter target; review before running 01c") }
    return $p
}

# Changes the binding of filter targets on the host vNIC: the only place 01c and
# its undo change a binding. Refuses before any change if an id is not a target.
# -AllBindings, because ms_pppoe and ms_ndisuio are hidden bindings: without it the
# cmdlets do not see them (the same view Get-EoFilterCurrent reads). A failed call
# stops the caller.
function Set-EoFilterBindings([string[]]$ComponentIds, [switch]$Enable) {
    $bad = @($ComponentIds | Where-Object { $_ -cnotin $EO.FilterTargets })
    if ($bad.Count) { throw "Refusing to change bindings that are not filter-guard targets: $($bad -join ', ')" }
    foreach ($id in $ComponentIds) {
        if ($Enable) { Enable-NetAdapterBinding -Name $EO.HostIf -ComponentID $id -AllBindings -ErrorAction Stop }
        else { Disable-NetAdapterBinding -Name $EO.HostIf -ComponentID $id -AllBindings -ErrorAction Stop }
    }
}

# Changes extension targets on the eo-l2-int switch: the only place 01c and its undo
# change a vSwitch extension. Acts on the switch object with the recorded id, never
# by name (two switches could share a name), and refuses before any change if a
# name is not a target or that id is not exactly one Internal switch named eo-l2-int.
function Set-EoSwitchExtensions([string[]]$Names, [string]$SwitchId, [switch]$Enable) {
    $bad = @($Names | Where-Object { $_ -cnotin $EO.SwitchExtTargets })
    if ($bad.Count) { throw "Refusing to change switch extensions that are not filter-guard targets: $($bad -join ', ')" }
    if (-not @($Names).Count) { return }
    if ("$SwitchId" -notmatch '\A[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z') { throw "Refusing to change switch extensions: switch id '$SwitchId' is malformed" }
    $sw = @(Get-VMSwitch -Id $SwitchId -ErrorAction Stop)
    if ($sw.Count -ne 1 -or "$($sw[0].Name)" -cne $EO.SwitchName -or "$($sw[0].SwitchType)" -ne 'Internal') { throw "Refusing to change switch extensions: id $SwitchId is not exactly one Internal switch named $($EO.SwitchName)" }
    foreach ($n in $Names) {
        if ($Enable) { Enable-VMSwitchExtension -VMSwitch $sw[0] -Name $n }
        else { Disable-VMSwitchExtension -VMSwitch $sw[0] -Name $n }
    }
}

# Problems with a filter guard record (as read from JSON) against the current host
# and the instance id of the 01b record ($null when there is none).
function Test-EoFilterState($State, $Current, $GuardInstanceId) {
    $p = New-Object System.Collections.Generic.List[string]
    if ($null -eq $State) { $p.Add("no filter guard record at $($EO.FilterState); the bindings before 01c are unknown"); return $p }
    $names = @($State.PSObject.Properties.Name)
    foreach ($k in 'schema', 'instanceId', 'computer', 'switchId', 'adapter', 'hostGuardInstanceId', 'bindings', 'switchExtensions') { if ($k -notin $names) { $p.Add("filter record has no '$k'") } }
    if ($p.Count) { return $p }
    foreach ($k in 'schema', 'instanceId', 'computer', 'switchId', 'hostGuardInstanceId') { if ($State.$k -isnot [string]) { $p.Add("filter record $k is not a single string") } }
    if ($p.Count) { return $p }
    if ($State.schema -cne $EoFilterSchema) { $p.Add("filter record schema is '$($State.schema)', want '$EoFilterSchema'") }
    foreach ($k in 'instanceId', 'hostGuardInstanceId') { if ($State.$k -cnotmatch '\A[0-9a-f]{32}\z') { $p.Add("filter record $k '$($State.$k)' is malformed") } }
    $recs = @($State.bindings)
    $ids = @($recs | ForEach-Object { "$(Get-EoProp $_ 'componentId')" })
    if ((@($ids | Sort-Object) -join ',') -cne (@($EO.FilterTargets | Sort-Object) -join ',')) { $p.Add("filter record components are '$($ids -join ',')', want '$($EO.FilterTargets -join ',')'") }
    foreach ($r in $recs) {
        $pr = Get-EoProp $r 'present'; $eb = Get-EoProp $r 'enabledBefore'
        if ($pr -isnot [bool] -or $eb -isnot [bool]) { $p.Add("filter record entry '$(Get-EoProp $r 'componentId')' needs boolean present and enabledBefore"); continue }
        if ($eb -and -not $pr) { $p.Add("filter record entry '$(Get-EoProp $r 'componentId')' is enabledBefore but not present") }
    }
    $xrecs = @($State.switchExtensions)
    # Read the value directly: a function's output would unroll a one-item list into a string.
    foreach ($r in $xrecs) { $np = if ($r -is [psobject]) { $r.PSObject.Properties['name'] } else { $null }; if (-not $np -or $np.Value -isnot [string]) { $p.Add("filter record extension name '$(Get-EoProp $r 'name')' is not a single string") } }
    $xn = @($xrecs | ForEach-Object { "$(Get-EoProp $_ 'name')" })
    if ((@($xn | Sort-Object) -join ',') -cne (@($EO.SwitchExtTargets | Sort-Object) -join ',')) { $p.Add("filter record switch extensions are '$($xn -join ',')', want '$($EO.SwitchExtTargets -join ',')'") }
    foreach ($r in $xrecs) {
        $pr = Get-EoProp $r 'present'; $eb = Get-EoProp $r 'enabledBefore'
        if ($pr -isnot [bool] -or $eb -isnot [bool]) { $p.Add("filter record extension '$(Get-EoProp $r 'name')' needs boolean present and enabledBefore"); continue }
        if ($eb -and -not $pr) { $p.Add("filter record extension '$(Get-EoProp $r 'name')' is enabledBefore but not present") }
    }
    if ($State.computer -ne $Current.Computer) { $p.Add("filter record is for computer '$($State.computer)', this is '$($Current.Computer)'") }
    $a = $State.adapter
    foreach ($k in 'interfaceGuid', 'macAddress', 'settingId') { $v = Get-EoProp $a $k; if ($v -isnot [string] -or -not $v) { $p.Add("filter record adapter has no $k") } }
    if ($Current.Adapter) {
        if ("$($State.switchId)" -ne "$($Current.SwitchId)") { $p.Add("switch id is $($Current.SwitchId), the filter record has $($State.switchId): another provisioning instance") }
        foreach ($k in 'InterfaceGuid', 'MacAddress', 'SettingId') {
            $rec = "$(Get-EoProp $a $k)"
            if ($rec -ne "$($Current.Adapter[$k])") { $p.Add("adapter $k is '$($Current.Adapter[$k])', the filter record has '$rec': another adapter") }
        }
        if ("$GuardInstanceId" -ne "$($State.hostGuardInstanceId)") { $p.Add("the filter record builds on host guard instance '$($State.hostGuardInstanceId)', the host guard record is '$GuardInstanceId'") }
    } elseif ($Current.SwitchId) {
        $p.Add("switch $($EO.SwitchName) exists but its host adapter was not found; cannot tell which adapter to restore")
    }
    return $p
}

# Problems with the host vNIC's bindings: each filter target must be absent or
# disabled. $Bindings: @{ <ComponentID> = Enabled }.
function Test-EoFilterBindings($Bindings) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($id in $EO.FilterTargets) { if ($Bindings.ContainsKey($id) -and $Bindings[$id]) { $p.Add("$id is enabled on '$($EO.HostIf)'") } }
    return $p
}

# Enabled components on the host vNIC that are neither allowed nor a filter target
# (targets have their own check), so a newly installed filter or protocol fails the
# verifier instead of passing silently. Callers pass the default (non-hidden)
# binding view, which the allowed list was taken from.
function Test-EoUnknownBindings($Bindings) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($Bindings.Keys | Sort-Object)) {
        if ($Bindings[$id] -and $id -notin $EO.FilterAllowed -and $id -notin $EO.FilterTargets) { $p.Add("$id is enabled on '$($EO.HostIf)' and is not in the allowed list") }
    }
    return $p
}

# Problems with the vSwitch extensions of eo-l2-int: only $EO.SwitchExtAllowed may be
# enabled, besides the 01c targets, which Test-EoFilterExtensions checks (so a
# third-party extension cannot see or inject frames inside the switch).
# $Extensions: @{ Name; Vendor; Enabled }.
function Test-EoSwitchExtensions($Extensions) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($Extensions)) {
        if ("$($e.Enabled)" -eq 'True' -and "$($e.Name)" -cnotin $EO.SwitchExtAllowed -and "$($e.Name)" -cnotin $EO.SwitchExtTargets) { $p.Add("switch extension '$($e.Name)' ($($e.Vendor)) is enabled on $($EO.SwitchName)") }
    }
    return $p
}

# Problems with the 01c extension targets on eo-l2-int: each must be absent or
# disabled. $States: @{ <name> = Enabled }.
function Test-EoFilterExtensions($States) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($n in $EO.SwitchExtTargets) { if ($States.ContainsKey($n) -and $States[$n]) { $p.Add("switch extension '$n' is enabled on $($EO.SwitchName)") } }
    return $p
}

# Problems with the hidden adapter that carries eo-l2-int's extensions ($EO.SwitchAdapter):
# for each extension target, exactly one binding of its component, reading as the
# extension does. 01c checks this before it changes anything, so the snapshot's
# exclusion of that adapter from the other-adapter digest hits the right adapter,
# and again after, so the extension and its binding agree. Pure.
function Test-EoSwitchAdapterBindings($Bindings, $ExtensionStates) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($x in $EO.SwitchExtTargets) {
        $c = "$($EO.SwitchExtComponents[$x])"
        $b = @(@($Bindings) | Where-Object { "$($_.ComponentID)" -ceq $c })
        if ($b.Count -ne 1) { $p.Add("'$($EO.SwitchAdapter)' has $($b.Count) $c binding(s), want exactly 1 for the '$x' extension"); continue }
        if (-not $ExtensionStates.ContainsKey($x)) { $p.Add("'$x' is bound on '$($EO.SwitchAdapter)' but not listed among the extensions of $($EO.SwitchName)"); continue }
        if ([bool]$b[0].Enabled -ne [bool]$ExtensionStates[$x]) { $p.Add("$c on '$($EO.SwitchAdapter)' reads Enabled=$([bool]$b[0].Enabled) but the '$x' extension on $($EO.SwitchName) reads $([bool]$ExtensionStates[$x]), so that adapter is not the one the extension maps to") }
    }
    return $p
}

# One read of whether the host vNIC is settled: up, its IPv4 address Preferred and
# its on-link route present. Read-only.
function Test-EoHostIfSettled {
    $nic = @(Get-NetAdapter -Name $EO.HostIf -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -eq 'Up' })
    $ip = @(Get-NetIPAddress -InterfaceAlias $EO.HostIf -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { "$($_.IPAddress)" -eq $EO.HostIp -and "$($_.AddressState)" -eq 'Preferred' })
    $rt = @(Get-NetRoute -InterfaceAlias $EO.HostIf -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { "$($_.DestinationPrefix)" -eq "$($EO.SubnetLow)/29" })
    return ($nic.Count -eq 1 -and $ip.Count -ge 1 -and $rt.Count -ge 1)
}

# Waits (read-only, up to $Seconds) until the host vNIC has read as settled on
# $Stable consecutive polls a second apart: a binding change restarts the adapter, and
# the after snapshot must not catch it before or during the restart. True when settled.
function Wait-EoHostIfAddress([int]$Seconds = 30, [int]$Stable = 3) {
    $run = 0
    for ($i = 0; $i -lt $Seconds; $i++) {
        Start-Sleep -Seconds 1
        if (Test-EoHostIfSettled) { $run++; if ($run -ge $Stable) { return $true } } else { $run = 0 }
    }
    return $false
}

# What must not change while 01c or its undo runs, from Get-EoFilterCurrent before
# the change and after it: the switch id, the host vNIC identity, its NetBIOS value,
# every binding on it other than the targets, and every extension on eo-l2-int
# other than the targets. Pure.
function Test-EoFilterUnchanged($Before, $Now) {
    $p = New-Object System.Collections.Generic.List[string]
    if ("$($Before.SwitchId)" -ne "$($Now.SwitchId)") { $p.Add("switch id changed from '$($Before.SwitchId)' to '$($Now.SwitchId)'") }
    if ([bool]$Before.Adapter -ne [bool]$Now.Adapter) { $p.Add("host adapter '$($EO.HostIf)' $(if ($Now.Adapter) { 'appeared' } else { 'disappeared' })") }
    elseif ($Before.Adapter) {
        foreach ($k in 'InterfaceGuid', 'MacAddress', 'SettingId', 'Netbios') { if ("$($Before.Adapter[$k])" -ne "$($Now.Adapter[$k])") { $p.Add("adapter $k changed from '$($Before.Adapter[$k])' to '$($Now.Adapter[$k])'") } }
    }
    foreach ($id in @(@($Before.Bindings.Keys) + @($Now.Bindings.Keys) | Sort-Object -Unique)) {
        if ($id -cin $EO.FilterTargets) { continue }
        $was = if ($Before.Bindings.ContainsKey($id)) { "$($Before.Bindings[$id])" } else { 'absent' }
        $is = if ($Now.Bindings.ContainsKey($id)) { "$($Now.Bindings[$id])" } else { 'absent' }
        if ($was -ne $is) { $p.Add("$id on '$($EO.HostIf)' changed from $was to $is") }
    }
    foreach ($n in @(@($Before.ExtensionStates.Keys) + @($Now.ExtensionStates.Keys) | Sort-Object -Unique)) {
        if ($n -cin $EO.SwitchExtTargets) { continue }
        $was = if ($Before.ExtensionStates.ContainsKey($n)) { "$($Before.ExtensionStates[$n])" } else { 'absent' }
        $is = if ($Now.ExtensionStates.ContainsKey($n)) { "$($Now.ExtensionStates[$n])" } else { 'absent' }
        if ($was -ne $is) { $p.Add("switch extension '$n' on $($EO.SwitchName) changed from $was to $is") }
    }
    return $p
}

# Collateral changes between the before and after snapshots of 01c or its undo (as
# read back from JSON), enforced, not only printed:
#   - every other adapter's bindings (digest; the Default Switch and WSL switch
#     adapters included), every other switch's extensions (digest), the switches;
#   - the firewall (digest and the eo-l2 rule names), so the 01b guard is untouched;
#   - the IPv4 addresses and routes on the host vNIC;
#   - on the host vNIC only the target bindings, on eo-l2-int only the target
#     extensions, and on its switch adapter only the targets' components
#     (ms_ndiscap is the NDIS Capture extension itself).
# -RequireSwitch (01c): the before snapshot must list the switch's extensions and
# its switch adapter's bindings, so those comparisons are not vacuous. Pure.
function Test-EoSnapshotCollateral($Before, $After, [switch]$RequireSwitch) {
    $p = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'otherBindings', 'otherSwitchExtensions', 'firewall') {
        $b = Get-EoProp $Before $k; $a = Get-EoProp $After $k
        if ("$(Get-EoProp $b 'sha256')" -ne "$(Get-EoProp $a 'sha256')" -or "$(Get-EoProp $b 'count')" -ne "$(Get-EoProp $a 'count')" -or -not "$(Get-EoProp $b 'sha256')") { $p.Add("$k changed (digest $(Get-EoProp $b 'sha256') -> $(Get-EoProp $a 'sha256'))") }
    }
    $j = { param($o, [string]$k) @(Get-EoProp $o $k) | ConvertTo-Json -Depth 4 -Compress }
    $rb = (@(Get-EoProp (Get-EoProp $Before 'firewall') 'eoRules') | Sort-Object) -join ','; $ra = (@(Get-EoProp (Get-EoProp $After 'firewall') 'eoRules') | Sort-Object) -join ','
    if ($rb -cne $ra) { $p.Add('the eo-l2 firewall rules changed') }
    if ((& $j $Before 'vmSwitches') -cne (& $j $After 'vmSwitches')) { $p.Add('the Hyper-V switches changed') }
    $eoIp = { param($o) (@(Get-EoProp $o 'ipAddresses') | Where-Object { "$(Get-EoProp $_ 'if')" -eq $EO.HostIf } | ForEach-Object { "$(Get-EoProp $_ 'ip')/$(Get-EoProp $_ 'prefix')" } | Sort-Object) -join ',' }
    if ((& $eoIp $Before) -cne (& $eoIp $After)) { $p.Add("the IPv4 addresses on '$($EO.HostIf)' changed from '$(& $eoIp $Before)' to '$(& $eoIp $After)'") }
    $eoRt = { param($o) (@(Get-EoProp $o 'routes') | Where-Object { "$_".EndsWith(" on $($EO.HostIf)") } | Sort-Object) -join ',' }
    if ((& $eoRt $Before) -cne (& $eoRt $After)) { $p.Add("the routes on '$($EO.HostIf)' changed") }
    $xc = @($EO.SwitchExtTargets | ForEach-Object { "$($EO.SwitchExtComponents[$_])" })
    $keep = { param($l, $t) @(@($l) | Where-Object { ("$_" -split '\|')[0] -cnotin $t }) -join ',' }
    foreach ($c in @(@('eoBindings', $EO.FilterTargets, "'$($EO.HostIf)'"), @('eoSwitchExtensions', $EO.SwitchExtTargets, "the extensions of $($EO.SwitchName)"), @('eoSwitchAdapterBindings', $xc, "'$($EO.SwitchAdapter)'"))) {
        if ((& $keep (Get-EoProp $Before $c[0]) $c[1]) -cne (& $keep (Get-EoProp $After $c[0]) $c[1])) { $p.Add("$($c[2]) changed outside the targets") }
    }
    if ($RequireSwitch) {
        if (-not @(Get-EoProp $Before 'eoSwitchExtensions').Count) { $p.Add("the before snapshot lists no extensions of $($EO.SwitchName); the extension diff cannot be checked") }
        if (-not @(Get-EoProp $Before 'eoSwitchAdapterBindings').Count) { $p.Add("the before snapshot lists no bindings of '$($EO.SwitchAdapter)'; the switch adapter diff cannot be checked") }
    }
    return $p
}

$EoFilterVerifiedSchema = 'eo-l2-filter-guard-verified/1'

# Problems with 01c's completion stamp (as read from JSON) for the record $State whose
# file hashes to $RecordSha256: it must exist, carry this schema, name the record's
# instance and its hash (so a stamp cannot vouch for another or a changed record).
function Test-EoFilterVerified($Stamp, $State, [string]$RecordSha256) {
    $p = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Stamp) { $p.Add("01c did not complete: no completion stamp at $($EO.FilterVerified) (01c writes it only after its final verification passed). Review the 01c transcript, then run undo-01c-filter-guard.ps1 and 01c again"); return $p }
    $names = @($Stamp.PSObject.Properties.Name)
    # verifiedAt only needs to be there: PowerShell 7's ConvertFrom-Json reads an ISO
    # date string as a DateTime.
    foreach ($k in 'schema', 'instanceId', 'recordSha256', 'verifiedAt') {
        if ($k -notin $names) { $p.Add("completion stamp has no '$k'") }
        elseif ($k -ne 'verifiedAt' -and $Stamp.PSObject.Properties[$k].Value -isnot [string]) { $p.Add("completion stamp $k is not a single string") }
    }
    if ($p.Count) { return $p }
    if ($Stamp.schema -cne $EoFilterVerifiedSchema) { $p.Add("completion stamp schema is '$($Stamp.schema)', want '$EoFilterVerifiedSchema'") }
    if ("$($Stamp.instanceId)" -cne "$(Get-EoProp $State 'instanceId')") { $p.Add("completion stamp is for 01c instance '$($Stamp.instanceId)', the record is '$(Get-EoProp $State 'instanceId')'") }
    if (-not $RecordSha256 -or "$($Stamp.recordSha256)" -ne $RecordSha256) { $p.Add("completion stamp vouches for record SHA256 '$($Stamp.recordSha256)', the record now hashes to '$RecordSha256'") }
    return $p
}

# 01c's completion stamp, or $null when there is none. Throws when the folder or file
# is not protected (Administrators and SYSTEM only, no link).
function Read-EoFilterVerified {
    if (-not (Test-Path -LiteralPath $EO.FilterVerified)) { return $null }
    $p = @(Test-EoAclFacts (Get-EoAclFacts $EO.GuardDir) -Container) + @(Test-EoAclFacts (Get-EoAclFacts $EO.FilterVerified))
    if ($p.Count) { throw "the 01c completion stamp is not protected: $($p -join '; ')" }
    return (Get-Content -LiteralPath $EO.FilterVerified -Raw | ConvertFrom-Json)
}

# Problems that stop a later step (04a) unless 01c is installed and completed: a valid
# record for this computer, switch, adapter and 01b instance, 01c's completion stamp
# for that record (written only after its final verification passed), the adapter
# present, and every binding and extension target absent or off. $Verified is the
# stamp as read (or $null), $RecordSha256 the record file's SHA256 now. Pure; the
# caller also runs verify-host -RequireFilterGuard.
function Test-EoFilterInstalled($State, $Current, $GuardInstanceId, $Verified, [string]$RecordSha256) {
    $p = New-Object System.Collections.Generic.List[string]
    if ($null -eq $State) { $p.Add("the filter guard (01c) is not installed: no record at $($EO.FilterState)"); return $p }
    foreach ($x in @(Test-EoFilterVerified $Verified $State $RecordSha256)) { $p.Add($x) }
    if (-not $Current.Adapter) { $p.Add("host adapter '$($EO.HostIf)' not found") }
    foreach ($x in @(Test-EoFilterState $State $Current $GuardInstanceId)) { $p.Add($x) }
    foreach ($x in @(Test-EoFilterBindings $Current.Bindings)) { $p.Add($x) }
    foreach ($x in @(Test-EoFilterExtensions $Current.ExtensionStates)) { $p.Add($x) }
    return $p
}

# How verify-host treats the filter guard: 'absent' (before 01b: the record must
# not exist), 'check' (rows are mandatory) or 'skip' (-SwitchOnly before 01c, with
# no record yet). Full verification (the VM exists, B9) always checks.
function Get-EoFilterGuardMode([bool]$SwitchOnly, [bool]$BeforeGuard, [bool]$Require, [bool]$RecordPresent) {
    if ($BeforeGuard) { return 'absent' }
    if ($Require -or -not $SwitchOnly -or $RecordPresent) { return 'check' }
    return 'skip'
}

# The filter guard record, or $null when there is none. Throws when the folder or
# file is not protected (Administrators and SYSTEM only, no link).
function Read-EoFilterState {
    if (-not (Test-Path -LiteralPath $EO.FilterState)) { return $null }
    $p = @(Test-EoAclFacts (Get-EoAclFacts $EO.GuardDir) -Container) + @(Test-EoAclFacts (Get-EoAclFacts $EO.FilterState))
    if ($p.Count) { throw "the filter guard record is not protected: $($p -join '; ')" }
    return (Get-Content -LiteralPath $EO.FilterState -Raw | ConvertFrom-Json)
}
