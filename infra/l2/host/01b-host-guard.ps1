# Step 01b (NOT YET APPROVED; run only after the owner approves it separately):
# the host guard on eo-l2-int. Turns NetBIOS over TCP/IP off on the host vNIC and
# adds outbound block rules on it for all UDP, all ICMPv4, and TCP to every port
# but 22. The host then sends the guest no name queries (LLMNR, mDNS, NetBIOS),
# no UDP broadcasts and no TCP connection but SSH (IGMP and other rare IP
# protocols are not covered), so guest root cannot answer a
# host lookup and draw a host client (and its credentials) to the guest.
# Needs an elevated PowerShell, after step 01. Undo: undo-01b-host-guard.ps1.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'host-guard'
$before = $null
try {
    $nic = Get-NetAdapter -Name $EO.HostIf -ErrorAction SilentlyContinue
    if (-not $nic) { throw "Host interface '$($EO.HostIf)' is missing; run 01-switch.ps1 first." }
    $existing = @(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue | Where-Object Name -in $EO.GuardRules)
    if ($existing.Count) { throw "Host guard rules already exist: $(($existing | ForEach-Object Name) -join ', '); stopping." }
    $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $($nic.ifIndex)"
    Confirm-EoPlan 'host-guard' @(
        "NetBIOS over TCP/IP off on '$($EO.HostIf)' (TcpipNetbiosOptions $($cfg.TcpipNetbiosOptions) -> 2)"
        "Firewall (group $($EO.FwGroup)): block outbound TCP to remote ports 1-21 and 23-65535 on '$($EO.HostIf)', all profiles"
        "Firewall (group $($EO.FwGroup)): block outbound UDP on '$($EO.HostIf)', all profiles"
        "Firewall (group $($EO.FwGroup)): block outbound ICMPv4 on '$($EO.HostIf)', all profiles"
        'SSH from the host to 192.168.250.2:22 keeps working; nothing else on the host changes'
    )
    $before = Save-EoSnapshot $stamp 'before'
    Set-Content -Encoding UTF8 -Path (Join-Path $EO.Evidence "$stamp-netbios-before.txt") -Value "$($cfg.TcpipNetbiosOptions)"

    $r = Invoke-CimMethod -InputObject $cfg -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 }
    if ($r.ReturnValue -ne 0) { throw "SetTcpipNetbios returned $($r.ReturnValue)" }
    $out = @{ Group = $EO.FwGroup; Direction = 'Outbound'; Action = 'Block'; Profile = 'Any'; Enabled = 'True'; InterfaceAlias = $EO.HostIf }
    New-NetFirewallRule @out -Name 'eo-l2-out-block-tcp' -DisplayName 'eo-l2: host sends the guest only SSH (TCP)' -Protocol TCP -RemotePort '1-21', '23-65535' | Format-List Name, Action, Direction
    New-NetFirewallRule @out -Name 'eo-l2-out-block-udp' -DisplayName 'eo-l2: host sends the guest no UDP' -Protocol UDP | Format-List Name, Action, Direction
    New-NetFirewallRule @out -Name 'eo-l2-out-block-icmp' -DisplayName 'eo-l2: host sends the guest no ICMPv4' -Protocol ICMPv4 | Format-List Name, Action, Direction

    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly
    if ($LASTEXITCODE -ne 0) { throw 'Host-side verification failed. Run undo-01b-host-guard.ps1.' }
    Write-Host 'STEP 01b DONE: host guard on eo-l2-int added and verified.'
} catch {
    Write-Host "STEP 01b STOPPED: $($_.Exception.Message)"
    if ($before) { Write-Host 'Changes may be partly made. Run undo-01b-host-guard.ps1, then fix the cause and rerun.' }
    throw
} finally {
    Stop-EoLog
}
