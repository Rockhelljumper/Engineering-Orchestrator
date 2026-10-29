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
}

# Runs a native program without letting Windows PowerShell 5.1 turn its stderr
# into a terminating error. Returns all output lines as strings; throws on a
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
    return ,$out
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
# after every changing step; Compare-EoSnapshot reports every difference.
function Get-EoSnapshot {
    $s = [ordered]@{}
    $s.vmSwitches   = @(Get-VMSwitch | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; type = "$($_.SwitchType)"; adapter = $_.NetAdapterInterfaceDescription } })
    $s.vms          = @(Get-VM | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; generation = $_.Generation; cpus = $_.ProcessorCount; memoryStartup = $_.MemoryStartup; checkpointType = "$($_.CheckpointType)"; path = $_.Path } })
    $s.vmAdapters   = @(Get-VMNetworkAdapter -All | Sort-Object VMName, Name | ForEach-Object { [ordered]@{ vm = $_.VMName; name = $_.Name; switch = $_.SwitchName; mac = $_.MacAddress; managementOs = $_.IsManagementOs } })
    $s.netAdapters  = @(Get-NetAdapter -IncludeHidden | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; description = $_.InterfaceDescription; mac = $_.MacAddress } })
    $s.ipAddresses  = @(Get-NetIPAddress | Sort-Object InterfaceAlias, IPAddress | ForEach-Object { [ordered]@{ if = $_.InterfaceAlias; ip = $_.IPAddress; prefix = $_.PrefixLength } })
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
