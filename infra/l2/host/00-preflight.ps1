# Step 00: read-only preflight. Changes nothing on the host. Run it in an elevated
# PowerShell, because Get-VM and Get-VMSwitch need Hyper-V administrator rights;
# it only reads. It writes a transcript and a baseline snapshot to
# %USERPROFILE%\eo-l2-evidence. Exit code 0 means every check passed.

. (Join-Path $PSScriptRoot '_common.ps1')

$results = New-Object System.Collections.Generic.List[object]
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $r = & $Test
        $ok = [bool]$r.ok
        $detail = "$($r.detail)"
    } catch {
        $ok = $false
        $detail = "error: $($_.Exception.Message)"
    }
    $results.Add([pscustomobject]@{ Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Check = $Name; Detail = $detail })
}
function Info([string]$Name, [scriptblock]$Get) {
    try { $d = "$(& $Get)" } catch { $d = "error: $($_.Exception.Message)" }
    $results.Add([pscustomobject]@{ Result = 'INFO'; Check = $Name; Detail = $d })
}

$code = 2
$stamp = Start-EoLog 'preflight'
try {
    Check 'Elevated (read-only use)' { @{ ok = (Test-EoAdmin); detail = 'needed only to read Hyper-V state' } }

    $os = Get-CimInstance Win32_OperatingSystem
    Info 'Windows' { "$($os.Caption) build $($os.BuildNumber)" }
    Check 'Hyper-V module' { $m = Get-Module -ListAvailable Hyper-V; @{ ok = [bool]$m; detail = ($m | Select-Object -First 1).Version } }
    Check 'Hyper-V services running' {
        $s = Get-Service vmms, vmcompute
        @{ ok = -not ($s | Where-Object Status -ne 'Running'); detail = ($s | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ' ' }
    }

    # Existing resources with our names
    Check "No VM switch named $($EO.SwitchName)" { $x = Get-VMSwitch -Name $EO.SwitchName -ErrorAction SilentlyContinue; @{ ok = -not $x; detail = $(if ($x) { 'exists' } else { 'absent' }) } }
    Check "No VM named $($EO.VmName)" { $x = Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue; @{ ok = -not $x; detail = $(if ($x) { 'exists' } else { 'absent' }) } }
    Check "No folder $($EO.Root)" { @{ ok = -not (Test-Path $EO.Root); detail = $(if (Test-Path $EO.Root) { 'exists' } else { 'absent' }) } }
    Check "No firewall rules in group $($EO.FwGroup)" { $x = @(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue); @{ ok = $x.Count -eq 0; detail = "$($x.Count) rules" } }
    Check "No host interface named $($EO.HostIf)" { $x = Get-NetAdapter -Name $EO.HostIf -ErrorAction SilentlyContinue; @{ ok = -not $x; detail = $(if ($x) { 'exists' } else { 'absent' }) } }
    Check 'Planned MAC addresses unused' {
        $used = @(Get-VMNetworkAdapter -All | Where-Object { $_.MacAddress -in @($EO.IntMac, $EO.SetupMac) })
        $used += @(Get-NetAdapter -IncludeHidden | Where-Object { ($_.MacAddress -replace '-', '') -in @($EO.IntMac, $EO.SetupMac) })
        @{ ok = $used.Count -eq 0; detail = "$($used.Count) in use" }
    }
    Check "Setup switch '$($EO.SetupSwitch)' exists" { $x = Get-VMSwitch -Name $EO.SetupSwitch -ErrorAction SilentlyContinue; @{ ok = [bool]$x; detail = $(if ($x) { "$($x.SwitchType)" } else { 'absent' }) } }

    # Network conflicts with 192.168.250.0/29
    Check 'No host address inside 192.168.250.0/29' {
        $x = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { Test-EoOverlap $_.IPAddress 32 })
        @{ ok = $x.Count -eq 0; detail = ($x | ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)" }) -join ', ' }
    }
    Check 'No route overlapping 192.168.250.0/29 (default and multicast routes excepted)' {
        $x = @(Get-NetRoute -AddressFamily IPv4 | Where-Object {
                $p, $l = $_.DestinationPrefix -split '/'
                [int]$l -gt 0 -and $p -ne '255.255.255.255' -and -not $p.StartsWith('224.') -and (Test-EoOverlap $p ([int]$l))
            })
        @{ ok = $x.Count -eq 0; detail = ($x | ForEach-Object { "$($_.DestinationPrefix) via $($_.InterfaceAlias)" }) -join ', ' }
    }
    Check 'No NetNat prefix overlapping 192.168.250.0/29' {
        $x = @(Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $p, $l = $_.InternalIPInterfaceAddressPrefix -split '/'; Test-EoOverlap $p ([int]$l) })
        @{ ok = $x.Count -eq 0; detail = "$($x.Count) overlapping" }
    }
    Info 'NetNat instances (unchanged by eo-l2)' { (@(Get-NetNat -ErrorAction SilentlyContinue) | ForEach-Object { "$($_.Name)=$($_.InternalIPInterfaceAddressPrefix)" }) -join ', ' }
    Info 'Interfaces with IP forwarding enabled (unchanged by eo-l2)' { (@(Get-NetIPInterface | Where-Object Forwarding -eq 'Enabled') | ForEach-Object { "$($_.InterfaceAlias)/$($_.AddressFamily)" }) -join ', ' }
    Info 'Host-wide IPEnableRouter' { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -ErrorAction SilentlyContinue).IPEnableRouter }
    Info 'VPN adapters' { (@(Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match 'OpenVPN|TAP|PIA|WireGuard|Wintun' }) | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ' }

    # Capacity
    Check 'Free memory >= 20 GB (16 GB VM + 4 GB headroom)' { $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1); @{ ok = $free -ge 20; detail = "$free GB free of $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB" } }
    Check 'Logical processors >= 16' { $n = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors; @{ ok = $n -ge 16; detail = "$n" } }
    Check 'C: free >= 200 GB (164 GB disks + 1 GB ISO + margin)' { $v = Get-Volume -DriveLetter C; $g = [math]::Round($v.SizeRemaining / 1GB, 1); @{ ok = $g -ge 200; detail = "$g GB free, $($v.FileSystem)" } }
    Info 'Existing VMs (unchanged by eo-l2)' { (@(Get-VM) | ForEach-Object { "$($_.Name)=$($_.State)/$([math]::Round($_.MemoryAssigned / 1GB, 1))GB" }) -join ', ' }
    Info 'Hyper-V host defaults (unchanged by eo-l2)' { $h = Get-VMHost; "VMs=$($h.VirtualMachinePath) VHDs=$($h.VirtualHardDiskPath) EnhancedSession=$($h.EnableEnhancedSessionMode)" }

    # SSH and tools
    Check 'OpenSSH client present' { $s = Get-Command ssh.exe -ErrorAction SilentlyContinue; $k = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue; @{ ok = [bool]($s -and $k); detail = $(if ($s) { $s.Source } else { 'ssh.exe missing' }) } }
    Info 'OpenSSH client version' { (Invoke-EoNative ssh.exe @('-V') -AllowFail) -join ' ' }
    Check 'No existing key file eo-l2_ed25519' { @{ ok = -not (Test-Path $EO.SshKey) -and -not (Test-Path "$($EO.SshKey).pub"); detail = $EO.SshKey } }
    Check 'No "Host eo-l2" entry in ~/.ssh/config' {
        $hit = (Test-Path $EO.SshConfig) -and (Select-String -Path $EO.SshConfig -Pattern '^\s*Host\s+(.*\s)?eo-l2(\s|$)' -Quiet)
        @{ ok = -not $hit; detail = $(if (Test-Path $EO.SshConfig) { 'config exists' } else { 'no config file yet' }) }
    }
    Check 'No known_hosts_eo-l2 file' { @{ ok = -not (Test-Path $EO.SshKnown); detail = $EO.SshKnown } }
    Info 'ssh-agent service (not changed by eo-l2)' { $s = Get-Service ssh-agent -ErrorAction SilentlyContinue; if ($s) { "$($s.Status), start=$($s.StartType)" } else { 'not installed' } }
    Check 'gpg available (Git for Windows)' {
        $g = 'C:\Program Files\Git\usr\bin\gpg.exe'
        @{ ok = (Test-Path $g); detail = $(if (Test-Path $g) { ((Invoke-EoNative $g @('--version')) | Select-Object -First 1) } else { "$g missing" }) }
    }
    Info 'VS Code CLI' { $c = Get-Command code -ErrorAction SilentlyContinue; if ($c) { $c.Source } else { 'not on PATH' } }

    $results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    Save-EoSnapshot $stamp 'baseline' | Out-Null
    $failed = @($results | Where-Object Result -eq 'FAIL')
    if ($failed.Count -gt 0) {
        Write-Host "PREFLIGHT FAILED: $($failed.Count) check(s). Do not continue; nothing was changed."
        $code = 1
    } else {
        Write-Host 'PREFLIGHT PASSED. Nothing was changed.'
        $code = 0
    }
} finally {
    Stop-EoLog
}
exit $code
