# Step 01 (approved change 1): the private host-only network.
# Creates the Internal switch eo-l2-int, gives its host vNIC 192.168.250.1/29 with
# file sharing, client, discovery and IPv6 bindings removed and forwarding off,
# and adds two inbound block rules in firewall group eo-l2. No NAT, no route.
# Needs an elevated PowerShell. Undo: undo-01-switch.ps1.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'switch'
$before = $null
try {
    if (Get-VMSwitch -Name $EO.SwitchName -ErrorAction SilentlyContinue) { throw "Switch $($EO.SwitchName) already exists; stopping." }
    if (Get-NetAdapter -Name $EO.HostIf -IncludeHidden -ErrorAction SilentlyContinue) { throw "A (possibly hidden) adapter named '$($EO.HostIf)' already exists; remove it in Device Manager (View > Show hidden devices) and rerun." }
    if (@(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue).Count) { throw "Firewall group $($EO.FwGroup) already has rules; stopping." }
    if (@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { Test-EoOverlap $_.IPAddress 32 }).Count) { throw 'An address inside 192.168.250.0/29 is already in use; stopping.' }

    $bindings = 'ms_msclient', 'ms_server', 'ms_lltdio', 'ms_rspndr', 'ms_lldp', 'ms_tcpip6'
    Confirm-EoPlan 'switch' @(
        "New-VMSwitch -Name $($EO.SwitchName) -SwitchType Internal"
        "Disable-NetAdapterBinding on '$($EO.HostIf)': $($bindings -join ', ')"
        "New-NetIPAddress $($EO.HostIp)/$($EO.PrefixLength) on '$($EO.HostIf)' (no gateway, DHCP off, forwarding off)"
        "Firewall (group $($EO.FwGroup)): block inbound from $($EO.SubnetLow)/$($EO.PrefixLength), all profiles"
        "Firewall (group $($EO.FwGroup)): block all inbound on '$($EO.HostIf)', all profiles"
        'No NAT, no route, no change to any existing switch, adapter, VM or firewall rule'
    )
    $before = Save-EoSnapshot $stamp 'before'

    New-VMSwitch -Name $EO.SwitchName -SwitchType Internal -Notes 'eo-l2 private host-only network; no NAT' | Format-List Name, SwitchType, Id
    # The host vNIC can take a few seconds to appear.
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Get-NetAdapter -Name $EO.HostIf -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { throw "Host interface '$($EO.HostIf)' did not appear." }
        Start-Sleep -Seconds 1
    }
    foreach ($b in $bindings) { Disable-NetAdapterBinding -Name $EO.HostIf -ComponentID $b -ErrorAction Continue }
    Set-NetIPInterface -InterfaceAlias $EO.HostIf -AddressFamily IPv4 -Dhcp Disabled -Forwarding Disabled -RouterDiscovery Disabled
    Get-NetIPAddress -InterfaceAlias $EO.HostIf -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
    New-NetIPAddress -InterfaceAlias $EO.HostIf -IPAddress $EO.HostIp -PrefixLength $EO.PrefixLength -SkipAsSource $false | Format-List IPAddress, PrefixLength, InterfaceAlias

    $fw = @{ Group = $EO.FwGroup; Direction = 'Inbound'; Action = 'Block'; Profile = 'Any'; Enabled = 'True' }
    New-NetFirewallRule @fw -Name 'eo-l2-block-guest-subnet' -DisplayName 'eo-l2: block inbound from guest subnet' -RemoteAddress "$($EO.SubnetLow)/$($EO.PrefixLength)" | Format-List Name, Action, Direction, Profile
    New-NetFirewallRule @fw -Name 'eo-l2-block-interface' -DisplayName 'eo-l2: block all inbound on eo-l2-int' -InterfaceAlias $EO.HostIf | Format-List Name, Action, Direction, Profile

    # Verify what was made, and fail if anything is not as planned.
    $ip = @(Get-NetIPAddress -InterfaceAlias $EO.HostIf)
    $ipIf = Get-NetIPInterface -InterfaceAlias $EO.HostIf -AddressFamily IPv4
    $bound = @(Get-NetAdapterBinding -Name $EO.HostIf | Where-Object { $_.ComponentID -in $bindings -and $_.Enabled })
    $routes = @(Get-NetRoute -InterfaceAlias $EO.HostIf -AddressFamily IPv4 | Where-Object DestinationPrefix -eq '0.0.0.0/0')
    $nat = @(Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $p, $l = $_.InternalIPInterfaceAddressPrefix -split '/'; Test-EoOverlap $p ([int]$l) })
    $problems = @()
    if ($ip.Count -ne 1 -or $ip[0].IPAddress -ne $EO.HostIp) { $problems += "addresses: $($ip.IPAddress -join ', ')" }
    if ($ipIf.Forwarding -ne 'Disabled') { $problems += 'forwarding enabled' }
    if ($bound.Count) { $problems += "bindings still enabled: $($bound.ComponentID -join ', ')" }
    if ($routes.Count) { $problems += 'default route on eo-l2-int' }
    if ($nat.Count) { $problems += 'NAT covers the guest subnet' }
    if (@(Get-NetFirewallRule -Group $EO.FwGroup).Count -ne 2) { $problems += 'firewall rule count is not 2' }
    Get-NetAdapterBinding -Name $EO.HostIf | Format-Table ComponentID, DisplayName, Enabled -AutoSize | Out-String | Write-Host
    $ipIf | Format-List InterfaceAlias, AddressFamily, Dhcp, Forwarding, RouterDiscovery | Out-String | Write-Host

    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if ($problems.Count) { throw "Verification failed: $($problems -join '; '). Run undo-01-switch.ps1." }
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly
    if ($LASTEXITCODE -ne 0) { throw 'Host-side switch verification failed. Run undo-01-switch.ps1.' }
    Write-Host 'STEP 01 DONE: eo-l2-int created and verified.'
} catch {
    Write-Host "STEP 01 STOPPED: $($_.Exception.Message)"
    if ($before) { Write-Host 'Changes may be partly made. Run undo-01-switch.ps1 to remove the switch and the eo-l2 rules, then fix the cause and rerun.' }
    throw
} finally {
    Stop-EoLog
}
