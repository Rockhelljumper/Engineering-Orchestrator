# CI self-test for the eo-l2 host scripts. Changes nothing: it parses every
# script and exercises the pure helpers in _common.ps1. Runs under Windows
# PowerShell 5.1 and PowerShell 7.
#   -KeyDir: folder holding "plain" (no passphrase) and "locked" (passphrase)
#            ed25519 private keys made by ssh-keygen.
param([Parameter(Mandatory)][string]$KeyDir)

$hostDir = Split-Path $PSScriptRoot
. (Join-Path $hostDir '_common.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Expect([string]$Name, $Actual, $Expected) {
    if ("$Actual" -ceq "$Expected") { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name (got '$Actual', want '$Expected')"; $failures.Add($Name) }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

foreach ($f in Get-ChildItem -Path $hostDir -Recurse -Filter *.ps1) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    Expect "parses: $($f.Name)" $errors.Count 0
    foreach ($e in $errors) { Write-Host "     $($e.Extent.StartLineNumber): $($e.Message)" }
}

Expect 'overlap: same /29' (Test-EoOverlap '192.168.250.0' 29) $true
Expect 'overlap: host address' (Test-EoOverlap '192.168.250.5' 32) $true
Expect 'overlap: next /29' (Test-EoOverlap '192.168.250.8' 29) $false
Expect 'overlap: previous address' (Test-EoOverlap '192.168.249.255' 32) $false
Expect 'overlap: 192.168.0.0/16' (Test-EoOverlap '192.168.0.0' 16) $true
Expect 'overlap: 192.168.250.0/24' (Test-EoOverlap '192.168.250.0' 24) $true
Expect 'overlap: 10.0.0.0/8' (Test-EoOverlap '10.0.0.0' 8) $false
Expect 'overlap: 0.0.0.0/1' (Test-EoOverlap '0.0.0.0' 1) $false
Expect 'overlap: 128.0.0.0/1' (Test-EoOverlap '128.0.0.0' 1) $true
Expect 'overlap: 172.16.0.0/12' (Test-EoOverlap '172.16.0.0' 12) $false

Expect 'network: /24' (Get-EoNetwork '192.168.1.57' 24) '192.168.1.0/24'
Expect 'network: /20' (Get-EoNetwork '172.20.150.1' 20) '172.20.144.0/20'
Expect 'network: /32' (Get-EoNetwork '10.1.2.3' 32) '10.1.2.3/32'
Expect 'network: /0' (Get-EoNetwork '10.1.2.3' 0) '0.0.0.0/0'

$out = Invoke-EoNative cmd.exe @('/c', 'echo to-stdout & echo to-stderr 1>&2 & exit 0')
Expect 'native: stdout kept' (@($out | ForEach-Object { $_.Trim() }) -contains 'to-stdout') $true
Expect 'native: stderr kept, not thrown' (@($out | ForEach-Object { $_.Trim() }) -contains 'to-stderr') $true
$filtered = @(Invoke-EoNative cmd.exe @('/c', 'echo alpha & echo beta') | Where-Object { $_ -match '^beta' })
Expect 'native: a pipeline filter sees single lines' ($filtered.Count) 1
$threw = $false
try { Invoke-EoNative cmd.exe @('/c', 'exit 3') | Out-Null } catch { $threw = $true }
Expect 'native: non-zero exit throws' $threw $true
$threw = $false
try { Invoke-EoNative cmd.exe @('/c', 'exit 3') -AllowFail | Out-Null } catch { $threw = $true }
Expect 'native: -AllowFail does not throw' $threw $false

Expect 'key: no passphrase detected' (Test-EoKeyEncrypted (Join-Path $KeyDir 'plain')) $false
Expect 'key: passphrase detected' (Test-EoKeyEncrypted (Join-Path $KeyDir 'locked')) $true
$threw = $false
try { Test-EoKeyEncrypted (Join-Path $KeyDir 'plain.pub') | Out-Null } catch { $threw = $true }
Expect 'key: public key rejected' $threw $true

# --- eo-l2 firewall rules: exact filters, and any alteration fails -------------
$specs = Get-EoRuleSpecs
$allSpecs = [ordered]@{}
foreach ($k in $specs.Inbound.Keys) { $allSpecs[$k] = $specs.Inbound[$k] }
foreach ($k in $specs.Guard.Keys) { $allSpecs[$k] = $specs.Guard[$k] }
Expect 'rules: five specs (two inbound, three guard)' "$($specs.Inbound.Count)/$($specs.Guard.Count)" '2/3'
function GoodFacts($Spec) {
    $f = @{ Present = $true; PrimaryStatus = 'OK' }
    foreach ($k in $Spec.Keys) { $f[$k] = (@($Spec[$k])[0] -split ',') }
    return $f
}
foreach ($n in $allSpecs.Keys) {
    $spec = $allSpecs[$n]
    Expect "rules: $n as specified passes" (@(Test-EoRuleFacts $n (GoodFacts $spec) $spec -Active).Count) 0
    Expect "rules: $n missing fails" (@(Test-EoRuleFacts $n @{ Present = $false } $spec).Count -gt 0) $true
    $f = GoodFacts $spec; $f.PrimaryStatus = 'Inactive'
    Expect "rules: $n not in force fails (active)" (@(Test-EoRuleFacts $n $f $spec -Active).Count -gt 0) $true
    foreach ($k in $spec.Keys) {
        $f = GoodFacts $spec; $f[$k] = @('eo-mutated')
        Expect "rules: $n altered $k fails for $k" (@(Test-EoRuleFacts $n $f $spec | Where-Object { $_.StartsWith("${n}: $k ") }).Count -gt 0) $true
    }
}
# The same rules as the firewall cmdlets report them.
$hostIf = $EO.HostIf
$realTcp = @{ Present = $true; PrimaryStatus = 'OK'; Enabled = 'True'; Action = 'Block'; Direction = 'Outbound'; Profile = 'Any'; Protocol = 'TCP'
    LocalPort = @('Any'); RemotePort = @('23-65535', '1-21'); IcmpType = @('Any'); RemoteAddress = @('Any'); LocalAddress = @('Any')
    InterfaceAlias = @($hostIf); InterfaceType = 'Any'; Program = 'Any'; Service = 'Any'
    Owner = ''; Platform = @(); EdgeTraversalPolicy = 'Block'; LooseSourceMapping = 'False'; LocalOnlyMapping = 'False'; DynamicTarget = 'Any'; Package = ''
    Authentication = 'NotRequired'; Encryption = 'NotRequired'; OverrideBlockRules = 'False'; LocalUser = 'Any'; RemoteUser = 'Any'; RemoteMachine = 'Any'
    Group = 'eo-l2'; RemoteDynamicKeywordAddresses = @() }
$tcpSpec = $specs.Guard['eo-l2-out-block-tcp']
Expect 'rules: TCP guard as reported passes (port order ignored)' (@(Test-EoRuleFacts 'tcp' $realTcp $tcpSpec -Active).Count) 0
$variants = [ordered]@{
    'remote port 22 also blocked'    = @{ RemotePort = @('1-65535') }
    'port 23-65535 range dropped'    = @{ RemotePort = @('1-21') }
    'SSH port opened to all'         = @{ RemotePort = @('Any') }
    'protocol changed to UDP'        = @{ Protocol = 'UDP' }
    'scoped to another interface'    = @{ InterfaceAlias = @('Ethernet') }
    'scoped to every interface'      = @{ InterfaceAlias = @('Any') }
    'an extra interface'             = @{ InterfaceAlias = @($hostIf, 'Wi-Fi') }
    'only one remote address'        = @{ RemoteAddress = @('192.168.250.2') }
    'only one local port'            = @{ LocalPort = @('49152-65535') }
    'limited to one program'         = @{ Program = 'C:\Windows\System32\svchost.exe' }
    'limited to one service'         = @{ Service = 'Dnscache' }
    'limited to wireless'            = @{ InterfaceType = 'Wireless' }
    'disabled'                       = @{ Enabled = 'False' }
    'turned into an allow rule'      = @{ Action = 'Allow' }
    'made inbound'                   = @{ Direction = 'Inbound' }
    'only the Public profile'        = @{ Profile = 'Public' }
    'limited to an app container'    = @{ Package = 'S-1-15-2-1430448594-2639229838-973813799-439329657-1197984847-4069523365-2491785580' }
    'owned by one user'              = @{ Owner = 'S-1-5-21-1-2-3-1001' }
    'limited to one Windows version' = @{ Platform = @('10.0') }
    'limited to a dynamic target'    = @{ DynamicTarget = 'ProximityApps' }
    'limited to one local user'      = @{ LocalUser = 'O:LSD:(A;;CC;;;S-1-5-21-1-2-3-1001)' }
    'limited to one remote user'     = @{ RemoteUser = 'O:LSD:(A;;CC;;;S-1-5-21-1-2-3-1002)' }
    'limited to one remote machine'  = @{ RemoteMachine = 'O:LSD:(A;;CC;;;S-1-5-21-1-2-3-1003)' }
    'only for authenticated traffic' = @{ Authentication = 'Required' }
    'only for encrypted traffic'     = @{ Encryption = 'Required' }
    'overridable by IPsec'           = @{ OverrideBlockRules = 'True' }
    'a filter that was not read'     = @{ Package = $null }
    'keyword address not read'       = @{ RemoteDynamicKeywordAddresses = $null }
    'limited to a keyword address'   = @{ RemoteDynamicKeywordAddresses = @('{8b9c1f4e-0000-4000-8000-000000000001}') }
    'moved to another group'         = @{ Group = 'other' }
}
foreach ($v in $variants.Keys) {
    $f = $realTcp.Clone(); foreach ($k in $variants[$v].Keys) { if ($null -eq $variants[$v][$k]) { $f.Remove($k) } else { $f[$k] = $variants[$v][$k] } }
    $msgs = @(Test-EoRuleFacts 'tcp' $f $tcpSpec)
    foreach ($k in $variants[$v].Keys) {
        Expect "rules: TCP guard $v fails for $k" (@($msgs | Where-Object { $_.StartsWith("tcp: $k ") }).Count -gt 0) $true
    }
}
$icmpSpec = $specs.Guard['eo-l2-out-block-icmp']
$realIcmp = $realTcp.Clone(); $realIcmp.Protocol = 'ICMPv4'; $realIcmp.RemotePort = @('Any')
Expect 'rules: ICMP guard as reported passes' (@(Test-EoRuleFacts 'icmp' $realIcmp $icmpSpec -Active).Count) 0
$f = $realIcmp.Clone(); $f.IcmpType = @('8')
Expect 'rules: ICMP guard limited to echo requests fails' (@(Test-EoRuleFacts 'icmp' $f $icmpSpec).Count -gt 0) $true
$f = $realIcmp.Clone(); $f.Protocol = 'ICMPv6'
Expect 'rules: ICMP guard on ICMPv6 instead fails' (@(Test-EoRuleFacts 'icmp' $f $icmpSpec).Count -gt 0) $true
$udpSpec = $specs.Guard['eo-l2-out-block-udp']
$realUdp = $realTcp.Clone(); $realUdp.Protocol = 'UDP'; $realUdp.RemotePort = @('Any')
Expect 'rules: UDP guard as reported passes' (@(Test-EoRuleFacts 'udp' $realUdp $udpSpec -Active).Count) 0
$f = $realUdp.Clone(); $f.RemotePort = @('5353', '5355', '137')
Expect 'rules: UDP guard limited to name-query ports fails' (@(Test-EoRuleFacts 'udp' $f $udpSpec).Count -gt 0) $true
$subSpec = $specs.Inbound['eo-l2-block-guest-subnet']
$realSub = $realTcp.Clone(); $realSub.Direction = 'Inbound'; $realSub.Protocol = 'Any'; $realSub.RemotePort = @('Any'); $realSub.InterfaceAlias = @('Any'); $realSub.RemoteAddress = @('192.168.250.0/255.255.255.248')
Expect 'rules: guest-subnet rule in mask form passes' (@(Test-EoRuleFacts 'sub' $realSub $subSpec -Active).Count) 0
$f = $realSub.Clone(); $f.RemoteAddress = @('192.168.250.0/255.255.255.0')
Expect 'rules: guest-subnet rule widened to /24 fails' (@(Test-EoRuleFacts 'sub' $f $subSpec).Count -gt 0) $true

# --- firewall profiles: on, blocking inbound, applying local rules, not exempting eo-l2-int ---
function Prof([string]$Name, [hashtable]$Over) {
    $f = @{ Name = $Name; Enabled = 'True'; DefaultInboundAction = 'NotConfigured'; AllowLocalFirewallRules = 'NotConfigured'; DisabledInterfaceAliases = @('NotConfigured') }
    foreach ($k in $Over.Keys) { if ($null -eq $Over[$k]) { $f.Remove($k) } else { $f[$k] = $Over[$k] } }
    return $f
}
function Profs([hashtable]$PublicOver) { @((Prof 'Domain' @{}), (Prof 'Private' @{}), (Prof 'Public' $PublicOver)) }
Expect 'profiles: defaults pass' (@(Test-EoProfileFacts (Profs @{})).Count) 0
Expect 'profiles: another interface exempt passes' (@(Test-EoProfileFacts (Profs @{ DisabledInterfaceAliases = @('Ethernet 2') })).Count) 0
$badProf = [ordered]@{
    'eo-l2-int exempt'               = @(@{ DisabledInterfaceAliases = @($EO.HostIf) }, 'DisabledInterfaceAliases exempts')
    'eo-l2-int exempt (other case)'  = @(@{ DisabledInterfaceAliases = @('Ethernet', $EO.HostIf.ToUpperInvariant()) }, 'DisabledInterfaceAliases exempts')
    'every interface exempt'         = @(@{ DisabledInterfaceAliases = @('Any') }, 'DisabledInterfaceAliases exempts')
    'exemptions not read'            = @(@{ DisabledInterfaceAliases = $null }, 'DisabledInterfaceAliases was not read')
    'profile off'                    = @(@{ Enabled = 'False' }, 'Enabled is')
    'inbound allowed by default'     = @(@{ DefaultInboundAction = 'Allow' }, 'DefaultInboundAction is')
    'local rules ignored'            = @(@{ AllowLocalFirewallRules = 'False' }, 'AllowLocalFirewallRules is False')
}
foreach ($k in $badProf.Keys) {
    $msgs = @(Test-EoProfileFacts (Profs $badProf[$k][0]))
    Expect "profiles: $k fails for its own reason" (@($msgs | Where-Object { $_.StartsWith('profile Public: ') -and $_.Contains($badProf[$k][1]) }).Count -gt 0) $true
}
Expect 'profiles: only two profiles read fails' (@(Test-EoProfileFacts @((Prof 'Domain' @{}), (Prof 'Private' @{})) | Where-Object { $_.Contains('want 3') }).Count -gt 0) $true

# --- host guard record folder and file: Administrators and SYSTEM only, no link ---
$userSid = 'S-1-5-21-1-2-3-1001'
function Acl([bool]$Container, [hashtable]$Over) {
    $f = @{ Path = 'X'; Reparse = $false; Container = $Container; Owner = 'S-1-5-32-544'; Protected = $Container; Allow = @('S-1-5-32-544', 'S-1-5-18') }
    foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
    return $f
}
Expect 'acl: protected folder passes' (@(Test-EoAclFacts (Acl $true @{}) -Container).Count) 0
Expect 'acl: folder owned by SYSTEM passes' (@(Test-EoAclFacts (Acl $true @{ Owner = 'S-1-5-18' }) -Container).Count) 0
Expect 'acl: file inheriting from it passes' (@(Test-EoAclFacts (Acl $false @{})).Count) 0
$badAcl = [ordered]@{
    'folder is a junction'           = @($true, @{ Reparse = $true }, 'is a link')
    'file is a symbolic link'        = @($false, @{ Reparse = $true }, 'is a link')
    'folder owned by a user'         = @($true, @{ Owner = $userSid }, 'is owned by')
    'file owned by a user'           = @($false, @{ Owner = $userSid }, 'is owned by')
    'folder inherits from ProgramData' = @($true, @{ Protected = $false }, 'inherits permissions')
    'folder grants Users'            = @($true, @{ Allow = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-32-545') }, 'grants access to S-1-5-32-545')
    'folder grants CREATOR OWNER'    = @($true, @{ Allow = @('S-1-5-32-544', 'S-1-3-0') }, 'grants access to S-1-3-0')
    'file grants a user'             = @($false, @{ Allow = @('S-1-5-18', $userSid) }, "grants access to $userSid")
    'a file where the folder should be' = @($true, @{ Container = $false; Protected = $true }, 'is a file, want a folder')
    'a folder where the file should be' = @($false, @{ Container = $true }, 'is a folder, want a file')
    'folder with a null ACL'         = @($true, @{ Allow = @() }, 'has no access entries')
}
foreach ($k in $badAcl.Keys) {
    $c = $badAcl[$k][0]
    $msgs = @(Test-EoAclFacts (Acl $c $badAcl[$k][1]) -Container:$c)
    Expect "acl: $k fails for its own reason" (@($msgs | Where-Object { $_.Contains($badAcl[$k][2]) }).Count -gt 0) $true
}

# --- host guard state: the undo restores only from a matching record -------------
$guid = '{6c1d5d6a-0000-4000-8000-00000000abcd}'
$goodJson = @"
{ "schema": "eo-l2-host-guard/1", "instanceId": "0123456789abcdef0123456789abcdef", "createdAt": "2026-10-29T20:00:00Z",
  "computer": "$env:COMPUTERNAME", "switchId": "11111111-2222-3333-4444-555555555555",
  "adapter": { "name": "vEthernet (eo-l2-int)", "interfaceGuid": "$guid", "macAddress": "00-15-5D-AA-BB-CC", "settingId": "$guid" },
  "netbiosBefore": 0, "rules": ["eo-l2-out-block-tcp", "eo-l2-out-block-udp", "eo-l2-out-block-icmp"] }
"@
$tag = Get-EoGuardInstanceTag '0123456789abcdef0123456789abcdef'
function Cur([hashtable]$Over) {
    $c = @{ Computer = $env:COMPUTERNAME; SwitchId = '11111111-2222-3333-4444-555555555555'
        Adapter = @{ InterfaceGuid = $guid; MacAddress = '00-15-5D-AA-BB-CC'; SettingId = $guid }
        RuleDescriptions = @{ 'eo-l2-out-block-tcp' = $tag; 'eo-l2-out-block-udp' = $tag; 'eo-l2-out-block-icmp' = $tag } }
    foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }
    return $c
}
function StateWith([string]$Find, [string]$Replace) { ($goodJson.Replace($Find, $Replace)) | ConvertFrom-Json }
Expect 'guard state: matching record passes' (@(Test-EoGuardState ($goodJson | ConvertFrom-Json) (Cur @{})).Count) 0
foreach ($nb in 1, 2) { Expect "guard state: netbiosBefore $nb passes" (@(Test-EoGuardState (StateWith '"netbiosBefore": 0' """netbiosBefore"": $nb") (Cur @{})).Count) 0 }
Expect 'guard state: switch and adapter already gone passes (nothing to restore)' (@(Test-EoGuardState ($goodJson | ConvertFrom-Json) (Cur @{ SwitchId = $null; Adapter = $null; RuleDescriptions = @{} })).Count) 0
$bad = [ordered]@{
    'no record'                            = @($null, (Cur @{}), 'no host guard state record')
    'record without netbiosBefore'         = @((StateWith '"netbiosBefore": 0, ' ''), (Cur @{}), "no 'netbiosBefore'")
    'netbiosBefore as a string'            = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": "0"'), (Cur @{}), 'netbiosBefore')
    'netbiosBefore null'                   = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": null'), (Cur @{}), 'netbiosBefore')
    'netbiosBefore 3'                      = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": 3'), (Cur @{}), 'netbiosBefore')
    'netbiosBefore -1'                     = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": -1'), (Cur @{}), 'netbiosBefore')
    'netbiosBefore 1.5'                    = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": 1.5'), (Cur @{}), 'netbiosBefore')
    'netbiosBefore as a list'              = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": [0, 2]'), (Cur @{}), 'netbiosBefore')
    'another schema'                       = @((StateWith 'eo-l2-host-guard/1' 'eo-l2-host-guard/0'), (Cur @{}), 'schema is')
    'schema as a list'                     = @((StateWith '"schema": "eo-l2-host-guard/1"' '"schema": ["eo-l2-host-guard/1"]'), (Cur @{}), 'schema is not a single string')
    'computer as a list'                   = @((StateWith """computer"": ""$env:COMPUTERNAME""" """computer"": [""$env:COMPUTERNAME""]"), (Cur @{}), 'computer is not a single string')
    'malformed instance id'                = @((StateWith '"instanceId": "0123456789abcdef0123456789abcdef"' '"instanceId": "not-an-id"'), (Cur @{ RuleDescriptions = @{} }), 'instanceId')
    'upper-case instance id'               = @((StateWith '"instanceId": "0123456789abcdef0123456789abcdef"' '"instanceId": "0123456789ABCDEF0123456789ABCDEF"'), (Cur @{ RuleDescriptions = @{} }), 'instanceId')
    'other rule list'                      = @((StateWith '"eo-l2-out-block-icmp"]' '"eo-l2-out-block-icmpv6"]'), (Cur @{}), 'rules are')
    'another computer'                     = @((StateWith """computer"": ""$env:COMPUTERNAME""" '"computer": "OTHER-PC"'), (Cur @{}), 'is for computer')
    'another provisioning (switch id)'     = @(($goodJson | ConvertFrom-Json), (Cur @{ SwitchId = '99999999-2222-3333-4444-555555555555' }), 'another provisioning instance')
    'another adapter (GUID)'               = @(($goodJson | ConvertFrom-Json), (Cur @{ Adapter = @{ InterfaceGuid = '{00000000-0000-4000-8000-000000000001}'; MacAddress = '00-15-5D-AA-BB-CC'; SettingId = $guid } }), 'adapter InterfaceGuid')
    'another adapter (MAC)'                = @(($goodJson | ConvertFrom-Json), (Cur @{ Adapter = @{ InterfaceGuid = $guid; MacAddress = '00-15-5D-00-00-01'; SettingId = $guid } }), 'adapter MacAddress')
    'another adapter (setting id)'         = @(($goodJson | ConvertFrom-Json), (Cur @{ Adapter = @{ InterfaceGuid = $guid; MacAddress = '00-15-5D-AA-BB-CC'; SettingId = '{00000000-0000-4000-8000-000000000002}' } }), 'adapter SettingId')
    'record without the adapter GUID'      = @((StateWith """interfaceGuid"": ""$guid"", " ''), (Cur @{}), 'adapter has no interfaceGuid')
    'switch present, adapter missing'      = @(($goodJson | ConvertFrom-Json), (Cur @{ Adapter = $null }), 'cannot tell which adapter')
    'rule from another instance'           = @(($goodJson | ConvertFrom-Json), (Cur @{ RuleDescriptions = @{ 'eo-l2-out-block-tcp' = (Get-EoGuardInstanceTag 'ffffffffffffffffffffffffffffffff') } }), 'belongs to another instance')
    'rule with no instance tag'            = @(($goodJson | ConvertFrom-Json), (Cur @{ RuleDescriptions = @{ 'eo-l2-out-block-udp' = '' } }), 'belongs to another instance')
}
foreach ($k in $bad.Keys) {
    $threw = $false; $msgs = @()
    try { $msgs = @(Test-EoGuardState $bad[$k][0] $bad[$k][1]) } catch { $threw = $true; $msgs = @("threw: $($_.Exception.Message)") }
    $hit = @($msgs | Where-Object { $_.Contains($bad[$k][2]) })
    Expect "guard state: $k refused for its own reason" ($hit.Count -gt 0 -and -not $threw) $true
    if (-not $hit.Count) { $msgs | ForEach-Object { Write-Host "     $_" } }
}

# --- host snapshot: a host (management OS) adapter whose VMName throws -----------
# On RH-DT-M3, Get-VMNetworkAdapter -All returns host vNICs whose VMName getter
# throws "Object reference not set" when Sort-Object reads it (Windows PowerShell
# 5.1). The CI runner has no Hyper-V, so the cmdlets Get-EoSnapshot calls are
# replaced by functions returning such an adapter.
& {
    function New-FakeAdapter([bool]$Host_, [string]$Vm, [string]$Name, [string]$Mac) {
        $o = [pscustomobject]@{ Name = $Name; SwitchName = 'Default Switch'; MacAddress = $Mac; IsManagementOs = $Host_ }
        if ($Host_) { $o | Add-Member -MemberType ScriptProperty -Name VMName -Value { throw [NullReferenceException]::new('Object reference not set to an instance of an object.') } }
        else { $o | Add-Member -MemberType NoteProperty -Name VMName -Value $Vm }
        return $o
    }
    $adapters = @((New-FakeAdapter $false 'other-vm' 'Network Adapter' '00155D000001'), (New-FakeAdapter $true '' 'Host Vnic 790E58B4' '00155D000002'))
    function Get-VMNetworkAdapter { $adapters }
    function Get-VMSwitch { }
    function Get-VM { }
    function Get-NetAdapter { }
    function Get-NetIPAddress { }
    function Get-NetRoute { }
    function Get-NetIPInterface { }
    function Get-NetNat { }
    function Get-NetFirewallRule { }
    function Get-Service { }
    function Get-VMHost { [pscustomobject]@{ EnableEnhancedSessionMode = $true; VirtualHardDiskPath = 'C:\vhd'; VirtualMachinePath = 'C:\vm' } }

    $oldThrew = $false
    try { $null = @(Get-VMNetworkAdapter -All | Sort-Object VMName, Name) } catch { $oldThrew = $_.Exception.Message -match 'VMName' }
    if ($PSVersionTable.PSEdition -eq 'Desktop') { Expect 'snapshot: the old sort by VMName fails on a host adapter (5.1, the RH-DT-M3 failure)' $oldThrew $true }
    else { Write-Host "info the old sort by VMName on a host adapter threw under PowerShell 7: $oldThrew" }
    $snap = $null; $err = ''
    try { $snap = Get-EoSnapshot } catch { $err = $_.Exception.Message }
    Expect 'snapshot: Get-EoSnapshot succeeds with a host adapter present' $err ''
    Expect 'snapshot: Get-EoSnapshot returned a snapshot' ($null -ne $snap) $true
    if ($snap) {
        Expect 'snapshot: host adapter recorded as (host)' (@($snap.vmAdapters | Where-Object { $_.vm -eq '(host)' -and $_.mac -eq '00155D000002' -and $_.managementOs }).Count) 1
        Expect 'snapshot: VM adapter keeps its VM name' (@($snap.vmAdapters | Where-Object { $_.vm -eq 'other-vm' -and $_.mac -eq '00155D000001' }).Count) 1
        Expect 'snapshot: serializes to JSON' ([bool]($snap | ConvertTo-Json -Depth 6)) $true
    }
}

if ($failures.Count) { Write-Host "$($failures.Count) failure(s)"; exit 1 }
Write-Host 'all host-script self-tests passed'
exit 0
