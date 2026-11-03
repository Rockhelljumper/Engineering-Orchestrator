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
    # Real host layout (2026-11-02): each switch has a hidden 'vSwitch (<switch>)'
    # adapter whose ms_ndiscap binding is its NDIS Capture extension.
    $vsEo = $true; $vsDefault = $true
    function Get-NetAdapterBinding { [CmdletBinding()] param($Name, [switch]$AllBindings, [switch]$IncludeHidden)
        $all = @([pscustomobject]@{ Name = $EO.HostIf; ComponentID = 'ms_tcpip'; Enabled = $true }, [pscustomobject]@{ Name = $EO.HostIf; ComponentID = 'INSECURE_NPCAP'; Enabled = $false },
            [pscustomobject]@{ Name = 'Ethernet'; ComponentID = 'INSECURE_NPCAP'; Enabled = $true },
            [pscustomobject]@{ Name = 'vSwitch (eo-l2-int)'; ComponentID = 'ms_ndiscap'; Enabled = $vsEo }, [pscustomobject]@{ Name = 'vSwitch (eo-l2-int)'; ComponentID = 'vms_vsf'; Enabled = $true },
            [pscustomobject]@{ Name = 'vSwitch (Default Switch)'; ComponentID = 'ms_ndiscap'; Enabled = $vsDefault }, [pscustomobject]@{ Name = 'vSwitch (WSL)'; ComponentID = 'ms_winvfp'; Enabled = $true })
        if ($Name) { $all | Where-Object Name -eq $Name } else { $all } }
    function Get-VMSwitchExtension { [CmdletBinding()] param($VMSwitchName) @([pscustomobject]@{ Name = 'Microsoft NDIS Capture'; Enabled = $true }, [pscustomobject]@{ Name = 'Microsoft Windows Filtering Platform'; Enabled = $false }) }
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
        Expect 'snapshot: eo-l2-int bindings listed in full' ($snap.eoBindings -join ',') 'INSECURE_NPCAP|False,ms_tcpip|True'
        Expect 'snapshot: eo-l2-int switch extensions listed' ($snap.eoSwitchExtensions -join ',') 'Microsoft NDIS Capture|True,Microsoft Windows Filtering Platform|False'
        Expect 'snapshot: other switches extension digest present' "$($snap.otherSwitchExtensions.count)/$($snap.otherSwitchExtensions.sha256.Length)" '0/64'
        Expect 'snapshot: other adapters digested, the Default Switch and WSL switch adapters included' "$($snap.otherBindings.count)/$($snap.otherBindings.sha256.Length)" '3/64'
        Expect 'snapshot: the eo-l2-int switch adapter listed in full' ($snap.eoSwitchAdapterBindings -join ',') 'ms_ndiscap|True,vms_vsf|True'
        # 01c's own change (NDIS Capture off on eo-l2-int) must leave the digest as it was;
        # the same change on the Default Switch must not.
        $vsEo = $false; $s2 = Get-EoSnapshot
        Expect 'snapshot: NDIS Capture off on eo-l2-int keeps the other-adapter digest' "$($s2.otherBindings.sha256)" "$($snap.otherBindings.sha256)"
        Expect 'snapshot: NDIS Capture off on eo-l2-int shows in the switch adapter list' ($s2.eoSwitchAdapterBindings -join ',') 'ms_ndiscap|False,vms_vsf|True'
        $vsDefault = $false; $s3 = Get-EoSnapshot
        Expect 'snapshot: NDIS Capture off on the Default Switch changes the other-adapter digest' ("$($s3.otherBindings.sha256)" -ne "$($s2.otherBindings.sha256)") $true

    }
}

# On RH-DT-M3, step 01b's verify-host.ps1 crashed on "$sp.Count": the old line
# wrapped only the branches of an if statement in @(), the if output was unrolled,
# and .Count on $null (0 problems) or a bare string (1 problem) throws under
# StrictMode in Windows PowerShell 5.1. This runs the shipped assignment, taken
# from verify-host.ps1 by the parser, for 0, 1 and 3 problems and for the
# unreadable-record branch.
& {
    $vtokens = $null; $verrors = $null
    $vast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir 'verify-host.ps1'), [ref]$vtokens, [ref]$verrors)
    $assigns = @($vast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -eq '$sp' }, $true))
    Expect 'guard problems: verify-host.ps1 assigns $sp exactly once' $assigns.Count 1
    $shipped = "$($assigns[0].Extent.Text)"
    $old = '$sp = if ($gerr) { @("state record unreadable: $gerr") } else { @(Test-EoGuardState $gstate $gcur) }'
    function Invoke-SpAssignment([string]$Text, [int]$N, $GErr) {
        & {
            Set-StrictMode -Version 3.0
            $ErrorActionPreference = 'Stop'
            function Test-EoGuardState($State, $Current) {
                $p = New-Object System.Collections.Generic.List[string]
                for ($i = 1; $i -le $N; $i++) { $p.Add("problem $i") }
                return $p
            }
            $gerr = $GErr; $gstate = $null; $gcur = $null
            . ([scriptblock]::Create($Text))
            "$($sp.Count)|$($sp -join '; ')"
        }
    }
    foreach ($case in @(@(0, $null, '0|'), @(1, $null, '1|problem 1'), @(3, $null, '3|problem 1; problem 2; problem 3'), @(0, 'bad json', '1|state record unreadable: bad json'))) {
        $got = ''
        try { $got = Invoke-SpAssignment $shipped $case[0] $case[1] } catch { $got = "threw: $($_.Exception.Message)" }
        Expect "guard problems: shipped line, $($case[0]) problem(s), record error '$($case[1])'" $got $case[2]
    }
    foreach ($n in 0, 1) {
        $oldThrew = $false
        try { $null = Invoke-SpAssignment $old $n $null } catch { $oldThrew = $true }
        if ($PSVersionTable.PSEdition -eq 'Desktop') { Expect "guard problems: the old line throws with $n problem(s) (5.1, the RH-DT-M3 failure)" $oldThrew $true }
        else { Write-Host "info the old line with $n problem(s) threw under PowerShell 7: $oldThrew" }
    }
}

# The same 5.1 StrictMode unrolling in undo-01b-host-guard.ps1: Get-GuardRules
# returns 0, 1 or 3 rules, and each shipped use of it, taken from the script by
# the parser, must give a count without throwing. The rule check after the
# restore runs on every successful undo, when 0 rules remain.
& {
    $utokens = $null; $uerrors = $null
    $uast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir 'undo-01b-host-guard.ps1'), [ref]$utokens, [ref]$uerrors)
    $fn = @($uast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GuardRules' }, $true))
    $assigns = @($uast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -eq '$rules' }, $true))
    $conds = @($uast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) | ForEach-Object { $_.Clauses } | ForEach-Object { $_.Item1 } | Where-Object { "$_" -match 'Get-GuardRules' })
    $calls = @($uast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-GuardRules' }, $true))
    Expect 'undo rules: Get-GuardRules defined once' $fn.Count 1
    Expect 'undo rules: two $rules assignments and one rule check' "$($assigns.Count)/$($conds.Count)" '2/1'
    Expect 'undo rules: every Get-GuardRules call sits in @()' (@($calls | Where-Object { -not ($_.Parent.Parent.Parent -is [System.Management.Automation.Language.ArrayExpressionAst]) }).Count) 0
    function Invoke-UndoRules([string]$Text, [int]$N, [switch]$Condition) {
        & {
            Set-StrictMode -Version 3.0
            $ErrorActionPreference = 'Stop'
            # Serves the first $N guard rules asked for; the rest are missing.
            function Get-NetFirewallRule { [CmdletBinding()] param($PolicyStore, $Name) if ($script:served -lt $N) { $script:served++; [pscustomobject]@{ Name = $Name } } }
            $script:served = 0
            . ([scriptblock]::Create($fn[0].Extent.Text))
            if ($Condition) { [bool](. ([scriptblock]::Create($Text))) } else { . ([scriptblock]::Create($Text)); "$($rules.Count)" }
        }
    }
    foreach ($n in 0, 1, 3) {
        foreach ($a in $assigns) {
            $got = ''
            try { $got = Invoke-UndoRules $a.Extent.Text $n } catch { $got = "threw: $($_.Exception.Message)" }
            Expect "undo rules: '$($a.Extent.Text)' with $n rule(s)" $got "$n"
        }
        foreach ($c in $conds) {
            $got = ''
            try { $got = Invoke-UndoRules $c.Extent.Text $n -Condition } catch { $got = "threw: $($_.Exception.Message)" }
            Expect "undo rules: '$($c.Extent.Text)' with $n rule(s)" $got "$($n -gt 0)"
        }
    }
}


# --- filter guard (01c, B9-R1) ----------------------------------------------------
$npc = 'INSECURE_NPCAP'; $vbx = 'oracle_VBoxNetLwf'; $ppp = 'ms_pppoe'; $uio = 'ms_ndisuio'
Expect 'filter targets: exactly the four approved component IDs, in order' ($EO.FilterTargets -join ',') "$npc,$vbx,$ppp,$uio"
function PlanText($Plan) { (@($Plan) | ForEach-Object { "$($_.ComponentId)=$($_.Action)/$($_.EnabledBefore)" }) -join ',' }
# Under StrictMode, for 0, 1, 2 and 4 enabled targets (the lesson of D-2), including
# the hidden-only targets ms_pppoe and ms_ndisuio and the real host state of
# 2026-11-02 (all four enabled).
& {
    Set-StrictMode -Version 3.0
    foreach ($c in @(
            @(@{}, "$npc=absent/False,$vbx=absent/False,$ppp=absent/False,$uio=absent/False", 0),
            @(@{ $npc = $false; $vbx = $false; $ppp = $false; $uio = $false }, "$npc=already-off/False,$vbx=already-off/False,$ppp=already-off/False,$uio=already-off/False", 0),
            @(@{ $npc = $true; $vbx = $false; 'ms_tcpip' = $true }, "$npc=disable/True,$vbx=already-off/False,$ppp=absent/False,$uio=absent/False", 1),
            @(@{ $vbx = $true }, "$npc=absent/False,$vbx=disable/True,$ppp=absent/False,$uio=absent/False", 1),
            @(@{ $ppp = $true; 'ms_tcpip' = $true }, "$npc=absent/False,$vbx=absent/False,$ppp=disable/True,$uio=absent/False", 1),
            @(@{ $uio = $true; $ppp = $false }, "$npc=absent/False,$vbx=absent/False,$ppp=already-off/False,$uio=disable/True", 1),
            @(@{ $npc = $true; $vbx = $true }, "$npc=disable/True,$vbx=disable/True,$ppp=absent/False,$uio=absent/False", 2),
            @(@{ $npc = $true; $vbx = $true; $ppp = $true; $uio = $true; 'ms_tcpip' = $true; 'ms_wfplwf_lower' = $true }, "$npc=disable/True,$vbx=disable/True,$ppp=disable/True,$uio=disable/True", 4))) {
        $got = ''; $n = -1
        try { $plan = @(Get-EoFilterApplyPlan $c[0]); $got = PlanText $plan; $n = @($plan | Where-Object Action -eq 'disable').Count } catch { $got = "threw: $($_.Exception.Message)" }
        Expect "filter plan: $($c[1])" $got $c[1]
        Expect "filter plan: $($c[1]) counts $($c[2]) to disable under StrictMode" $n $c[2]
    }
}
$fguid = '{94ebb62f-0000-4000-8000-00000000abcd}'
$fGuardId = '0123456789abcdef0123456789abcdef'
$fJson = @"
{ "schema": "eo-l2-filter-guard/3", "instanceId": "fedcba9876543210fedcba9876543210", "createdAt": "2026-11-02T00:00:00Z",
  "computer": "$env:COMPUTERNAME", "switchId": "11111111-2222-3333-4444-555555555555",
  "adapter": { "name": "vEthernet (eo-l2-int)", "interfaceGuid": "$fguid", "macAddress": "00-15-5D-0A-1C-02", "settingId": "$fguid" },
  "hostGuardInstanceId": "$fGuardId",
  "bindings": [ { "componentId": "INSECURE_NPCAP", "displayName": "Npcap Packet Driver (NPCAP)", "present": true, "enabledBefore": true }, { "componentId": "oracle_VBoxNetLwf", "displayName": "VirtualBox NDIS6 Bridged Networking Driver", "present": true, "enabledBefore": false }, { "componentId": "ms_pppoe", "displayName": "Point to Point Protocol Over Ethernet", "present": true, "enabledBefore": false }, { "componentId": "ms_ndisuio", "displayName": "NDIS Usermode I/O Protocol", "present": true, "enabledBefore": false } ],
  "switchExtensions": [ { "name": "Microsoft NDIS Capture", "present": true, "enabledBefore": true } ],
  "drivers": { "npcap.sys": "1.75", "VBoxNetLwf.sys": "7.2.4" } }
"@
function FCur([hashtable]$Over) {
    $c = @{ Computer = $env:COMPUTERNAME; SwitchId = '11111111-2222-3333-4444-555555555555'
        Adapter = @{ InterfaceGuid = $fguid; MacAddress = '00-15-5D-0A-1C-02'; SettingId = $fguid }
        RuleDescriptions = @{}; Bindings = @{ $npc = $false; $vbx = $false; 'ms_tcpip' = $true }
        VisibleBindings = @{ $npc = $false; $vbx = $false; 'ms_tcpip' = $true; 'ms_pacer' = $true; 'ms_l2bridge' = $true; 'ms_l1vhlwf' = $true }
        Extensions = @(@{ Name = 'Microsoft Windows Filtering Platform'; Vendor = 'Microsoft'; Enabled = 'False' }, @{ Name = 'Microsoft NDIS Capture'; Vendor = 'Microsoft'; Enabled = 'False' })
        ExtensionStates = @{ 'Microsoft Windows Filtering Platform' = $false; 'Microsoft NDIS Capture' = $false } }
    foreach ($k in $Over.Keys) { $c[$k] = $Over[$k] }
    return $c
}
function FState([string]$Find, [string]$Replace) { ($fJson.Replace($Find, $Replace)) | ConvertFrom-Json }
Expect 'filter record: matching record passes' (@(Test-EoFilterState ($fJson | ConvertFrom-Json) (FCur @{}) $fGuardId).Count) 0
Expect 'filter record: switch and adapter gone passes (nothing to restore)' (@(Test-EoFilterState ($fJson | ConvertFrom-Json) (FCur @{ SwitchId = $null; Adapter = $null }) $null).Count) 0
$fbad = [ordered]@{
    'no record'                        = @($null, (FCur @{}), $fGuardId, 'no filter guard record')
    'no bindings'                      = @((FState '"bindings":' '"bindingz":'), (FCur @{}), $fGuardId, "no 'bindings'")
    'another schema'                   = @((FState 'eo-l2-filter-guard/3' 'eo-l2-filter-guard/1'), (FCur @{}), $fGuardId, 'schema is')
    'the /2 schema (two targets)'      = @((FState 'eo-l2-filter-guard/3' 'eo-l2-filter-guard/2'), (FCur @{}), $fGuardId, 'schema is')
    'a new target left out'            = @((FState ', { "componentId": "ms_ndisuio", "displayName": "NDIS Usermode I/O Protocol", "present": true, "enabledBefore": false }' ''), (FCur @{}), $fGuardId, 'components are')
    'a new target in another case'     = @((FState '"componentId": "ms_pppoe"' '"componentId": "MS_PPPOE"'), (FCur @{}), $fGuardId, 'components are')
    'schema as a list'                 = @((FState '"schema": "eo-l2-filter-guard/3"' '"schema": ["eo-l2-filter-guard/3"]'), (FCur @{}), $fGuardId, 'schema is not a single string')
    'malformed instance id'            = @((FState 'fedcba9876543210fedcba9876543210' 'fedcba98'), (FCur @{}), $fGuardId, 'instanceId')
    'malformed host guard id'          = @((FState """hostGuardInstanceId"": ""$fGuardId""" '"hostGuardInstanceId": "X"'), (FCur @{}), 'X', 'hostGuardInstanceId')
    'host guard id as a number'        = @((FState """hostGuardInstanceId"": ""$fGuardId""" '"hostGuardInstanceId": 5'), (FCur @{}), $fGuardId, 'hostGuardInstanceId is not a single string')
    'another host guard instance'      = @(($fJson | ConvertFrom-Json), (FCur @{}), 'ffffffffffffffffffffffffffffffff', 'builds on host guard instance')
    'no host guard record now'         = @(($fJson | ConvertFrom-Json), (FCur @{}), $null, 'builds on host guard instance')
    'a component that is not a target' = @((FState '"componentId": "oracle_VBoxNetLwf"' '"componentId": "ms_tcpip"'), (FCur @{}), $fGuardId, 'components are')
    'a target recorded twice'          = @((FState '"componentId": "oracle_VBoxNetLwf"' '"componentId": "INSECURE_NPCAP"'), (FCur @{}), $fGuardId, 'components are')
    'a target in another case'         = @((FState '"componentId": "INSECURE_NPCAP"' '"componentId": "insecure_npcap"'), (FCur @{}), $fGuardId, 'components are')
    'one target left out'              = @((FState ', { "componentId": "oracle_VBoxNetLwf", "displayName": "VirtualBox NDIS6 Bridged Networking Driver", "present": true, "enabledBefore": false }' ''), (FCur @{}), $fGuardId, 'components are')
    'enabledBefore as a string'        = @((FState '"present": true, "enabledBefore": true' '"present": true, "enabledBefore": "true"'), (FCur @{}), $fGuardId, 'needs boolean')
    'present missing'                  = @((FState '"present": true, "enabledBefore": true' '"enabledBefore": true'), (FCur @{}), $fGuardId, 'needs boolean')
    'enabled before but not present'   = @((FState '"present": true, "enabledBefore": true' '"present": false, "enabledBefore": true'), (FCur @{}), $fGuardId, 'is enabledBefore but not present')
    'another computer'                 = @((FState """computer"": ""$env:COMPUTERNAME""" '"computer": "OTHER-PC"'), (FCur @{}), $fGuardId, 'is for computer')
    'another switch'                   = @(($fJson | ConvertFrom-Json), (FCur @{ SwitchId = '99999999-2222-3333-4444-555555555555' }), $fGuardId, 'another provisioning instance')
    'another adapter (GUID)'           = @(($fJson | ConvertFrom-Json), (FCur @{ Adapter = @{ InterfaceGuid = '{00000000-0000-4000-8000-000000000001}'; MacAddress = '00-15-5D-0A-1C-02'; SettingId = $fguid } }), $fGuardId, 'adapter InterfaceGuid')
    'another adapter (MAC)'            = @(($fJson | ConvertFrom-Json), (FCur @{ Adapter = @{ InterfaceGuid = $fguid; MacAddress = '00-15-5D-00-00-01'; SettingId = $fguid } }), $fGuardId, 'adapter MacAddress')
    'another adapter (setting id)'     = @(($fJson | ConvertFrom-Json), (FCur @{ Adapter = @{ InterfaceGuid = $fguid; MacAddress = '00-15-5D-0A-1C-02'; SettingId = '{00000000-0000-4000-8000-000000000002}' } }), $fGuardId, 'adapter SettingId')
    'record without the adapter GUID'  = @((FState """interfaceGuid"": ""$fguid"", " ''), (FCur @{}), $fGuardId, 'adapter has no interfaceGuid')
    'switch present, adapter missing'  = @(($fJson | ConvertFrom-Json), (FCur @{ Adapter = $null }), $fGuardId, 'cannot tell which adapter')
    'extension name as a list'         = @((FState '"name": "Microsoft NDIS Capture"' '"name": ["Microsoft NDIS Capture"]'), (FCur @{}), $fGuardId, 'is not a single string')
    'no switchExtensions'              = @((FState '"switchExtensions":' '"switchExtensionz":'), (FCur @{}), $fGuardId, "no 'switchExtensions'")
    'another extension recorded'       = @((FState '"name": "Microsoft NDIS Capture"' '"name": "Microsoft Windows Filtering Platform"'), (FCur @{}), $fGuardId, 'switch extensions are')
    'no extension recorded'            = @((FState '"switchExtensions": [ { "name": "Microsoft NDIS Capture", "present": true, "enabledBefore": true } ]' '"switchExtensions": []'), (FCur @{}), $fGuardId, 'switch extensions are')
    'extension enabledBefore a string' = @((FState '"present": true, "enabledBefore": true } ]' '"present": true, "enabledBefore": "yes" } ]'), (FCur @{}), $fGuardId, 'needs boolean present and enabledBefore')
}
foreach ($k in $fbad.Keys) {
    $threw = $false; $msgs = @()
    try { $msgs = @(Test-EoFilterState $fbad[$k][0] $fbad[$k][1] $fbad[$k][2]) } catch { $threw = $true; $msgs = @("threw: $($_.Exception.Message)") }
    $hit = @($msgs | Where-Object { $_.Contains($fbad[$k][3]) })
    Expect "filter record: $k refused for its own reason" ($hit.Count -gt 0 -and -not $threw) $true
    if (-not $hit.Count) { $msgs | ForEach-Object { Write-Host "     $_" } }
}

# The undo's plan: only targets recorded as enabled are re-enabled, and it refuses on
# a target it cannot restore or one something else enabled.
$fRec = $fJson | ConvertFrom-Json
foreach ($c in @(
        @(@{ $npc = $false; $vbx = $false }, "$npc=enable/True,$vbx=leave-off/False,$ppp=leave-off/False,$uio=leave-off/False", 0),
        @(@{ $npc = $true; $vbx = $false }, "$npc=skip/True,$vbx=leave-off/False,$ppp=leave-off/False,$uio=leave-off/False", 0),
        @(@{ $vbx = $false }, "$npc=missing/True,$vbx=leave-off/False,$ppp=leave-off/False,$uio=leave-off/False", 1),
        @(@{ $npc = $false }, "$npc=enable/True,$vbx=leave-off/False,$ppp=leave-off/False,$uio=leave-off/False", 0),
        @(@{ $npc = $false; $vbx = $true }, "$npc=enable/True,$vbx=drifted/False,$ppp=leave-off/False,$uio=leave-off/False", 1))) {
    & {
        Set-StrictMode -Version 3.0
        $got = ''; $n = -1
        try { $plan = @(Get-EoFilterRestorePlan $fRec $c[0]); $got = PlanText $plan; $n = @(Test-EoFilterRestorePlan $plan).Count } catch { $got = "threw: $($_.Exception.Message)" }
        Expect "filter undo plan: $($c[1])" $got $c[1]
        Expect "filter undo plan: $($c[1]) gives $($c[2]) refusal(s)" $n $c[2]
    }
}
foreach ($c in @(
        @(@{ 'Microsoft NDIS Capture' = $false }, 'Microsoft NDIS Capture=enable/True', 0),
        @(@{ 'Microsoft NDIS Capture' = $true }, 'Microsoft NDIS Capture=skip/True', 0),
        @(@{}, 'Microsoft NDIS Capture=missing/True', 1))) {
    $got = ''; $n = -1
    try { $plan = @(Get-EoFilterRestorePlan $fRec $c[0] -Extensions); $got = PlanText $plan; $n = @(Test-EoFilterRestorePlan $plan).Count } catch { $got = "threw: $($_.Exception.Message)" }
    Expect "filter undo plan (extension): $($c[1])" $got $c[1]
    Expect "filter undo plan (extension): $($c[1]) gives $($c[2]) refusal(s)" $n $c[2]
}
$xoff = FState '"present": true, "enabledBefore": true } ]' '"present": true, "enabledBefore": false } ]'
Expect 'filter undo plan (extension): recorded off, enabled now is drift' (PlanText (Get-EoFilterRestorePlan $xoff @{ 'Microsoft NDIS Capture' = $true } -Extensions)) 'Microsoft NDIS Capture=drifted/False'
foreach ($c in @(
        @(@{ 'Microsoft NDIS Capture' = $true; 'Microsoft Windows Filtering Platform' = $false }, 'Microsoft NDIS Capture=disable/True'),
        @(@{ 'Microsoft NDIS Capture' = $false }, 'Microsoft NDIS Capture=already-off/False'),
        @(@{}, 'Microsoft NDIS Capture=absent/False'))) {
    Expect "filter plan (extension): $($c[1])" (PlanText (Get-EoFilterApplyPlan $c[0] $EO.SwitchExtTargets)) $c[1]
}
Expect 'filter extensions: NDIS Capture off passes' (@(Test-EoFilterExtensions @{ 'Microsoft NDIS Capture' = $false }).Count) 0
Expect 'filter extensions: NDIS Capture absent passes' (@(Test-EoFilterExtensions @{}).Count) 0
Expect 'filter extensions: NDIS Capture on fails' (@(Test-EoFilterExtensions @{ 'Microsoft NDIS Capture' = $true }) -join ';') "switch extension 'Microsoft NDIS Capture' is enabled on $($EO.SwitchName)"
$sabOn = @([pscustomobject]@{ ComponentID = 'ms_ndiscap'; Enabled = $true }, [pscustomobject]@{ ComponentID = 'vms_vsf'; Enabled = $true })
$sabOff = @([pscustomobject]@{ ComponentID = 'ms_ndiscap'; Enabled = $false }, [pscustomobject]@{ ComponentID = 'vms_vsf'; Enabled = $true })
Expect 'switch adapter: ms_ndiscap on with NDIS Capture on passes' (@(Test-EoSwitchAdapterBindings $sabOn @{ 'Microsoft NDIS Capture' = $true }).Count) 0
Expect 'switch adapter: ms_ndiscap off with NDIS Capture off passes' (@(Test-EoSwitchAdapterBindings $sabOff @{ 'Microsoft NDIS Capture' = $false }).Count) 0
Expect 'switch adapter: ms_ndiscap off with NDIS Capture on fails (wrong adapter)' (@(Test-EoSwitchAdapterBindings $sabOff @{ 'Microsoft NDIS Capture' = $true }).Count) 1
Expect 'switch adapter: ms_ndiscap on with NDIS Capture off fails' (@(Test-EoSwitchAdapterBindings $sabOn @{ 'Microsoft NDIS Capture' = $false }).Count) 1
Expect 'switch adapter: no bindings (adapter not found) fails' (@(Test-EoSwitchAdapterBindings @() @{ 'Microsoft NDIS Capture' = $true }) -join ';') "'$($EO.SwitchAdapter)' has 0 ms_ndiscap binding(s), want exactly 1 for the 'Microsoft NDIS Capture' extension"
Expect 'switch adapter: two ms_ndiscap bindings fail' (@(Test-EoSwitchAdapterBindings @($sabOn + $sabOn) @{ 'Microsoft NDIS Capture' = $true }).Count) 1
Expect 'switch adapter: a single binding object works under StrictMode' (@(Test-EoSwitchAdapterBindings $sabOn[0] @{ 'Microsoft NDIS Capture' = $true }).Count) 0
Expect 'switch adapter: extension not listed fails' (@(Test-EoSwitchAdapterBindings $sabOn @{}).Count) 1
Expect 'switch adapter: component matched case-exactly' (@(Test-EoSwitchAdapterBindings @([pscustomobject]@{ ComponentID = 'MS_NDISCAP'; Enabled = $true }) @{ 'Microsoft NDIS Capture' = $true }).Count) 1
$both = FState '"present": true, "enabledBefore": false' '"present": true, "enabledBefore": true'
Expect 'filter undo plan: all four recorded enabled, all off now' (PlanText (Get-EoFilterRestorePlan $both @{ $npc = $false; $vbx = $false; $ppp = $false; $uio = $false })) "$npc=enable/True,$vbx=enable/True,$ppp=enable/True,$uio=enable/True"
# The real host (all four enabled before 01c), under StrictMode: a full undo, a partial
# 01c or undo (some already as recorded), a removed component and a drift.
& {
    Set-StrictMode -Version 3.0
    foreach ($c in @(
            @(@{ $npc = $false; $vbx = $false; $ppp = $false; $uio = $false }, "$npc=enable/True,$vbx=enable/True,$ppp=enable/True,$uio=enable/True", 4, 0),
            @(@{ $npc = $false; $vbx = $true; $ppp = $true; $uio = $true }, "$npc=enable/True,$vbx=skip/True,$ppp=skip/True,$uio=skip/True", 1, 0),
            @(@{ $npc = $true; $vbx = $true; $ppp = $false; $uio = $false }, "$npc=skip/True,$vbx=skip/True,$ppp=enable/True,$uio=enable/True", 2, 0),
            @(@{ $npc = $true; $vbx = $true; $ppp = $true; $uio = $true }, "$npc=skip/True,$vbx=skip/True,$ppp=skip/True,$uio=skip/True", 0, 0),
            @(@{ $npc = $false; $vbx = $false; $ppp = $false }, "$npc=enable/True,$vbx=enable/True,$ppp=enable/True,$uio=missing/True", 3, 1))) {
        $got = ''; $n = -1; $r = -1
        try { $plan = @(Get-EoFilterRestorePlan $both $c[0]); $got = PlanText $plan; $n = @($plan | Where-Object Action -eq 'enable').Count; $r = @(Test-EoFilterRestorePlan $plan).Count } catch { $got = "threw: $($_.Exception.Message)" }
        Expect "filter undo plan (four enabled): $($c[1])" $got $c[1]
        Expect "filter undo plan (four enabled): $($c[1]) enables $($c[2]), refuses $($c[3])" "$n/$r" "$($c[2])/$($c[3])"
    }
    $mixed = FState '"componentId": "ms_pppoe", "displayName": "Point to Point Protocol Over Ethernet", "present": true, "enabledBefore": false' '"componentId": "ms_pppoe", "displayName": "Point to Point Protocol Over Ethernet", "present": true, "enabledBefore": true'
    $plan = @(Get-EoFilterRestorePlan $mixed @{ $npc = $false; $vbx = $false; $ppp = $false; $uio = $true })
    Expect 'filter undo plan: ms_ndisuio recorded off but enabled now is drift, and refuses' "$(PlanText $plan)|$(@(Test-EoFilterRestorePlan $plan).Count)" "$npc=enable/True,$vbx=leave-off/False,$ppp=enable/True,$uio=drifted/False|1"
}

# Bindings, unknown components and switch extensions, as verify-host checks them.
Expect 'filter bindings: both off passes' (@(Test-EoFilterBindings @{ $npc = $false; $vbx = $false; 'ms_tcpip' = $true }).Count) 0
Expect 'filter bindings: both absent passes' (@(Test-EoFilterBindings @{ 'ms_tcpip' = $true }).Count) 0
Expect 'filter bindings: all four off passes' (@(Test-EoFilterBindings @{ $npc = $false; $vbx = $false; $ppp = $false; $uio = $false; 'ms_tcpip' = $true }).Count) 0
Expect 'filter bindings: ms_pppoe enabled fails' (@(Test-EoFilterBindings @{ $npc = $false; $vbx = $false; $ppp = $true; $uio = $false }) -join ';') "$ppp is enabled on '$($EO.HostIf)'"
Expect 'filter bindings: ms_ndisuio enabled fails' (@(Test-EoFilterBindings @{ $uio = $true }) -join ';') "$uio is enabled on '$($EO.HostIf)'"
Expect 'filter bindings: all four enabled gives four problems' (@(Test-EoFilterBindings @{ $npc = $true; $vbx = $true; $ppp = $true; $uio = $true }).Count) 4
Expect 'filter unknown: hidden-only targets in the default view are not unknown' (@(Test-EoUnknownBindings @{ $ppp = $true; $uio = $true; 'ms_tcpip' = $true }).Count) 0
Expect 'filter bindings: Npcap enabled fails' (@(Test-EoFilterBindings @{ $npc = $true; $vbx = $false }) -join ';') "$npc is enabled on '$($EO.HostIf)'"
Expect 'filter bindings: VirtualBox enabled fails' (@(Test-EoFilterBindings @{ $vbx = $true }) -join ';') "$vbx is enabled on '$($EO.HostIf)'"
$clean = (FCur @{}).VisibleBindings
Expect 'unknown bindings: the 2026-11-01 inventory after 01c passes' (@(Test-EoUnknownBindings $clean).Count) 0
$c2 = $clean.Clone(); $c2[$npc] = $true; $c2[$vbx] = $true
Expect 'unknown bindings: enabled targets are left to their own check' (@(Test-EoUnknownBindings $c2).Count) 0
$c2 = $clean.Clone(); $c2['WINPCAP'] = $true
Expect 'unknown bindings: a new enabled filter fails' (@(Test-EoUnknownBindings $c2) -join ';') "WINPCAP is enabled on '$($EO.HostIf)' and is not in the allowed list"
$c2 = $clean.Clone(); $c2['ms_msclient'] = $true
Expect 'unknown bindings: client for Microsoft networks re-enabled fails' (@(Test-EoUnknownBindings $c2).Count) 1
$c2 = $clean.Clone(); $c2['ms_server'] = $false
Expect 'unknown bindings: a disabled unknown component passes' (@(Test-EoUnknownBindings $c2).Count) 0
$ext = @(@{ Name = 'Microsoft Windows Filtering Platform'; Vendor = 'Microsoft'; Enabled = 'True' }, @{ Name = 'Microsoft NDIS Capture'; Vendor = 'Microsoft'; Enabled = 'False' })
Expect 'switch extensions: WFP on, NDIS Capture off passes' (@(Test-EoSwitchExtensions $ext).Count) 0
Expect 'switch extensions: none passes' (@(Test-EoSwitchExtensions @()).Count) 0
$e2 = @($ext[0], @{ Name = 'Microsoft NDIS Capture'; Vendor = 'Microsoft'; Enabled = 'True' })
Expect 'switch extensions: NDIS Capture on is left to the 01c target check' (@(Test-EoSwitchExtensions $e2).Count) 0
$e2 = @(@{ Name = 'Microsoft Azure VFP Switch Filter Extension'; Vendor = 'Microsoft'; Enabled = 'True' })
Expect 'switch extensions: Azure VFP enabled fails' (@(Test-EoSwitchExtensions $e2).Count) 1
$e2 = @($ext[0], @{ Name = 'Contoso Mirror'; Vendor = 'Contoso'; Enabled = 'True' })
Expect 'switch extensions: a third-party extension on fails' (@(Test-EoSwitchExtensions $e2).Count) 1

# When verify-host checks the filter guard.
foreach ($c in @(
        @($true, $false, $false, $false, 'skip'), @($true, $false, $false, $true, 'check'), @($true, $false, $true, $false, 'check'),
        @($false, $false, $false, $false, 'check'), @($false, $false, $false, $true, 'check'),
        @($true, $true, $false, $false, 'absent'), @($true, $true, $false, $true, 'absent'), @($true, $true, $true, $true, 'absent'))) {
    Expect "filter mode: SwitchOnly=$($c[0]) BeforeGuard=$($c[1]) Require=$($c[2]) Record=$($c[3])" (Get-EoFilterGuardMode $c[0] $c[1] $c[2] $c[3]) $c[4]
}

# 01c's preconditions: it refuses before any change.
$gRec = $goodJson | ConvertFrom-Json
$gCur = FCur @{ Adapter = @{ InterfaceGuid = $guid; MacAddress = '00-15-5D-AA-BB-CC'; SettingId = $guid }; RuleDescriptions = (Cur @{}).RuleDescriptions }
$leaf = Split-Path -Leaf $EO.GuardState
Expect 'filter preconditions: 01b recorded and verified, clean inventory passes' (@(Test-EoFilterPreconditions $gRec $gCur $false @($leaf) $ext).Count) 0
$hostExt = @(@{ Name = 'Microsoft Windows Filtering Platform'; Vendor = 'Microsoft'; Enabled = 'False' }, @{ Name = 'Microsoft Azure VFP Switch Filter Extension'; Vendor = 'Microsoft'; Enabled = 'False' }, @{ Name = 'Microsoft NDIS Capture'; Vendor = 'Microsoft'; Enabled = 'True' })
Expect 'filter preconditions: the RH-DT-M3 extensions of 2026-11-02 (NDIS Capture on, a 01c target) pass' (@(Test-EoFilterPreconditions $gRec $gCur $false @($leaf) $hostExt).Count) 0
$fpre = [ordered]@{
    '01c record already exists'      = @($gRec, $gCur, $true, @($leaf), $ext, 'an earlier 01c was not undone')
    'no 01b record'                  = @($null, $gCur, $false, @(), $ext, 'no host guard (01b) record')
    'adapter differs from 01b'       = @($gRec, (FCur @{ Adapter = @{ InterfaceGuid = '{00000000-0000-4000-8000-000000000009}'; MacAddress = '00-15-5D-AA-BB-CC'; SettingId = $guid }; RuleDescriptions = (Cur @{}).RuleDescriptions }), $false, @($leaf), $ext, 'host guard record: adapter InterfaceGuid')
    'switch from another instance'   = @($gRec, (FCur @{ SwitchId = '99999999-2222-3333-4444-555555555555'; Adapter = $gCur.Adapter; RuleDescriptions = (Cur @{}).RuleDescriptions }), $false, @($leaf), $ext, 'another provisioning instance')
    'adapter missing'                = @($gRec, (FCur @{ Adapter = $null; RuleDescriptions = (Cur @{}).RuleDescriptions }), $false, @($leaf), $ext, 'or its host adapter is missing')
    'a stray file in the folder'     = @($gRec, $gCur, $false, @($leaf, 'filter-guard-state.json.tmp'), $ext, "holds 'filter-guard-state.json.tmp'")
    'an unknown filter enabled'      = @($gRec, (FCur @{ Adapter = $gCur.Adapter; RuleDescriptions = (Cur @{}).RuleDescriptions; VisibleBindings = @{ 'ms_tcpip' = $true; 'WINPCAP' = $true } }), $false, @($leaf), $ext, 'WINPCAP is enabled')
    'a third-party switch extension' = @($gRec, $gCur, $false, @($leaf), @(@{ Name = 'Contoso Mirror'; Vendor = 'Contoso'; Enabled = 'True' }), "switch extension 'Contoso Mirror'")
    'a leftover completion stamp'    = @($gRec, $gCur, $false, @($leaf, 'filter-guard-verified.json'), $ext, 'completion stamp of an earlier 01c')
    'a leftover stamp temp file'     = @($gRec, $gCur, $false, @($leaf, 'filter-guard-verified.json.tmp'), $ext, 'before its completion stamp was in place')
    'a target reported in another case' = @($gRec, (FCur @{ Adapter = $gCur.Adapter; RuleDescriptions = (Cur @{}).RuleDescriptions; Bindings = @{ 'MS_PPPOE' = $true; 'ms_tcpip' = $true } }), $false, @($leaf), $ext, "binding 'MS_PPPOE'")
}
foreach ($k in $fpre.Keys) {
    $a = $fpre[$k]; $threw = $false; $msgs = @()
    try { $msgs = @(Test-EoFilterPreconditions $a[0] $a[1] $a[2] $a[3] $a[4]) } catch { $threw = $true; $msgs = @("threw: $($_.Exception.Message)") }
    $hit = @($msgs | Where-Object { $_.Contains($a[5]) })
    Expect "filter preconditions: $k refused for its own reason" ($hit.Count -gt 0 -and -not $threw) $true
    if (-not $hit.Count) { $msgs | ForEach-Object { Write-Host "     $_" } }
}

# 04a's gate: it refuses unless 01c is installed and matches this host.
$fRecOk = $fJson | ConvertFrom-Json
$fSha = 'A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90'
$fStampJson = '{ "schema": "eo-l2-filter-guard-verified/1", "instanceId": "fedcba9876543210fedcba9876543210", "recordSha256": "' + $fSha + '", "verifiedAt": "2026-11-02T07:00:00Z" }'
$fStamp = $fStampJson | ConvertFrom-Json
Expect 'filter installed: matching record and completion stamp, targets off passes' (@(Test-EoFilterInstalled $fRecOk (FCur @{}) $fGuardId $fStamp $fSha).Count) 0
& {
    Set-StrictMode -Version 3.0
    Expect 'completion stamp: matching stamp passes under StrictMode' (@(Test-EoFilterVerified $fStamp $fRecOk $fSha).Count) 0
    $vbad = [ordered]@{
        'no stamp (01c stopped before the end)' = @($null, $fSha, '01c did not complete')
        'stamp for another 01c instance'        = @(($fStampJson.Replace('fedcba9876543210fedcba9876543210', '00000000000000000000000000000000') | ConvertFrom-Json), $fSha, 'is for 01c instance')
        'record changed since the stamp'        = @($fStamp, ('0' * 64), 'record now hashes to')
        'record hash not read'                  = @($fStamp, '', 'record now hashes to')
        'another stamp schema'                  = @(($fStampJson.Replace('verified/1', 'verified/0') | ConvertFrom-Json), $fSha, 'stamp schema is')
        'instance id as a list'                 = @(($fStampJson.Replace('"instanceId": "fedcba9876543210fedcba9876543210"', '"instanceId": ["fedcba9876543210fedcba9876543210"]') | ConvertFrom-Json), $fSha, 'instanceId is not a single string')
        'no recordSha256'                       = @(($fStampJson.Replace('"recordSha256"', '"recordShaX"') | ConvertFrom-Json), $fSha, "has no 'recordSha256'")
    }
    foreach ($k in $vbad.Keys) {
        $a = $vbad[$k]; $msgs = @()
        try { $msgs = @(Test-EoFilterVerified $a[0] $fRecOk $a[1]) } catch { $msgs = @("threw: $($_.Exception.Message)") }
        Expect "completion stamp: $k refused for its own reason" (@($msgs | Where-Object { $_.Contains($a[2]) }).Count -gt 0) $true
        if (-not @($msgs | Where-Object { $_.Contains($a[2]) }).Count) { $msgs | ForEach-Object { Write-Host "     $_" } }
    }
    Expect '04a gate: a record without a completion stamp is refused' (@(Test-EoFilterInstalled $fRecOk (FCur @{}) $fGuardId $null $fSha) -join ';').Contains('01c did not complete') $true
}
$finst = [ordered]@{
    'no 01c record'               = @($null, (FCur @{}), $fGuardId, 'is not installed')
    'a target enabled again'      = @($fRecOk, (FCur @{ Bindings = @{ $npc = $true; $vbx = $false; 'ms_tcpip' = $true } }), $fGuardId, "$npc is enabled")
    'ms_pppoe enabled again'      = @($fRecOk, (FCur @{ Bindings = @{ $npc = $false; $vbx = $false; $ppp = $true; 'ms_tcpip' = $true } }), $fGuardId, "$ppp is enabled")
    'ms_ndisuio enabled again'    = @($fRecOk, (FCur @{ Bindings = @{ $npc = $false; $vbx = $false; $uio = $true; 'ms_tcpip' = $true } }), $fGuardId, "$uio is enabled")
    'a /2 record (two targets)'   = @(($fJson.Replace('eo-l2-filter-guard/3', 'eo-l2-filter-guard/2') | ConvertFrom-Json), (FCur @{}), $fGuardId, 'schema is')
    'NDIS Capture enabled again'  = @($fRecOk, (FCur @{ ExtensionStates = @{ 'Microsoft NDIS Capture' = $true } }), $fGuardId, "'Microsoft NDIS Capture' is enabled")
    'adapter gone'                = @($fRecOk, (FCur @{ SwitchId = $null; Adapter = $null }), $fGuardId, 'not found')
    'record for another adapter'  = @($fRecOk, (FCur @{ Adapter = @{ InterfaceGuid = '{00000000-0000-4000-8000-000000000001}'; MacAddress = '00-15-5D-0A-1C-02'; SettingId = $fguid } }), $fGuardId, 'adapter InterfaceGuid')
    'another 01b instance'        = @($fRecOk, (FCur @{}), 'ffffffffffffffffffffffffffffffff', 'builds on host guard instance')
}
foreach ($k in $finst.Keys) {
    $a = $finst[$k]; $msgs = @()
    try { $msgs = @(Test-EoFilterInstalled $a[0] $a[1] $a[2] $fStamp $fSha) } catch { $msgs = @("threw: $($_.Exception.Message)") }
    Expect "filter installed: $k refused for its own reason" (@($msgs | Where-Object { $_.Contains($a[3]) }).Count -gt 0) $true
}
# What must not change while 01c or its undo runs (Test-EoFilterUnchanged), from
# Get-EoFilterCurrent facts: targets may change, nothing else on the adapter or switch.
& {
    Set-StrictMode -Version 3.0
    $b0 = FCur @{ Bindings = @{ $npc = $true; $vbx = $true; $ppp = $true; $uio = $true; 'ms_tcpip' = $true; 'ms_wfplwf_lower' = $true; 'ms_netbt' = $true }
        ExtensionStates = @{ 'Microsoft NDIS Capture' = $true; 'Microsoft Windows Filtering Platform' = $false } }
    $b0.Adapter['Netbios'] = 2
    $mk = { param([hashtable]$Bind, [hashtable]$Ext, [hashtable]$Ad)
        $n = FCur @{ Bindings = $Bind; ExtensionStates = $Ext }
        $n.Adapter = @{ InterfaceGuid = $fguid; MacAddress = '00-15-5D-0A-1C-02'; SettingId = $fguid; Netbios = 2 }
        if ($Ad) { foreach ($k in $Ad.Keys) { $n.Adapter[$k] = $Ad[$k] } }
        $n }
    $offAll = @{ $npc = $false; $vbx = $false; $ppp = $false; $uio = $false; 'ms_tcpip' = $true; 'ms_wfplwf_lower' = $true; 'ms_netbt' = $true }
    $extOff = @{ 'Microsoft NDIS Capture' = $false; 'Microsoft Windows Filtering Platform' = $false }
    Expect 'unchanged: all four targets and NDIS Capture off, nothing else, passes' (@(Test-EoFilterUnchanged $b0 (& $mk $offAll $extOff $null)).Count) 0
    Expect 'unchanged: one target off (partial), nothing else, passes' (@(Test-EoFilterUnchanged $b0 (& $mk @{ $npc = $false; $vbx = $true; $ppp = $true; $uio = $true; 'ms_tcpip' = $true; 'ms_wfplwf_lower' = $true; 'ms_netbt' = $true } $b0.ExtensionStates $null)).Count) 0
    $cases = [ordered]@{
        'IPv4 binding off'            = @(@{ 'ms_tcpip' = $false }, $null, $null, 'ms_tcpip on')
        'WFP filter unbound'          = @(@{ 'ms_wfplwf_lower' = $false }, $null, $null, 'ms_wfplwf_lower on')
        'NetBT binding removed'       = @(@{ 'ms_netbt' = $null }, $null, $null, 'ms_netbt on')
        'a new binding appears'       = @(@{ 'ms_lldp' = $true }, $null, $null, 'ms_lldp on')
        'WFP extension enabled'       = @($null, @{ 'Microsoft Windows Filtering Platform' = $true }, $null, "'Microsoft Windows Filtering Platform'")
        'NetBIOS value changed'       = @($null, $null, @{ Netbios = 0 }, 'adapter Netbios')
        'adapter replaced (GUID)'     = @($null, $null, @{ InterfaceGuid = '{00000000-0000-4000-8000-000000000009}' }, 'adapter InterfaceGuid')
        'adapter MAC changed'         = @($null, $null, @{ MacAddress = '00-15-5D-00-00-09' }, 'adapter MacAddress')
    }
    foreach ($k in $cases.Keys) {
        $c = $cases[$k]; $bind = $offAll.Clone(); $ext = $extOff.Clone()
        if ($c[0]) { foreach ($x in $c[0].Keys) { if ($null -eq $c[0][$x]) { $bind.Remove($x) } else { $bind[$x] = $c[0][$x] } } }
        if ($c[1]) { foreach ($x in $c[1].Keys) { $ext[$x] = $c[1][$x] } }
        $msgs = @(); try { $msgs = @(Test-EoFilterUnchanged $b0 (& $mk $bind $ext $c[2])) } catch { $msgs = @("threw: $($_.Exception.Message)") }
        Expect "unchanged: $k is caught" (@($msgs | Where-Object { $_.Contains($c[3]) }).Count -eq 1 -and $msgs.Count -eq 1) $true
        if ($msgs.Count -ne 1) { $msgs | ForEach-Object { Write-Host "     $_" } }
    }
    $n2 = & $mk $offAll $extOff $null; $n2.SwitchId = '99999999-2222-3333-4444-555555555555'
    Expect 'unchanged: another switch id is caught' (@(Test-EoFilterUnchanged $b0 $n2) -join ';') "switch id changed from '11111111-2222-3333-4444-555555555555' to '99999999-2222-3333-4444-555555555555'"
    $n3 = & $mk $offAll $extOff $null; $n3.Adapter = $null
    Expect 'unchanged: the adapter disappearing is caught' (@(Test-EoFilterUnchanged $b0 $n3).Count -ge 1) $true
}

# The settle wait after a binding change: the adapter up, its address Preferred and its
# on-link route present, on 3 polls in a row; a settled read before the restart begins
# does not count alone. Start-Sleep and the cmdlets are stubbed.
& {
    function Start-Sleep { param($Seconds) }
    $up = 'Up'; $state = 'Preferred'; $route = $true
    function Get-NetAdapter { [CmdletBinding()] param($Name) [pscustomobject]@{ Name = $Name; Status = $up } }
    function Get-NetIPAddress { [CmdletBinding()] param($InterfaceAlias, $AddressFamily) [pscustomobject]@{ IPAddress = $EO.HostIp; AddressState = $state } }
    function Get-NetRoute { [CmdletBinding()] param($InterfaceAlias, $AddressFamily) if ($route) { [pscustomobject]@{ DestinationPrefix = "$($EO.SubnetLow)/29" } } }
    Expect 'settle: up, Preferred and on-link route reads as settled' (Test-EoHostIfSettled) $true
    $up = 'Disconnected'; Expect 'settle: adapter down is not settled' (Test-EoHostIfSettled) $false; $up = 'Up'
    $state = 'Tentative'; Expect 'settle: a Tentative address is not settled' (Test-EoHostIfSettled) $false; $state = 'Preferred'
    $route = $false; Expect 'settle: no on-link route is not settled' (Test-EoHostIfSettled) $false; $route = $true
    $script:seq = @($true, $false, $true, $true, $true); $script:i = 0
    function Test-EoHostIfSettled { $v = $script:seq[[Math]::Min($script:i, $script:seq.Count - 1)]; $script:i++; $v }
    Expect 'settle: a settled read, a restart, then 3 settled reads passes' "$(Wait-EoHostIfAddress -Seconds 10)/$script:i" 'True/5'
    $script:seq = @($true, $false); $script:i = 0
    Expect 'settle: never 3 settled reads in a row gives false within the limit' "$(Wait-EoHostIfAddress -Seconds 6)/$script:i" 'False/6'
}

# Collateral changes between the before and after snapshots (Test-EoSnapshotCollateral),
# with the real layout: on eo-l2-int only the targets may change, on its switch
# adapter only ms_ndiscap; every other adapter, switch, firewall rule, address and
# route stays as it was.
& {
    Set-StrictMode -Version 3.0
    $snapJson = @'
{ "vmSwitches": [ { "name": "Default Switch", "type": "Internal", "adapter": null }, { "name": "eo-l2-int", "type": "Internal", "adapter": null }, { "name": "WSL", "type": "Internal", "adapter": null } ],
  "ipAddresses": [ { "if": "vEthernet (eo-l2-int)", "ip": "192.168.250.1", "prefix": 29 }, { "if": "vEthernet (Default Switch)", "ip": "172.20.0.1", "prefix": 20 } ],
  "routes": [ "192.168.250.0/29 via 0.0.0.0 on vEthernet (eo-l2-int)", "0.0.0.0/0 via 192.168.1.1 on Ethernet" ],
  "firewall": { "count": 1139, "sha256": "ae29ad22eb51", "eoRules": [ "eo-l2 a", "eo-l2 b", "eo-l2 c", "eo-l2 d", "eo-l2 e" ] },
  "eoBindings": [ "INSECURE_NPCAP|True", "ms_ndisuio|True", "ms_pppoe|True", "ms_tcpip|True", "ms_wfplwf_lower|True", "oracle_VBoxNetLwf|True" ],
  "eoSwitchExtensions": [ "Microsoft Azure VFP Switch Filter Extension|False", "Microsoft NDIS Capture|True", "Microsoft Windows Filtering Platform|False" ],
  "eoSwitchAdapterBindings": [ "ms_ndiscap|True", "ms_wfplwf_vswitch|False", "ms_winvfp|False", "vms_vsf|True", "vms_vsp|True" ],
  "otherSwitchExtensions": { "count": 6, "sha256": "d0b715be3ecd" },
  "otherBindings": { "count": 349, "sha256": "311e2bfb3819" } }
'@
    $sb = $snapJson | ConvertFrom-Json
    $ok = $snapJson.Replace('"INSECURE_NPCAP|True", "ms_ndisuio|True", "ms_pppoe|True"', '"INSECURE_NPCAP|False", "ms_ndisuio|False", "ms_pppoe|False"').Replace('"oracle_VBoxNetLwf|True"', '"oracle_VBoxNetLwf|False"').Replace('"Microsoft NDIS Capture|True"', '"Microsoft NDIS Capture|False"').Replace('"ms_ndiscap|True"', '"ms_ndiscap|False"')
    Expect 'collateral: the planned 01c change (four bindings, NDIS Capture and its ms_ndiscap) passes' (@(Test-EoSnapshotCollateral $sb ($ok | ConvertFrom-Json) -RequireSwitch) -join ';') ''
    Expect 'collateral: no change passes' (@(Test-EoSnapshotCollateral $sb $sb -RequireSwitch).Count) 0
    Expect 'collateral: the undo direction passes' (@(Test-EoSnapshotCollateral ($ok | ConvertFrom-Json) $sb).Count) 0
    $one = $snapJson.Replace('"ms_pppoe|True"', '"ms_pppoe|False"')
    Expect 'collateral: one target changed (partial) passes' (@(Test-EoSnapshotCollateral $sb ($one | ConvertFrom-Json) -RequireSwitch).Count) 0
    $bad = [ordered]@{
        'another adapter''s bindings (digest)' = @($ok.Replace('"311e2bfb3819"', '"aaaaaaaaaaaa"'), 'otherBindings changed')
        'another adapter added (count)'        = @($ok.Replace('"count": 349', '"count": 350'), 'otherBindings changed')
        'another switch''s extensions'         = @($ok.Replace('"d0b715be3ecd"', '"bbbbbbbbbbbb"'), 'otherSwitchExtensions changed')
        'a firewall rule (digest)'             = @($ok.Replace('"ae29ad22eb51"', '"cccccccccccc"'), 'firewall changed')
        'an eo-l2 rule renamed'                = @($ok.Replace('"eo-l2 e"', '"eo-l2 x"'), 'eo-l2 firewall rules changed')
        'a switch added'                       = @($ok.Replace('{ "name": "WSL", "type": "Internal", "adapter": null }', '{ "name": "WSL", "type": "Internal", "adapter": null }, { "name": "new", "type": "External", "adapter": "Wi-Fi" }'), 'Hyper-V switches changed')
        'the host IPv4 address'                = @($ok.Replace('"ip": "192.168.250.1"', '"ip": "192.168.250.2"'), 'IPv4 addresses')
        'the host IPv4 address gone'           = @($ok.Replace('{ "if": "vEthernet (eo-l2-int)", "ip": "192.168.250.1", "prefix": 29 }, ', ''), 'IPv4 addresses')
        'a route on the host vNIC'             = @($ok.Replace('"192.168.250.0/29 via 0.0.0.0 on vEthernet (eo-l2-int)"', '"0.0.0.0/0 via 192.168.250.2 on vEthernet (eo-l2-int)"'), 'routes on')
        'IPv4 unbound on the host vNIC'        = @($ok.Replace('"ms_tcpip|True"', '"ms_tcpip|False"'), "'$($EO.HostIf)' changed outside the targets")
        'a secondary binding on the host vNIC' = @($ok.Replace('"ms_wfplwf_lower|True"', '"ms_wfplwf_lower|False"'), "'$($EO.HostIf)' changed outside the targets")
        'another extension on eo-l2-int'       = @($ok.Replace('"Microsoft Windows Filtering Platform|False"', '"Microsoft Windows Filtering Platform|True"'), 'extensions of eo-l2-int changed outside')
        'vms_vsf on the switch adapter'        = @($ok.Replace('"vms_vsf|True"', '"vms_vsf|False"'), "'$($EO.SwitchAdapter)' changed outside")
        'VFP on the switch adapter'            = @($ok.Replace('"ms_winvfp|False"', '"ms_winvfp|True"'), "'$($EO.SwitchAdapter)' changed outside")
    }
    foreach ($k in $bad.Keys) {
        $msgs = @(); try { $msgs = @(Test-EoSnapshotCollateral $sb ($bad[$k][0] | ConvertFrom-Json) -RequireSwitch) } catch { $msgs = @("threw: $($_.Exception.Message)") }
        Expect "collateral: $k is caught, alone" (@($msgs | Where-Object { $_.Contains($bad[$k][1]) }).Count -eq 1 -and $msgs.Count -eq 1) $true
        if ($msgs.Count -ne 1) { $msgs | ForEach-Object { Write-Host "     $_" } }
    }
    $empty = $snapJson.Replace('"eoSwitchAdapterBindings": [ "ms_ndiscap|True", "ms_wfplwf_vswitch|False", "ms_winvfp|False", "vms_vsf|True", "vms_vsp|True" ]', '"eoSwitchAdapterBindings": []') | ConvertFrom-Json
    Expect 'collateral: 01c refuses a before snapshot without the switch adapter' (@(Test-EoSnapshotCollateral $empty $empty -RequireSwitch).Count) 1
    Expect 'collateral: the undo after the switch is gone does not need it' (@(Test-EoSnapshotCollateral $empty $empty).Count) 0
}

& {
    $t = $null; $e = $null
    $a4 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir '04a-add-setup-nic.ps1'), [ref]$t, [ref]$e)
    $off = { param($Cmd) @($a4.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Cmd }, $true) | ForEach-Object { $_.Extent.StartOffset } | Sort-Object) }
    $g = @(& $off 'Assert-FilterGuard'); $c = @(& $off 'Confirm-EoPlan'); $add = @(& $off 'Add-VMNetworkAdapter')
    Expect '04a gate: checks the filter guard before and after its confirmation, before adding the NIC' ($g.Count -eq 2 -and $c.Count -eq 1 -and $add.Count -eq 1 -and $g[0] -lt $c[0] -and $g[1] -gt $c[0] -and $g[1] -lt $add[0]) $true
    $v = @($a4.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$($n.CommandElements[0])" -match 'verify-host' }, $true) | ForEach-Object { "$($_.Extent.Text)" })
    Expect '04a gate: verifies with the filter guard required' (@($v | Where-Object { $_ -match '-SwitchOnly -RequireFilterGuard$' }).Count) 1
}

# The only place a binding changes: targets only, on the host vNIC only, nothing
# changed when any id is not a target.
& {
    $script:calls = New-Object System.Collections.Generic.List[string]
    # Like the real cmdlets on RH-DT-M3: a hidden binding (ms_pppoe, ms_ndisuio) is
    # matched only with -AllBindings, and a failure must stop the caller.
    $hidden = @('ms_pppoe', 'ms_ndisuio')
    function Enable-NetAdapterBinding { [CmdletBinding()] param($Name, $ComponentID, [switch]$AllBindings)
        if ($ComponentID -in $hidden -and -not $AllBindings) { return }
        if ("$($PSBoundParameters['ErrorAction'])" -ne 'Stop') { $script:calls.Add('no-stop') }
        $script:calls.Add("enable $Name $ComponentID") }
    function Disable-NetAdapterBinding { [CmdletBinding()] param($Name, $ComponentID, [switch]$AllBindings)
        if ($ComponentID -in $hidden -and -not $AllBindings) { return }
        if ("$($PSBoundParameters['ErrorAction'])" -ne 'Stop') { $script:calls.Add('no-stop') }
        $script:calls.Add("disable $Name $ComponentID") }
    foreach ($c in @(
            @(@($npc, $vbx), $false, "disable $($EO.HostIf) $npc;disable $($EO.HostIf) $vbx"),
            @(@($npc), $true, "enable $($EO.HostIf) $npc"),
            @(@($npc, $vbx, $ppp, $uio), $false, "disable $($EO.HostIf) $npc;disable $($EO.HostIf) $vbx;disable $($EO.HostIf) $ppp;disable $($EO.HostIf) $uio"),
            @(@($ppp, $uio), $true, "enable $($EO.HostIf) $ppp;enable $($EO.HostIf) $uio"),
            @(@($ppp, 'ms_netbt'), $false, 'refused:'),
            @(@('ms_ndiscap'), $false, 'refused:'),
            @(@(), $false, ''),
            @(@('ms_tcpip'), $false, 'refused:'),
            @(@($npc, 'ms_tcpip'), $true, 'refused:'),
            @(@('insecure_npcap'), $false, 'refused:'))) {
        $script:calls.Clear(); $got = ''
        try { Set-EoFilterBindings $c[0] -Enable:$c[1]; $got = $script:calls -join ';' } catch { $got = "refused:$($script:calls -join ';')" }
        Expect "filter set: '$($c[0] -join ',')' enable=$($c[1])" $got $c[2]
    }
    function Enable-VMSwitchExtension { [CmdletBinding()] param($VMSwitch, $Name) $script:calls.Add("enable-ext $($VMSwitch.Id) $Name") }
    function Disable-VMSwitchExtension { [CmdletBinding()] param($VMSwitch, $Name) $script:calls.Add("disable-ext $($VMSwitch.Id) $Name") }
    $swId = '3d1cfb06-8390-426d-8579-bd79b6bf3aa4'; $dupId = '11111111-8390-426d-8579-bd79b6bf3aa4'; $extId = '22222222-8390-426d-8579-bd79b6bf3aa4'
    function Get-VMSwitch { [CmdletBinding()] param($Id)
        switch ($Id) {
            $swId { [pscustomobject]@{ Id = $swId; Name = $EO.SwitchName; SwitchType = 'Internal' } }
            $dupId { [pscustomobject]@{ Id = $dupId; Name = 'Default Switch'; SwitchType = 'Internal' } }
            $extId { [pscustomobject]@{ Id = $extId; Name = $EO.SwitchName; SwitchType = 'External' } }
        } }
    $ndc = 'Microsoft NDIS Capture'
    foreach ($c in @(
            @(@($ndc), $false, $swId, "disable-ext $swId $ndc"),
            @(@($ndc), $true, $swId, "enable-ext $swId $ndc"),
            @(@(), $true, $swId, ''),
            @(@('Microsoft Windows Filtering Platform'), $false, $swId, 'refused:'),
            @(@($ndc, 'Microsoft Azure VFP Switch Filter Extension'), $true, $swId, 'refused:'),
            @(@('microsoft ndis capture'), $false, $swId, 'refused:'),
            @(@($ndc), $false, $dupId, 'refused:'),
            @(@($ndc), $false, $extId, 'refused:'),
            @(@($ndc), $false, '99999999-8390-426d-8579-bd79b6bf3aa4', 'refused:'),
            @(@($ndc), $false, '', 'refused:'))) {
        $script:calls.Clear(); $got = ''
        try { Set-EoSwitchExtensions $c[0] $c[2] -Enable:$c[1]; $got = $script:calls -join ';' } catch { $got = "refused:$($script:calls -join ';')" }
        Expect "filter set extension: '$($c[0] -join ',')' on '$($c[2])' enable=$($c[1])" $got $c[3]
    }
}

# Structure: in the 01c scripts and the verifier, every call to a function that
# returns a list sits directly in @(), so 0 or 1 results cannot break .Count under
# StrictMode (D-2); and 01c verifies with the filter guard required.
& {
    $listFns = @('Get-EoFilterApplyPlan', 'Get-EoFilterRestorePlan', 'Test-EoFilterRestorePlan', 'Test-EoFilterState', 'Test-EoFilterBindings', 'Test-EoUnknownBindings', 'Test-EoSwitchExtensions', 'Test-EoFilterPreconditions', 'Test-EoFilterInstalled', 'Test-EoFilterExtensions', 'Test-EoSwitchAdapterBindings', 'Test-EoFilterUnchanged', 'Test-EoSnapshotCollateral', 'Test-EoFilterVerified', 'Test-EoGuardState', 'Test-EoAclFacts', 'Get-NetAdapterBinding', 'Get-VMSwitchExtension', 'Get-ChildItem')
    foreach ($f in '01c-filter-guard.ps1', 'undo-01c-filter-guard.ps1', 'verify-host.ps1', '_guard.ps1', '04a-add-setup-nic.ps1') {
        $t = $null; $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir $f), [ref]$t, [ref]$e)
        # verify-host reads one known binding (ms_tcpip6) as a single object, never counted.
        $fns = if ($f -eq 'verify-host.ps1') { @($listFns | Where-Object { $_ -ne 'Get-NetAdapterBinding' }) } else { $listFns }
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $fns }, $true))
        $bare = @($calls | Where-Object {
                $q = $_.Parent; $ok = $false
                # A call inside the expression of an @( ) in a pipeline, a subexpression or an if inside @().
                for ($i = 0; $i -lt 6 -and $q; $i++) { if ($q -is [System.Management.Automation.Language.ArrayExpressionAst]) { $ok = $true; break }; if ($q -is [System.Management.Automation.Language.AssignmentStatementAst] -or $q -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }; $q = $q.Parent }
                -not $ok -and -not ($_.Parent.Parent -is [System.Management.Automation.Language.ForEachStatementAst]) })
        Expect "filter structure: $f has $($calls.Count) list call(s), none outside @()" (($bare | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Extent.Text)" }) -join ' | ') ''
    }
    $t = $null; $e = $null
    $c01 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir '01c-filter-guard.ps1'), [ref]$t, [ref]$e)
    $v = @($c01.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and "$($n.CommandElements[0])" -match 'verify-host' }, $true) | ForEach-Object { "$($_.Extent.Text)" })
    Expect 'filter structure: 01c verifies before (SwitchOnly) and after (RequireFilterGuard)' (@($v | Where-Object { $_ -match '-SwitchOnly$' }).Count -eq 1 -and @($v | Where-Object { $_ -match '-SwitchOnly -RequireFilterGuard$' }).Count -eq 1) $true
    $bindingCalls = @($c01.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(Enable|Disable)-(NetAdapterBinding|VMSwitchExtension)$' }, $true))
    Expect 'filter structure: 01c changes bindings and extensions only through Set-EoFilterBindings and Set-EoSwitchExtensions' $bindingCalls.Count 0
    $u01 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir 'undo-01c-filter-guard.ps1'), [ref]$t, [ref]$e)
    $bindingCalls = @($u01.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -match '^(Enable|Disable)-(NetAdapterBinding|VMSwitchExtension)$' }, $true))
    Expect 'filter structure: undo-01c changes bindings and extensions only through Set-EoFilterBindings and Set-EoSwitchExtensions' $bindingCalls.Count 0

    # Order in the scripts: preconditions read before and again after the typed
    # confirmation, the record moved into place before any binding changes, and the
    # binding change after the second read.
    function Offsets($Ast, [string]$Cmd, [string]$Match = '') { @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Cmd -and "$($n.Extent.Text)" -match $Match }, $true) | ForEach-Object { $_.Extent.StartOffset } | Sort-Object) }
    $conf = @(Offsets $c01 'Confirm-EoPlan'); $pre = @(Offsets $c01 'Get-Preconditions'); $mv = @(Offsets $c01 'Move-Item' 'FilterState'); $set = @(Offsets $c01 'Set-EoFilterBindings')
    Expect 'filter order: 01c reads preconditions once before and once after its confirmation' ($conf.Count -eq 1 -and $pre.Count -eq 2 -and $pre[0] -lt $conf[0] -and $pre[1] -gt $conf[0]) $true
    Expect 'filter order: 01c moves the record into place before it changes a binding' ($mv.Count -eq 1 -and $set.Count -eq 1 -and $mv[0] -gt $pre[1] -and $mv[0] -lt $set[0]) $true
    $xset = @(Offsets $c01 'Set-EoSwitchExtensions')
    $vmv = @(Offsets $c01 'Move-Item' 'FilterVerified')
    Expect 'filter order: 01c writes its completion stamp once, after its final verification' ($vmv.Count -eq 1 -and $xset.Count -eq 1 -and $vmv[0] -gt $xset[0]) $true
    Expect 'filter order: 01c changes the extension after the record, once' ($xset.Count -eq 1 -and $xset[0] -gt $mv[0]) $true
    $conf = @(Offsets $u01 'Confirm-EoPlan'); $pre = @(Offsets $u01 'Get-UndoFacts'); $set = @(Offsets $u01 'Set-EoFilterBindings'); $mv = @(Offsets $u01 'Move-Item' 'FilterState')
    Expect 'filter order: undo-01c reads its facts once before and once after its confirmation' ($conf.Count -eq 1 -and $pre.Count -eq 2 -and $pre[0] -lt $conf[0] -and $pre[1] -gt $conf[0]) $true
    Expect 'filter order: undo-01c changes bindings after the second read and closes the record after that' ($set.Count -eq 1 -and $mv.Count -eq 1 -and $set[0] -gt $pre[1] -and $mv[0] -gt $set[0]) $true
    $xset = @(Offsets $u01 'Set-EoSwitchExtensions')
    $vmv = @(Offsets $u01 'Move-Item' 'FilterVerified')
    Expect 'filter order: undo-01c closes the completion stamp before the record' ($vmv.Count -eq 1 -and $mv.Count -eq 1 -and $vmv[0] -lt $mv[0] -and $vmv[0] -gt $xset[0]) $true
    Expect 'filter order: undo-01c restores the extension after the second read and before closing the record' ($xset.Count -eq 1 -and $xset[0] -gt $pre[1] -and $mv[0] -gt $xset[0]) $true

    # verify-host's filter record line, run as shipped for 0, 1 and 3 problems and an unreadable record.
    $vast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir 'verify-host.ps1'), [ref]$t, [ref]$e)
    $assigns = @($vast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and "$($n.Left)" -eq '$fp' }, $true))
    Expect 'filter problems: verify-host.ps1 assigns $fp exactly once' $assigns.Count 1
    foreach ($case in @(@(0, $null, '0|', $null), @(1, $null, '1|problem 1', $null), @(3, $null, '3|problem 1; problem 2; problem 3', $null), @(0, 'bad json', '1|filter record unreadable: bad json', $null), @(0, $null, '1|bindings not read: x', 'bindings not read: x'))) {
        $got = ''
        try {
            $got = & {
                Set-StrictMode -Version 3.0
                $ErrorActionPreference = 'Stop'
                $N = $case[0]
                function Test-EoFilterState($State, $Current, $Gid) { $p = New-Object System.Collections.Generic.List[string]; for ($i = 1; $i -le $N; $i++) { $p.Add("problem $i") }; return $p }
                $ferr = $case[1]; $fread = $case[3]; $fstate = $null; $fcur = $null; $gid = $null
                . ([scriptblock]::Create($assigns[0].Extent.Text))
                "$($fp.Count)|$($fp -join '; ')"
            }
        } catch { $got = "threw: $($_.Exception.Message)" }
        Expect "filter problems: shipped line, $($case[0]) problem(s), record error '$($case[1])', read error '$($case[3])'" $got $case[2]
    }
}

# --- VM folder chain (02, undo-02, verify-host): owner, ACL and link checks -------
# C:\Hyper-V, C:\Hyper-V\eo-l2, its iso folder, the disks, the ISO and the VM
# configuration, as plain facts (Test-EoPathFacts, Test-EoChainFacts, Test-EoVmTree).
$vA = 'S-1-5-32-544'; $vS = 'S-1-5-18'; $vU = 'S-1-5-32-545'; $vAU = 'S-1-5-11'; $vEv = 'S-1-1-0'
$vTI = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; $vCO = 'S-1-3-0'
$vVm = 'S-1-5-83-1-1234567890-1122334455-987654321-123456789'; $vAtk = 'S-1-5-21-1-2-3-1001'
$vCap = 'S-1-15-3-65536-1888954469-739942743-1668119174-2468466756-4239452838-1296943325-355587736-700089176'
# FullControl, ReadAndExecute, Modify, (S,RD,X,RA) as the C:\ capability entries on RH-DT-M3, GENERIC_ALL.
$vF = 2032127; $vRX = 1179817; $vM = 1245631; $vCapR = 1048737; $vGA = 268435456
function VAce([string]$Sid, [int64]$Rights, [switch]$Inherited, [switch]$InheritOnly, [switch]$Deny) { @{ Sid = $Sid; Allow = (-not $Deny); Rights = $Rights; Inherited = [bool]$Inherited; InheritOnly = [bool]$InheritOnly } }
function VFacts([string]$Path, [bool]$Container, [hashtable]$Over) {
    $f = @{ Path = $Path; Exists = $true; Reparse = $false; Container = $Container; Owner = $vA; Protected = $true; Aces = @((VAce $vA $vF), (VAce $vS $vF)) }
    foreach ($k in $Over.Keys) { $f[$k] = $Over[$k] }
    return $f
}
function VHit($Msgs, [string]$Want) { @(@($Msgs) | Where-Object { "$_".Contains($Want) }).Count -gt 0 }
& {
    Set-StrictMode -Version 3.0
    $pNew = @((VAce $vA $vF), (VAce $vS $vF), (VAce $vU $vRX))
    $hv = $EO.VmParent
    Expect 'vm folders: C:\Hyper-V as 02 creates it passes the new-folder check' (@(Test-EoPathFacts (VFacts $hv $true @{ Aces = $pNew }) 'parent' -Container -New) -join ';') ''
    Expect 'vm folders: a protected admin-only C:\Hyper-V passes' (@(Test-EoPathFacts (VFacts $hv $true @{ Aces = $pNew }) 'parent' -Container).Count) 0
    Expect 'vm folders: C:\Hyper-V owned by SYSTEM passes' (@(Test-EoPathFacts (VFacts $hv $true @{ Owner = $vS }) 'parent' -Container).Count) 0
    Expect 'vm folders: C:\Hyper-V owned by TrustedInstaller, with its full control, passes' (@(Test-EoPathFacts (VFacts $hv $true @{ Owner = $vTI; Aces = @((VAce $vTI $vF), (VAce $vA $vF)) }) 'parent' -Container).Count) 0
    Expect 'vm folders: C:\Hyper-V with an inherit-only CREATOR OWNER entry passes (decision)' (@(Test-EoPathFacts (VFacts $hv $true @{ Aces = $pNew + @((VAce $vCO $vGA -InheritOnly)) }) 'parent' -Container).Count) 0
    Expect 'vm folders: C:\Hyper-V with read-only entries for other accounts passes (decision: write-class rights only)' (@(Test-EoPathFacts (VFacts $hv $true @{ Protected = $false; Aces = $pNew + @((VAce $vAU $vRX -Inherited), (VAce $vCap $vCapR -Inherited)) }) 'parent' -Container).Count) 0
    Expect 'vm folders: a Deny entry is not counted as access' (@(Test-EoPathFacts (VFacts $hv $true @{ Aces = $pNew + @((VAce $vAU $vF -Deny)) }) 'parent' -Container).Count) 0
    $parentBad = [ordered]@{
        'attacker-owned (a standard user made it)'                    = @(@{ Owner = $vAtk }, "is owned by $vAtk")
        'inheriting the C:\ ACL (Authenticated Users Modify, as on RH-DT-M3)' = @(@{ Protected = $false; Aces = @((VAce $vA $vF -Inherited), (VAce $vS $vF -Inherited), (VAce $vU $vRX -Inherited), (VAce $vAU $vM -Inherited), (VAce $vCap $vCapR -Inherited)) }, "write-class right to $vAU")
        'Authenticated Users may add folders (AD)'                    = @(@{ Aces = $pNew + @((VAce $vAU 4)) }, "write-class right to $vAU")
        'Users may write'                                             = @(@{ Aces = @((VAce $vA $vF), (VAce $vS $vF), (VAce $vU 278)) }, "write-class right to $vU")
        'a user may delete it'                                        = @(@{ Aces = $pNew + @((VAce $vAtk 0x10000)) }, "write-class right to $vAtk")
        'a user may delete what is in it'                             = @(@{ Aces = $pNew + @((VAce $vAtk 0x40)) }, "write-class right to $vAtk")
        'a user may change its permissions'                           = @(@{ Aces = $pNew + @((VAce $vAtk 0x40000)) }, "write-class right to $vAtk")
        'a user may take ownership'                                   = @(@{ Aces = $pNew + @((VAce $vAtk 0x80000)) }, "write-class right to $vAtk")
        'Everyone GENERIC_ALL, inherit-only'                          = @(@{ Aces = $pNew + @((VAce $vEv $vGA -InheritOnly)) }, "write-class right to $vEv")
        'CREATOR OWNER effective on the folder itself'                = @(@{ Aces = $pNew + @((VAce $vCO $vF)) }, "write-class right to $vCO")
        'the VM account on C:\Hyper-V'                                = @(@{ Aces = $pNew + @((VAce $vVm $vF)) }, "write-class right to $vVm")
        'a junction'                                                  = @(@{ Reparse = $true }, 'is a link')
        'a file'                                                      = @(@{ Container = $false }, 'is a file, want a folder')
        'a null or empty ACL'                                         = @(@{ Aces = @() }, 'has no access entries')
        'only a Deny entry'                                           = @(@{ Aces = @((VAce $vA $vF -Deny)) }, 'has no access entries')
        'missing'                                                     = @(@{ Exists = $false }, 'does not exist')
    }
    foreach ($k in $parentBad.Keys) {
        $msgs = @(); try { $msgs = @(Test-EoPathFacts (VFacts $hv $true $parentBad[$k][0]) 'parent' -Container) } catch { $msgs = @("threw: $($_.Exception.Message)") }
        Expect "vm folders: C:\Hyper-V $k refused for its own reason" (VHit $msgs $parentBad[$k][1]) $true
        if (-not (VHit $msgs $parentBad[$k][1])) { $msgs | ForEach-Object { Write-Host "     $_" } }
    }
    $newBad = [ordered]@{
        'inheriting'                        = @(@{ Aces = $pNew; Protected = $false }, 'inherits permissions')
        'owned by SYSTEM, not Administrators' = @(@{ Aces = $pNew; Owner = $vS }, "is owned by $vS")
        'Authenticated Users read'          = @(@{ Aces = $pNew + @((VAce $vAU $vRX)) }, "grants $vAU")
        'Users write'                       = @(@{ Aces = @((VAce $vA $vF), (VAce $vS $vF), (VAce $vU $vM)) }, "grants $vU")
        'an inherit-only CREATOR OWNER'     = @(@{ Aces = $pNew + @((VAce $vCO $vGA -InheritOnly)) }, "grants $vCO")
    }
    foreach ($k in $newBad.Keys) {
        $msgs = @(Test-EoPathFacts (VFacts $hv $true $newBad[$k][0]) 'parent' -Container -New)
        Expect "vm folders: a C:\Hyper-V 02 just created, $k, refused for its own reason" (VHit $msgs $newBad[$k][1]) $true
    }

    $root = $EO.Root
    Expect 'vm folders: eo-l2 Administrators and SYSTEM only, protected, passes' (@(Test-EoPathFacts (VFacts $root $true @{}) 'root' -Container).Count) 0
    Expect 'vm folders: eo-l2 as 02 creates it passes the new-folder check' (@(Test-EoPathFacts (VFacts $root $true @{}) 'root' -Container -New).Count) 0
    Expect 'vm folders: eo-l2 owned by SYSTEM passes the existing-folder check' (@(Test-EoPathFacts (VFacts $root $true @{ Owner = $vS }) 'root' -Container).Count) 0
    $rootBad = [ordered]@{
        'inheriting'                  = @(@{ Protected = $false }, 'inherits permissions')
        'Users read'                  = @(@{ Aces = @((VAce $vA $vF), (VAce $vS $vF), (VAce $vU $vRX)) }, "grants access to $vU")
        'CREATOR OWNER (inherit-only)' = @(@{ Aces = @((VAce $vA $vF), (VAce $vS $vF), (VAce $vCO $vGA -InheritOnly)) }, "grants access to $vCO")
        'the VM account'              = @(@{ Aces = @((VAce $vA $vF), (VAce $vS $vF), (VAce $vVm $vF)) }, "grants access to $vVm")
        'owned by a user'             = @(@{ Owner = $vAtk }, "is owned by $vAtk")
        'owned by TrustedInstaller'   = @(@{ Owner = $vTI }, "is owned by $vTI")
        'a junction'                  = @(@{ Reparse = $true }, 'is a link')
        'a file'                      = @(@{ Container = $false }, 'is a file, want a folder')
    }
    foreach ($k in $rootBad.Keys) {
        $msgs = @(Test-EoPathFacts (VFacts $root $true $rootBad[$k][0]) 'root' -Container)
        Expect "vm folders: eo-l2 $k refused for its own reason" (VHit $msgs $rootBad[$k][1]) $true
        $msgs = @(Test-EoPathFacts (VFacts $EO.IsoDir $true $rootBad[$k][0]) 'root' -Container)
        Expect "vm folders: iso folder $k refused for its own reason" (VHit $msgs $rootBad[$k][1]) $true
    }

    $disk = @((VAce $vA $vF -Inherited), (VAce $vS $vF -Inherited), (VAce $vVm $vF))
    Expect 'vm folders: a VHDX with the VM account allowed (attached disk) passes' (@(Test-EoPathFacts (VFacts $EO.SystemVhd $false @{ Protected = $false; Aces = $disk }) 'vm').Count) 0
    Expect 'vm folders: the ISO with the VM account allowed passes' (@(Test-EoPathFacts (VFacts (Join-Path $EO.IsoDir 'debian.iso') $false @{ Protected = $false; Owner = $vS; Aces = $disk }) 'vm').Count) 0
    Expect 'vm folders: a runtime file owned by the VM account passes' (@(Test-EoPathFacts (VFacts "$root\eo-l2\Virtual Machines\x.VMRS" $false @{ Protected = $false; Owner = $vVm; Aces = $disk }) 'vm').Count) 0
    Expect 'vm folders: the VM configuration folder with the VM account passes' (@(Test-EoPathFacts (VFacts "$root\eo-l2\Virtual Machines" $true @{ Protected = $false; Aces = $disk }) 'vm' -Container).Count) 0
    $vmBad = [ordered]@{
        'the Virtual Machines group (S-1-5-83-0)' = @(@{ Aces = $disk + @((VAce 'S-1-5-83-0' $vF)) }, 'grants access to S-1-5-83-0')
        'a malformed VM account SID'          = @(@{ Aces = $disk + @((VAce 'S-1-5-83-1-5' $vF)) }, 'grants access to S-1-5-83-1-5')
        'Users read'                          = @(@{ Aces = $disk + @((VAce $vU $vRX -Inherited)) }, "grants access to $vU")
        'Authenticated Users Modify'          = @(@{ Aces = $disk + @((VAce $vAU $vM -Inherited)) }, "grants access to $vAU")
        'owned by a user'                     = @(@{ Aces = $disk; Owner = $vAtk }, "is owned by $vAtk")
        'a symbolic link'                     = @(@{ Aces = $disk; Reparse = $true }, 'is a link')
        'a folder where the disk should be'   = @(@{ Aces = $disk; Container = $true }, 'is a folder, want a file')
    }
    foreach ($k in $vmBad.Keys) {
        $msgs = @(Test-EoPathFacts (VFacts $EO.AnchorVhd $false $vmBad[$k][0]) 'vm')
        Expect "vm folders: a disk with $k refused for its own reason" (VHit $msgs $vmBad[$k][1]) $true
    }
    $threw = $false; try { $null = @(Test-EoPathFacts (VFacts $root $true @{}) 'other' -Container) } catch { $threw = $true }
    Expect 'vm folders: an unknown kind throws' $threw $true

    # What New-EoDirSecurity builds, read back as facts (no folder made, no elevation).
    foreach ($c in @(@($true, 'parent', 3), @($false, 'root', 2))) {
        $sec = New-EoDirSecurity -Parent:$c[0]
        $sf = ConvertTo-EoSecurityFacts $sec
        $f = @{ Path = "new $($c[1])"; Exists = $true; Reparse = $false; Container = $true; Owner = $sf.Owner; Protected = $sf.Protected; Aces = $sf.Aces }
        Expect "vm folders: New-EoDirSecurity for the $($c[1]) passes its own new-folder check" (@(Test-EoPathFacts $f $c[1] -Container -New) -join ';') ''
        Expect "vm folders: New-EoDirSecurity for the $($c[1]) has $($c[2]) entries, owner Administrators, protected" "$(@($sf.Aces).Count)/$($sf.Owner)/$($sf.Protected)" "$($c[2])/$vA/True"
    }

    # The chain, level by level.
    Expect 'vm chain: the folders above and at the iso folder' ((Get-EoAncestorPaths $EO.IsoDir) -join '|') 'C:\|C:\Hyper-V|C:\Hyper-V\eo-l2|C:\Hyper-V\eo-l2\iso'
    Expect 'vm chain: a trailing backslash' ((Get-EoAncestorPaths 'C:\Hyper-V\') -join '|') 'C:\|C:\Hyper-V'
    Expect 'vm chain: the drive root alone' ((Get-EoAncestorPaths 'C:\') -join '|') 'C:\'
    function VChain([int]$LinkAt = -1, [int]$MissingFrom = 99, [int]$FileAt = -1) {
        $i = 0
        foreach ($x in @(Get-EoAncestorPaths $EO.IsoDir)) { @{ Path = $x; Exists = ($i -lt $MissingFrom); Reparse = ($i -eq $LinkAt); Container = ($i -ne $FileAt) }; $i++ }
    }
    Expect 'vm chain: no link passes' (@(Test-EoChainFacts @(VChain)).Count) 0
    Expect 'vm chain: eo-l2 and iso not there yet passes' (@(Test-EoChainFacts @(VChain -MissingFrom 2)).Count) 0
    $levels = @(Get-EoAncestorPaths $EO.IsoDir)
    for ($i = 1; $i -lt $levels.Count; $i++) {
        $msgs = @(Test-EoChainFacts @(VChain -LinkAt $i))
        Expect "vm chain: a link at $($levels[$i]) is caught, alone" "$($msgs.Count)/$(VHit $msgs "$($levels[$i]) is a link")" '1/True'
    }
    Expect 'vm chain: a file where C:\Hyper-V should be is caught' (VHit @(Test-EoChainFacts @(VChain -FileAt 1)) 'C:\Hyper-V is a file') $true

    # What eo-l2 may hold (Test-EoVmTree).
    function VE([string]$Rel, [bool]$Dir, [bool]$Link = $false) { [pscustomobject]@{ Rel = $Rel; Full = "$($EO.Root)\$Rel"; Container = $Dir; Reparse = $Link } }
    $g = '0F2E2C1A-5B9D-4C3E-8A7B-123456789ABC'
    $tree = @((VE 'eo-l2-system.vhdx' $false), (VE 'eo-l2-anchor.vhdx' $false), (VE 'iso' $true), (VE 'iso\debian-13.1.0-amd64-netinst.iso' $false),
        (VE 'eo-l2' $true), (VE 'eo-l2\Virtual Machines' $true), (VE "eo-l2\Virtual Machines\$g.vmcx" $false), (VE "eo-l2\Virtual Machines\$g.vmgs" $false),
        (VE "eo-l2\Virtual Machines\$g.VMRS" $false), (VE "eo-l2\Virtual Machines\$g" $true), (VE "eo-l2\Virtual Machines\$g\$g.vsv" $false), (VE 'eo-l2\Snapshots' $true))
    Expect 'vm tree: the expected layout passes' (@(Test-EoVmTree $tree) -join ';') ''
    Expect 'vm tree: part of it (02 stopped early) passes' (@(Test-EoVmTree @($tree[0], $tree[2])).Count) 0
    Expect 'vm tree: an empty eo-l2 passes' (@(Test-EoVmTree @()).Count) 0
    $treeBad = [ordered]@{
        'an unexpected file in eo-l2'                 = @((VE 'payload.exe' $false), 'payload.exe (file) is not something')
        'a third VHDX'                                = @((VE 'other.vhdx' $false), 'other.vhdx (file) is not something')
        'VM configuration directly in eo-l2'          = @((VE 'Virtual Machines' $true), 'Virtual Machines (folder) is not something')
        'a folder inside iso'                         = @((VE 'iso\sub' $true), 'iso\sub (folder) is not something')
        'a non-ISO file in iso'                       = @((VE 'iso\notes.txt' $false), 'iso\notes.txt (file) is not something')
        'a VHDX that is a folder'                     = @((VE 'eo-l2-system.vhdx' $true), 'eo-l2-system.vhdx (folder) is not something')
        'another folder in the VM folder'             = @((VE 'eo-l2\Virtual Hard Disks' $true), 'eo-l2\Virtual Hard Disks (folder)')
        'a file directly in the VM folder'            = @((VE 'eo-l2\x.vmcx' $false), 'eo-l2\x.vmcx (file)')
        'a nested junction in the VM configuration'   = @((VE "eo-l2\Virtual Machines\$g\j" $true $true), "eo-l2\Virtual Machines\$g\j is a link")
        'the iso folder is a junction'                = @((VE 'iso' $true $true), 'iso is a link')
        'the system disk is a symbolic link'          = @((VE 'eo-l2-system.vhdx' $false $true), 'eo-l2-system.vhdx is a link')
    }
    foreach ($k in $treeBad.Keys) {
        $msgs = @(Test-EoVmTree @($tree + @($treeBad[$k][0])))
        Expect "vm tree: $k refused, alone" "$($msgs.Count)/$(VHit $msgs $treeBad[$k][1])" '1/True'
        if ($msgs.Count -ne 1) { $msgs | ForEach-Object { Write-Host "     $_" } }
    }

    # What Remove-EoVerifiedTree may delete at all (checked before it reads anything).
    Expect 'delete guard: C:\Hyper-V\eo-l2 may be deleted' (@(Test-EoDeletableRoot $EO.Root) -join ';') ''
    $delBad = [ordered]@{
        'the 01b/01c record folder'            = @($EO.GuardDir, 'is or holds')
        'a file in the record folder'          = @($EO.GuardState, 'is inside')
        'ProgramData'                          = @($env:ProgramData, 'is or holds')
        'the evidence folder'                  = @($EO.Evidence, 'is or holds')
        'the user profile'                     = @($env:USERPROFILE, 'is or holds')
        'the folder that holds the profiles'   = @((Split-Path -Parent $env:USERPROFILE), 'is or holds')
        'Windows'                              = @($env:windir, 'is or holds')
        'a drive root'                         = @('C:\', 'less than two folders')
        'C:\Hyper-V itself'                    = @($EO.VmParent, 'less than two folders')
        'a path with ..'                       = @('C:\Hyper-V\eo-l2\..\..\ProgramData\eo-l2', 'not in normal form')
        'a relative path'                      = @('Hyper-V\eo-l2', 'not a full path')
        'a network path'                       = @('\\server\share\Hyper-V\eo-l2', 'not a full path')
        'an empty path'                        = @('', 'not a full path')
    }
    foreach ($k in $delBad.Keys) {
        $msgs = @(); try { $msgs = @(Test-EoDeletableRoot $delBad[$k][0]) } catch { $msgs = @("threw: $($_.Exception.Message)") }
        Expect "delete guard: $k refused for its own reason" (VHit $msgs $delBad[$k][1]) $true
        if (-not (VHit $msgs $delBad[$k][1])) { $msgs | ForEach-Object { Write-Host "     $_" } }
    }
}

# The same checks on real folders in a temporary folder: junctions (no elevation
# needed) as parent, as child, dangling, inside the tree, and on the path of a delete
# (the RH-DT-M3 measurement: Remove-Item through a junction deletes the target). Only
# the temporary folder is touched; the protected-create part runs only elevated (the
# CI runner is).
& {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('eo-l2-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    # Whatever form GetFullPath gives (8.3 names on some runners), use it throughout.
    $base = [System.IO.Path]::GetFullPath($tmp).TrimEnd('\')
    $mk = { param([string]$Link, [string]$Target) Invoke-EoNative cmd.exe @('/c', 'mklink', '/J', $Link, $Target) | Out-Null }
    try {
        $victim = Join-Path $base 'victim'
        New-Item -ItemType Directory -Path (Join-Path $victim 'eo-l2') | Out-Null
        Set-Content -LiteralPath (Join-Path $victim 'keep.txt') -Value 'keep'
        Set-Content -LiteralPath (Join-Path $victim 'eo-l2\keep.txt') -Value 'keep'
        Expect 'vm live: an absent path reads as absent' ($null -eq (Get-EoEntryAttributes (Join-Path $base 'absent\deeper'))) $true
        Expect 'vm live: a real folder reads as a folder, not a link' ((Get-EoPathFacts $victim -NoAcl).Reparse) $false

        # Junction parent: <base>\HV -> victim, so <base>\HV\eo-l2 looks like a normal path.
        $hv = Join-Path $base 'HV'
        & $mk $hv $victim
        $f = Get-EoPathFacts $hv
        Expect 'vm live: a junction reads as a link, its ACL not read' "$($f.Exists)/$($f.Reparse)/$($f.Container)/$($null -eq $f.Owner)" 'True/True/True/True'
        Expect 'vm live: a junction parent fails the parent check' (VHit @(Test-EoPathFacts $f 'parent' -Container) 'is a link') $true
        $chain = @(Test-EoChainFacts @(Get-EoAncestorPaths (Join-Path $hv 'eo-l2\iso') | ForEach-Object { Get-EoPathFacts $_ -NoAcl }))
        Expect 'vm live: a junction parent is caught in the chain of a path through it' (VHit $chain "$hv is a link") $true
        Expect 'vm live: the folder seen through the junction is not itself a link (why every level is checked)' ((Get-EoPathFacts (Join-Path $hv 'eo-l2') -NoAcl).Reparse) $false

        # Junction child: <base>\P\eo-l2 -> victim.
        $p2 = Join-Path $base 'P'
        New-Item -ItemType Directory -Path $p2 | Out-Null
        $child = Join-Path $p2 'eo-l2'
        & $mk $child $victim
        Expect 'vm live: a junction child fails the root check' (VHit @(Test-EoPathFacts (Get-EoPathFacts $child) 'root' -Container) 'is a link') $true
        Expect 'vm live: a junction child is listed by name in its parent' ((@(Get-EoDirNames $p2)) -join ',') 'eo-l2'

        # A dangling junction is there, not absent (Test-Path can say otherwise).
        $dang = Join-Path $base 'dangling'
        & $mk $dang (Join-Path $base 'nothing-here')
        Expect 'vm live: a dangling junction is reported as present and a link' "$($null -ne (Get-EoEntryAttributes $dang))/$((Get-EoPathFacts $dang -NoAcl).Reparse)" 'True/True'

        # A tree with a junction inside: listed, not entered, refused, nothing deleted.
        $tree = Join-Path $base 'tree'
        New-Item -ItemType Directory -Path (Join-Path $tree 'eo-l2\Virtual Machines') | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'eo-l2-system.vhdx') -Value 'x'
        $inner = Join-Path $tree 'eo-l2\Virtual Machines\j'
        & $mk $inner $victim
        $entries = @(Get-EoTreeEntries $tree)
        Expect 'vm live: the tree listing does not enter the junction' (@($entries | Where-Object { "$($_.Rel)" -like '*keep.txt' }).Count) 0
        Expect 'vm live: the tree listing marks the junction' ((@($entries | Where-Object { $_.Reparse } | ForEach-Object { $_.Rel })) -join ',') 'eo-l2\Virtual Machines\j'
        Expect 'vm live: Test-EoVmTree refuses the nested junction' (VHit @(Test-EoVmTree $entries) 'eo-l2\Virtual Machines\j is a link') $true
        $msg = ''; try { Remove-EoVerifiedTree $tree } catch { $msg = $_.Exception.Message }
        Expect 'vm live: Remove-EoVerifiedTree refuses a tree that holds a junction' ($msg.Contains('holds links')) $true
        Expect 'vm live: ... and deletes nothing, in the tree or the target' "$(Test-Path -LiteralPath (Join-Path $tree 'eo-l2-system.vhdx'))/$(Test-Path -LiteralPath (Join-Path $victim 'keep.txt'))" 'True/True'

        # A delete through a junction above the folder (the measured RH-DT-M3 case).
        $msg = ''; try { Remove-EoVerifiedTree (Join-Path $hv 'eo-l2') } catch { $msg = $_.Exception.Message }
        Expect 'vm live: Remove-EoVerifiedTree refuses a path through a junction' ($msg.Contains("$hv is a link")) $true
        Expect 'vm live: ... and the redirected target survives' (Test-Path -LiteralPath (Join-Path $victim 'eo-l2\keep.txt')) $true
        # A delete of the junction itself.
        $msg = ''; try { Remove-EoVerifiedTree $child } catch { $msg = $_.Exception.Message }
        Expect 'vm live: Remove-EoVerifiedTree refuses a folder that is a junction' ($msg.Contains("$child is a link")) $true
        Expect 'vm live: ... and its target survives' (Test-Path -LiteralPath (Join-Path $victim 'keep.txt')) $true

        # Without the junction the same tree goes, read-only file included.
        [System.IO.Directory]::Delete($inner, $false)
        Set-Content -LiteralPath (Join-Path $tree 'eo-l2\Virtual Machines\a.vmcx') -Value 'x'
        [System.IO.File]::SetAttributes((Join-Path $tree 'eo-l2\Virtual Machines\a.vmcx'), [System.IO.FileAttributes]::ReadOnly)
        $msg = ''; try { Remove-EoVerifiedTree $tree } catch { $msg = $_.Exception.Message }
        Expect 'vm live: Remove-EoVerifiedTree deletes a tree without links' "$msg|$($null -eq (Get-EoEntryAttributes $tree))" '|True'
        Expect 'vm live: ... and the former junction target survives' (Test-Path -LiteralPath (Join-Path $victim 'keep.txt')) $true
        $msg = ''; try { Remove-EoVerifiedTree $tree } catch { $msg = $_.Exception.Message }
        Expect 'vm live: Remove-EoVerifiedTree of an absent folder does nothing' $msg ''

        if (Test-EoAdmin) {
            $sp = Join-Path $base 'HV-new'
            New-EoSecureDir $sp -Parent
            Expect 'vm live (elevated): New-EoSecureDir -Parent gives owner Administrators and the planned protected ACL' (@(Test-EoPathFacts (Get-EoPathFacts $sp) 'parent' -Container -New) -join ';') ''
            $threw = ''; try { Assert-EoNewDir $sp -Parent } catch { $threw = $_.Exception.Message }
            Expect 'vm live (elevated): Assert-EoNewDir accepts it' $threw ''
            $sr = Join-Path $sp 'eo-l2'
            New-EoSecureDir $sr
            Expect 'vm live (elevated): New-EoSecureDir gives eo-l2 Administrators and SYSTEM only, protected' (@(Test-EoPathFacts (Get-EoPathFacts $sr) 'root' -Container -New) -join ';') ''
            Set-Content -LiteralPath (Join-Path $sr 'planted.vhdx') -Value 'x'
            $threw = ''; try { Assert-EoNewDir $sr } catch { $threw = $_.Exception.Message }
            Expect 'vm live (elevated): Assert-EoNewDir refuses a folder that is not empty' ($threw.Contains('is not empty')) $true
            $threw = ''; try { New-EoSecureDir $sr } catch { $threw = $_.Exception.Message }
            Expect 'vm live (elevated): New-EoSecureDir refuses an existing folder' ($threw.Contains('already exists')) $true
            $threw = ''; try { New-EoSecureDir (Join-Path $base 'missing\eo-l2') } catch { $threw = $_.Exception.Message }
            Expect 'vm live (elevated): New-EoSecureDir refuses a missing parent' ($threw.Contains('is missing')) $true
            $threw = ''; try { New-EoSecureDir (Join-Path $hv 'new') } catch { $threw = $_.Exception.Message }
            Expect 'vm live (elevated): New-EoSecureDir refuses a parent that is a junction' ($threw.Contains('a link')) $true
            Expect 'vm live (elevated): ... and made nothing in the junction target' (Test-Path -LiteralPath (Join-Path $victim 'new')) $false
            $plain = Join-Path $base 'plain'
            New-Item -ItemType Directory -Path $plain | Out-Null
            Expect 'vm live (elevated): an ordinary New-Item folder fails the new-folder check (it inherits)' (VHit @(Test-EoPathFacts (Get-EoPathFacts $plain) 'root' -Container -New) 'inherits permissions') $true
            $msg = ''; try { Remove-EoVerifiedTree $sp } catch { $msg = $_.Exception.Message }
            Expect 'vm live (elevated): Remove-EoVerifiedTree deletes the protected folders' "$msg|$($null -eq (Get-EoEntryAttributes $sp))" '|True'
        } else {
            Write-Host 'info not elevated: the New-EoSecureDir live tests are skipped'
        }
    } finally {
        # Links first (removing a junction removes only the link), then the rest.
        if (Test-Path -LiteralPath $base) {
            foreach ($l in @(Get-EoTreeEntries $base | Where-Object { $_.Reparse })) { try { [System.IO.Directory]::Delete($l.Full, $false) } catch { Write-Host "info could not remove link $($l.Full): $($_.Exception.Message)" } }
            Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Structure of 02, undo-02 and verify-host for the VM folders.
& {
    $t = $null; $e = $null
    $ast02 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir '02-vm.ps1'), [ref]$t, [ref]$e)
    $astU = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir 'undo-02-vm.ps1'), [ref]$t, [ref]$e)
    $astV = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir 'verify-host.ps1'), [ref]$t, [ref]$e)
    $astF = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $hostDir '_vmfolder.ps1'), [ref]$t, [ref]$e)
    $cmds = { param($Ast, [string[]]$Names) @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $Names }, $true) | Sort-Object { $_.Extent.StartOffset }) }

    # The plan says what is created and with which ACL.
    $plan = @(& $cmds $ast02 @('Confirm-EoPlan'))
    $planText = if ($plan.Count) { "$($plan[0].Extent.Text)" } else { '' }
    Expect '02 plan: one Confirm-EoPlan' $plan.Count 1
    Expect '02 plan: no longer creates C:\Hyper-V with the inherited C:\ ACL' ($planText.Contains('inherits the C:\ ACL') -or $planText.Contains('exists; unchanged')) $false
    foreach ($want in @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-32-545', 'read and execute only', 'inheritance off', 'set in the create call', 'passed the check', 'is a link (reparse point)', 'deletes $($EO.Root) only')) {
        Expect "02 plan: states '$want'" ($planText.Contains($want)) $true
    }

    # 02 creates folders only through New-EoSecureDir, never New-Item or icacls grants,
    # and checks the chain right before each create, copy, New-VHD, New-VM and attach.
    Expect '02 structure: no New-Item, Remove-Item or icacls grant' "$(@(& $cmds $ast02 @('New-Item', 'Remove-Item')).Count)/$($ast02.Extent.Text.Contains('/grant'))" '0/False'
    $conf = @(& $cmds $ast02 @('Confirm-EoPlan'))[0].Extent.StartOffset
    $acts = @(& $cmds $ast02 @('New-EoSecureDir', 'Copy-Item', 'New-VHD', 'New-VM', 'Add-VMHardDiskDrive', 'Add-VMDvdDrive'))
    $asserts = @(& $cmds $ast02 @('Assert-EoVmChain') | ForEach-Object { $_.Extent.StartOffset })
    $newDir = @(& $cmds $ast02 @('Assert-EoNewDir') | ForEach-Object { $_.Extent.StartOffset })
    Expect '02 structure: 3 folder creates, 1 copy, 2 New-VHD, 1 New-VM, 3 attaches' (($acts | ForEach-Object { $_.GetCommandName() }) -join ',') 'New-EoSecureDir,New-EoSecureDir,New-EoSecureDir,Copy-Item,New-VHD,New-VHD,New-VM,Add-VMHardDiskDrive,Add-VMHardDiskDrive,Add-VMDvdDrive'
    $prev = $conf; $unguarded = @()
    foreach ($a in $acts) {
        $o = $a.Extent.StartOffset
        $attachFollow = $a.GetCommandName() -in @('Add-VMHardDiskDrive', 'Add-VMDvdDrive') -and @($acts | Where-Object { $_.Extent.StartOffset -lt $o -and $_.GetCommandName() -in @('Add-VMHardDiskDrive', 'Add-VMDvdDrive') }).Count
        if ($o -lt $conf -or (-not $attachFollow -and -not @($asserts | Where-Object { $_ -gt $prev -and $_ -lt $o }).Count)) { $unguarded += "$($a.Extent.StartLineNumber): $($a.GetCommandName())" }
        $prev = $o
    }
    Expect '02 structure: every create, copy, New-VHD, New-VM and the attaches come after the confirmation and right after a chain check' ($unguarded -join ', ') ''
    $creates = @($acts | Where-Object { $_.GetCommandName() -eq 'New-EoSecureDir' } | ForEach-Object { $_.Extent.StartOffset })
    $readBack = @(for ($i = 0; $i -lt $creates.Count; $i++) { $next = @($acts | Where-Object { $_.Extent.StartOffset -gt $creates[$i] } | Select-Object -First 1 | ForEach-Object { $_.Extent.StartOffset }); $lim = if ($next.Count) { $next[0] } else { [int]::MaxValue }; @($newDir | Where-Object { $_ -gt $creates[$i] -and $_ -lt $lim }).Count -eq 1 })
    Expect '02 structure: each folder it creates is read back before the next change' ($readBack -join ',') 'True,True,True'

    # undo-02: no Remove-Item; the tree checked before the plan, after it and after
    # Remove-VM; one Remove-EoVerifiedTree, of $EO.Root, after that last check.
    Expect 'undo-02 structure: no Remove-Item' (@(& $cmds $astU @('Remove-Item')).Count) 0
    $rt = @(& $cmds $astU @('Remove-EoVerifiedTree'))
    Expect 'undo-02 structure: one Remove-EoVerifiedTree, of $EO.Root' (($rt | ForEach-Object { "$($_.Extent.Text)" }) -join '|') 'Remove-EoVerifiedTree $EO.Root'
    $uc = @(& $cmds $astU @('Confirm-EoPlan') | ForEach-Object { $_.Extent.StartOffset })
    $chk = @(& $cmds $astU @('Get-EoVmTreeProblems') | ForEach-Object { $_.Extent.StartOffset })
    $rv = @(& $cmds $astU @('Remove-VM') | ForEach-Object { $_.Extent.StartOffset })
    $ok = $uc.Count -eq 1 -and $chk.Count -eq 3 -and $rv.Count -eq 1 -and $rt.Count -eq 1 -and $chk[0] -lt $uc[0] -and $chk[1] -gt $uc[0] -and $chk[1] -lt $rv[0] -and $chk[2] -gt $rv[0] -and $chk[2] -lt $rt[0].Extent.StartOffset
    Expect 'undo-02 structure: the tree is checked before the plan, after the confirmation and after Remove-VM, then deleted' $ok $true

    # verify-host reads the VM folders only in the full check (the VM exists).
    $vr = @(& $cmds $astV @('Get-EoVmFolderReport'))
    $gated = @($vr | Where-Object { $q = $_.Parent; $hit = $false; while ($q) { if ($q -is [System.Management.Automation.Language.IfStatementAst] -and "$($q.Clauses[0].Item1)" -eq '-not $SwitchOnly') { $hit = $true; break }; $q = $q.Parent }; $hit })
    Expect 'verify-host structure: the VM folder rows are read once, in the full check only' "$($vr.Count)/$($gated.Count)" '1/1'

    # Every call to a function returning a list is collected in @() (StrictMode, 0 or 1 results).
    $listFns = @('Test-EoPathFacts', 'Test-EoChainFacts', 'Test-EoVmTree', 'Test-EoDeletableRoot', 'Get-EoVmChainProblems', 'Get-EoVmTreeProblems', 'Get-EoTreeEntries', 'Get-EoDirNames', 'Get-EoAncestorPaths')
    foreach ($pair in @(@('02-vm.ps1', $ast02), @('undo-02-vm.ps1', $astU), @('verify-host.ps1', $astV), @('_vmfolder.ps1', $astF))) {
        $calls = @($pair[1].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $listFns }, $true))
        $bare = @($calls | Where-Object {
                $q = $_.Parent; $ok = $false
                for ($i = 0; $i -lt 12 -and $q; $i++) {
                    if ($q -is [System.Management.Automation.Language.ArrayExpressionAst]) { $ok = $true; break }
                    if ($q -is [System.Management.Automation.Language.AssignmentStatementAst] -or $q -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
                    $q = $q.Parent
                }
                -not $ok })
        Expect "vm structure: $($pair[0]) has $($calls.Count) list call(s), none outside @()" (($bare | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Extent.Text)" }) -join ' | ') ''
    }
}

if ($failures.Count) { Write-Host "$($failures.Count) failure(s)"; exit 1 }
Write-Host 'all host-script self-tests passed'
exit 0
