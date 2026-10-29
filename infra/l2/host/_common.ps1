# Shared settings and helpers for the eo-l2 host scripts. Dot-sourced by every
# script in this folder; it changes nothing on its own.
#
# Target: Windows PowerShell 5.1 or PowerShell 7 on Windows 11 with Hyper-V.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$EO = [ordered]@{
    SwitchName   = 'eo-l2-int'
    HostIf       = 'vEthernet (eo-l2-int)'
    HostIp       = '192.168.250.1'
    GuestIp      = '192.168.250.2'
    PrefixLength = 29
    SubnetLow    = '192.168.250.0'
    SubnetHigh   = '192.168.250.7'
    FwGroup      = 'eo-l2'
    VmName       = 'eo-l2'
    Root         = 'C:\Hyper-V\eo-l2'
    IsoDir       = 'C:\Hyper-V\eo-l2\iso'
    SystemVhd    = 'C:\Hyper-V\eo-l2\eo-l2-system.vhdx'
    AnchorVhd    = 'C:\Hyper-V\eo-l2\eo-l2-anchor.vhdx'
    SystemBytes  = 160GB
    AnchorBytes  = 4GB
    MemoryBytes  = 16GB
    Cpus         = 8
    IntNic       = 'eo-l2-int'
    IntMac       = '00155DE00202'
    SetupNic     = 'eo-l2-setup'
    SetupMac     = '00155DE00299'
    SetupSwitch  = 'Default Switch'
    # Standard-user locations (not admin-only), so the attended session can read them.
    Download     = Join-Path $env:USERPROFILE 'Downloads\eo-l2-iso'
    Evidence     = Join-Path $env:USERPROFILE 'eo-l2-evidence'
    SshDir       = Join-Path $env:USERPROFILE '.ssh'
    SshKey       = Join-Path $env:USERPROFILE '.ssh\eo-l2_ed25519'
    SshConfig    = Join-Path $env:USERPROFILE '.ssh\config'
    SshKnown     = Join-Path $env:USERPROFILE '.ssh\known_hosts_eo-l2'
    # Debian CD signing key (https://www.debian.org/CD/verify). The signature on
    # SHA256SUMS must come from one of these primary key fingerprints.
    DebianCdKeys = @('DF9B9C49EAA9298432589D76DA87E80D6294BE9B')
    # Hyper-V integration services by their fixed service GUIDs (the last part of
    # each Get-VMIntegrationService Id), so the steps also work on a localized Windows.
    IcsOff       = [ordered]@{ 'Guest Service Interface' = '6C09BB55-D683-4DA0-8931-C9BF705F6480'; 'Key-Value Pair Exchange' = '2A34B1C2-FD73-4043-8A5B-DD2159BC743F'; 'VSS' = '5CED1297-4598-4915-A5FC-AD21BB4D02A4' }
    IcsOn        = [ordered]@{ 'Heartbeat' = '84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47'; 'Shutdown' = '9F8233AC-BE49-4C79-8EE3-E7E1985B2077'; 'Time Synchronization' = '2497F4DE-E9FA-4204-80E4-4B75C46419C0' }
    # Optional host guard (only with the owner's approval; see README): NetBIOS off on
    # the host vNIC, and the host may send the guest nothing but SSH.
    GuardRules   = @('eo-l2-out-block-tcp', 'eo-l2-out-block-udp', 'eo-l2-out-block-icmp')
    # What 01b changed, written before it changes anything; the undo needs it.
    GuardState   = Join-Path $env:USERPROFILE 'eo-l2-evidence\host-guard-state.json'
}

. (Join-Path $PSScriptRoot '_guard.ps1')

# The VM's integration service with this GUID, matched on the Id's GUID part and
# falling back to the English name. Throws when neither matches.
function Get-EoIntegrationService([string]$VmName, [string]$Name, [string]$Guid) {
    $all = @(Get-VMIntegrationService -VMName $VmName)
    $hit = @($all | Where-Object { "$($_.Id)" -match "$([regex]::Escape($Guid))$" })
    if (-not $hit.Count) { $hit = @($all | Where-Object Name -eq $Name) }
    if ($hit.Count -ne 1) { throw "Integration service '$Name' ($Guid) not found on $VmName (found: $(($all | ForEach-Object { "$($_.Name)=$($_.Id)" }) -join ', '))" }
    return $hit[0]
}

# Runs a native program without letting Windows PowerShell 5.1 turn its stderr
# into a terminating error. Writes each output line to the pipeline as a string,
# so a filter after it sees lines; wrap the call in @() for an array. Throws on a
# non-zero exit code unless -AllowFail.
function Invoke-EoNative([string]$Exe, [string[]]$Arguments, [switch]$AllowFail) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0 -and -not $AllowFail) { throw "$Exe exited with $code`n$($out -join "`n")" }
    $out
}

# Verifies that $Sign is a good signature over $Sums by a key whose primary
# fingerprint is in $EO.DebianCdKeys, using only the key in $KeyFile, in a
# throwaway gpg home that is removed afterwards. Returns the primary fingerprint;
# throws otherwise. Used by 03 (after download) and again by 02 (elevated).
function Assert-EoDebianSignature([string]$Sums, [string]$Sign, [string]$KeyFile) {
    $gpg = 'C:\Program Files\Git\usr\bin\gpg.exe'
    $gpgconf = 'C:\Program Files\Git\usr\bin\gpgconf.exe'
    if (-not (Test-Path $gpg)) { throw "gpg not found at $gpg" }
    $home_ = Join-Path ([IO.Path]::GetTempPath()) ("eo-l2-gnupg-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $home_ | Out-Null
    # gpg from Git for Windows takes MSYS-style paths.
    $msys = { param($p) $p -replace '^([A-Za-z]):', '/$1' -replace '\\', '/' }
    $gh = & $msys $home_
    $statusFile = Join-Path $home_ 'status.txt'
    try {
        Invoke-EoNative $gpg @('--homedir', $gh, '--batch', '--quiet', '--import', (& $msys $KeyFile)) | Write-Host
        $fprs = @(Invoke-EoNative $gpg @('--homedir', $gh, '--batch', '--with-colons', '--fingerprint') | Where-Object { $_ -like 'fpr:*' } | ForEach-Object { ($_ -split ':')[9] })
        Write-Host "imported fingerprints: $($fprs -join ', ')"
        Invoke-EoNative $gpg @('--homedir', $gh, '--batch', '--status-file', (& $msys $statusFile), '--verify', (& $msys $Sign), (& $msys $Sums)) -AllowFail | Write-Host
        $status = @(Get-Content $statusFile)
        $status | Write-Host
        $valid = @($status | Where-Object { $_ -match '^\[GNUPG:\] VALIDSIG ' })
        if ($valid.Count -ne 1) { throw 'SHA256SUMS signature did not verify (no single VALIDSIG).' }
        # VALIDSIG <signing-key-fpr> ... <primary-key-fpr>: the primary is the last field.
        $primary = ($valid[0] -split ' ')[-1]
        if ($primary -notin $EO.DebianCdKeys) { throw "Signature is valid but from $primary, which is not an expected Debian CD key. Compare with https://www.debian.org/CD/verify before going on." }
        if (-not ($status | Where-Object { $_ -match '^\[GNUPG:\] GOODSIG ' })) { throw 'No GOODSIG status.' }
        Write-Host "SIGNATURE OK: primary key $primary"
        return $primary
    } finally {
        # gpg 2.4 may leave an agent or keyboxd running in the home; stop them first.
        if (Test-Path $gpgconf) { Invoke-EoNative $gpgconf @('--homedir', $gh, '--kill', 'all') -AllowFail | Out-Null }
        Remove-Item -Recurse -Force $home_ -ErrorAction SilentlyContinue
        if (Test-Path $home_) { Write-Host "note: could not remove $home_; delete it by hand" }
    }
}

function Test-EoAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-EoAdmin {
    if (-not (Test-EoAdmin)) { throw 'This step needs an elevated PowerShell (Run as administrator). Nothing was changed.' }
}

function Assert-EoNotAdmin {
    if (Test-EoAdmin) { throw 'Run this step from a normal (not elevated) PowerShell. Nothing was changed.' }
}

function Start-EoLog([string]$Step) {
    New-Item -ItemType Directory -Force -Path $EO.Evidence | Out-Null
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $path = Join-Path $EO.Evidence "$stamp-$Step.transcript.txt"
    Start-Transcript -Path $path | Out-Null
    Write-Host "eo-l2 step: $Step"
    Write-Host "transcript: $path"
    Write-Host "user: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)  elevated: $(Test-EoAdmin)"
    Write-Host "time (UTC): $((Get-Date).ToUniversalTime().ToString('o'))"
    Write-Host "script: $($MyInvocation.PSCommandPath)"
    return $stamp
}

function Stop-EoLog { try { Stop-Transcript | Out-Null } catch { } }

# Print the plan, then require the operator to type the step name. Anything else
# aborts before a change is made.
function Confirm-EoPlan([string]$Step, [string[]]$Lines) {
    Write-Host ''
    Write-Host "=== Planned changes for step '$Step' ==="
    foreach ($l in $Lines) { Write-Host "  - $l" }
    Write-Host '==='
    $answer = Read-Host "Type '$Step' to make these changes, anything else to stop"
    if ($answer -cne $Step) { throw "Not confirmed; step '$Step' stopped before any change." }
}

# A JSON snapshot of the host state the steps must not disturb. Taken before and
# after every changing host step (01, 01b, 02, 04a, 04b and the undos; 03 and 05
# change only files in the user profile); Compare-EoSnapshot prints every
# difference for the operator to read.
function Get-EoSnapshot {
    $s = [ordered]@{}
    $s.vmSwitches   = @(Get-VMSwitch | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; type = "$($_.SwitchType)"; adapter = $_.NetAdapterInterfaceDescription } })
    $s.vms          = @(Get-VM | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; generation = $_.Generation; cpus = $_.ProcessorCount; memoryStartup = $_.MemoryStartup; checkpointType = "$($_.CheckpointType)"; path = $_.Path } })
    $s.vmAdapters   = @(Get-VMNetworkAdapter -All | Sort-Object VMName, Name | ForEach-Object { [ordered]@{ vm = $_.VMName; name = $_.Name; switch = $_.SwitchName; mac = $_.MacAddress; managementOs = $_.IsManagementOs } })
    $s.netAdapters  = @(Get-NetAdapter -IncludeHidden | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; description = $_.InterfaceDescription; mac = $_.MacAddress } })
    $s.ipAddresses  = @(Get-NetIPAddress | Sort-Object InterfaceAlias, IPAddress | ForEach-Object { [ordered]@{ if = $_.InterfaceAlias; ip = $_.IPAddress; prefix = $_.PrefixLength } })
    $s.routes       = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -notlike '224.*' -and $_.DestinationPrefix -ne '255.255.255.255/32' } | Sort-Object DestinationPrefix, InterfaceAlias | ForEach-Object { "$($_.DestinationPrefix) via $($_.NextHop) on $($_.InterfaceAlias)" })
    $s.forwarding   = @(Get-NetIPInterface | Where-Object Forwarding -eq 'Enabled' | Sort-Object InterfaceAlias, AddressFamily | ForEach-Object { "$($_.InterfaceAlias)/$($_.AddressFamily)" })
    $s.nat          = @(Get-NetNat -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; prefix = $_.InternalIPInterfaceAddressPrefix } })
    $rules          = @(Get-NetFirewallRule | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.Enabled)|$($_.Action)|$($_.Direction)|$($_.Profile)" })
    $sha            = [Security.Cryptography.SHA256]::Create()
    $s.firewall     = [ordered]@{ count = $rules.Count; sha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rules -join "`n")))) -replace '-', '').ToLower(); eoRules = @(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue | ForEach-Object { $_.DisplayName }) }
    $s.services     = @(Get-Service -Name vmms, vmcompute, HvHost, LxssManager, WSLService, com.docker.service, VBoxSDS, ssh-agent -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; status = "$($_.Status)"; start = "$($_.StartType)" } })
    $s.vmHost       = [ordered]@{ enhancedSession = (Get-VMHost).EnableEnhancedSessionMode; vhdPath = (Get-VMHost).VirtualHardDiskPath; vmPath = (Get-VMHost).VirtualMachinePath }
    return $s
}

function Save-EoSnapshot([string]$Stamp, [string]$Label) {
    $path = Join-Path $EO.Evidence "$Stamp-$Label.snapshot.json"
    Get-EoSnapshot | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $path
    Write-Host "snapshot: $path"
    return $path
}

# Lists every line that differs between two snapshots, so the operator sees that
# only the eo-l2 resources changed.
function Compare-EoSnapshot([string]$Before, [string]$After) {
    $a = (Get-Content $Before -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 6) -split "`r?`n"
    $b = (Get-Content $After -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 6) -split "`r?`n"
    $d = Compare-Object $a $b
    Write-Host ''
    Write-Host '=== Host state differences (<= before only, => after only) ==='
    if (-not $d) { Write-Host '  (none)' }
    foreach ($x in $d) { Write-Host "  $($x.SideIndicator) $($x.InputObject.Trim())" }
    Write-Host '==='
}

function ConvertTo-EoUInt32([string]$Ip) {
    $b = ([Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    [Array]::Reverse($b)
    return [BitConverter]::ToUInt32($b, 0)
}

# True when the IPv4 prefix a.b.c.d/len overlaps 192.168.250.0/29.
function Test-EoOverlap([string]$Ip, [int]$Len) {
    $lo = ConvertTo-EoUInt32 $EO.SubnetLow
    $hi = ConvertTo-EoUInt32 $EO.SubnetHigh
    $n = ConvertTo-EoUInt32 $Ip
    $size = [uint64]1 -shl (32 - $Len)
    $start = [uint64]$n - ([uint64]$n % $size)
    $end = $start + $size - 1
    return ($start -le $hi -and $end -ge $lo)
}

# "a.b.c.d/len" of the network that holds Ip.
function Get-EoNetwork([string]$Ip, [int]$Len) {
    $n = [uint64](ConvertTo-EoUInt32 $Ip)
    $size = [uint64]1 -shl (32 - $Len)
    $net = $n - ($n % $size)
    $b = [BitConverter]::GetBytes([uint32]$net)
    [Array]::Reverse($b)
    return "$([Net.IPAddress]::new($b))/$Len"
}

# True when an OpenSSH private key file is passphrase-protected. The key format
# records its cipher and KDF ("none"/"none" without a passphrase, a cipher and
# "bcrypt" with one). Parsed directly because Windows PowerShell 5.1 drops
# empty-string arguments, so "ssh-keygen -y -P ''" cannot be relied on.
function Test-EoKeyEncrypted([string]$Path) {
    $b64 = (Get-Content $Path | Where-Object { $_ -notmatch '^-----' }) -join ''
    $raw = [Convert]::FromBase64String($b64)
    $magic = [Text.Encoding]::ASCII.GetBytes("openssh-key-v1`0")
    for ($i = 0; $i -lt $magic.Length; $i++) { if ($raw[$i] -ne $magic[$i]) { throw "$Path is not an OpenSSH private key" } }
    $off = $magic.Length
    $fields = @()
    foreach ($k in 1, 2) {
        $n = ([int]$raw[$off] -shl 24) -bor ([int]$raw[$off + 1] -shl 16) -bor ([int]$raw[$off + 2] -shl 8) -bor [int]$raw[$off + 3]
        $fields += [Text.Encoding]::ASCII.GetString($raw, $off + 4, $n)
        $off += 4 + $n
    }
    return ($fields[0] -ne 'none' -and $fields[1] -eq 'bcrypt')
}
