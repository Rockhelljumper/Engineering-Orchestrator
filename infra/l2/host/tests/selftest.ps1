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
        Expect "rules: $n altered $k fails" (@(Test-EoRuleFacts $n $f $spec).Count -gt 0) $true
    }
}
# The same rules as the firewall cmdlets report them.
$hostIf = $EO.HostIf
$realTcp = @{ Present = $true; PrimaryStatus = 'OK'; Enabled = 'True'; Action = 'Block'; Direction = 'Outbound'; Profile = 'Any'; Protocol = 'TCP'
    LocalPort = @('Any'); RemotePort = @('23-65535', '1-21'); IcmpType = @('Any'); RemoteAddress = @('Any'); LocalAddress = @('Any')
    InterfaceAlias = @($hostIf); InterfaceType = 'Any'; Program = 'Any'; Service = 'Any' }
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
}
foreach ($v in $variants.Keys) {
    $f = $realTcp.Clone(); foreach ($k in $variants[$v].Keys) { $f[$k] = $variants[$v][$k] }
    Expect "rules: TCP guard $v fails" (@(Test-EoRuleFacts 'tcp' $f $tcpSpec).Count -gt 0) $true
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
    'no record'                            = @($null, (Cur @{}))
    'record without netbiosBefore'         = @((StateWith '"netbiosBefore": 0, ' ''), (Cur @{}))
    'netbiosBefore as a string'            = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": "0"'), (Cur @{}))
    'netbiosBefore null'                   = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": null'), (Cur @{}))
    'netbiosBefore 3'                      = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": 3'), (Cur @{}))
    'netbiosBefore -1'                     = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": -1'), (Cur @{}))
    'netbiosBefore 1.5'                    = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": 1.5'), (Cur @{}))
    'netbiosBefore as a list'              = @((StateWith '"netbiosBefore": 0' '"netbiosBefore": [0, 2]'), (Cur @{}))
    'another schema'                       = @((StateWith 'eo-l2-host-guard/1' 'eo-l2-host-guard/0'), (Cur @{}))
    'malformed instance id'                = @((StateWith '0123456789abcdef0123456789abcdef' 'not-an-id'), (Cur @{}))
    'another computer'                     = @((StateWith """computer"": ""$env:COMPUTERNAME""" '"computer": "OTHER-PC"'), (Cur @{}))
    'another provisioning (switch id)'     = @(($goodJson | ConvertFrom-Json), (Cur @{ SwitchId = '99999999-2222-3333-4444-555555555555' }))
    'another adapter (GUID)'               = @(($goodJson | ConvertFrom-Json), (Cur @{ Adapter = @{ InterfaceGuid = '{00000000-0000-4000-8000-000000000001}'; MacAddress = '00-15-5D-AA-BB-CC'; SettingId = $guid } }))
    'another adapter (MAC)'                = @(($goodJson | ConvertFrom-Json), (Cur @{ Adapter = @{ InterfaceGuid = $guid; MacAddress = '00-15-5D-00-00-01'; SettingId = $guid } }))
    'another adapter (setting id)'         = @(($goodJson | ConvertFrom-Json), (Cur @{ Adapter = @{ InterfaceGuid = $guid; MacAddress = '00-15-5D-AA-BB-CC'; SettingId = '{00000000-0000-4000-8000-000000000002}' } }))
    'record without the adapter GUID'      = @((StateWith """interfaceGuid"": ""$guid"", " ''), (Cur @{}))
    'switch present, adapter missing'      = @(($goodJson | ConvertFrom-Json), (Cur @{ Adapter = $null }))
    'rule from another instance'           = @(($goodJson | ConvertFrom-Json), (Cur @{ RuleDescriptions = @{ 'eo-l2-out-block-tcp' = (Get-EoGuardInstanceTag 'ffffffffffffffffffffffffffffffff') } }))
    'rule with no instance tag'            = @(($goodJson | ConvertFrom-Json), (Cur @{ RuleDescriptions = @{ 'eo-l2-out-block-udp' = '' } }))
}
foreach ($k in $bad.Keys) {
    $threw = $false; $n = 0
    try { $n = @(Test-EoGuardState $bad[$k][0] $bad[$k][1]).Count } catch { $threw = $true }
    Expect "guard state: $k refused" ($n -gt 0 -and -not $threw) $true
}

if ($failures.Count) { Write-Host "$($failures.Count) failure(s)"; exit 1 }
Write-Host 'all host-script self-tests passed'
exit 0
