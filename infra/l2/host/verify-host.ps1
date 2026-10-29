# Read-only host-side checks for B9 and the isolation boundary. Changes nothing.
# Elevated PowerShell (reads Hyper-V state). Exit code 0 when every check passes.
#   B9(1): the VM has exactly one adapter, on eo-l2-int, with the expected MAC;
#          nothing on the Default Switch or any other switch.
#   Plus: no checkpoints, checkpoints disabled, guest services/KVP/VSS off, no DVD,
#   eo-l2-int has no NAT, no default route, forwarding off, and the eo-l2 rules are
#   in the active policy with their address and interface filters, with Windows
#   Firewall on and applying local rules. -SwitchOnly runs only the switch and host
#   checks (used by 01 and 01b, before the VM exists).
param([switch]$NoLog, [switch]$SwitchOnly)

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

if (-not $NoLog) { $null = Start-EoLog 'verify-host' }
$code = 2
try {
    $rows = New-Object System.Collections.Generic.List[object]
    function Row([string]$Name, [bool]$Ok, [string]$Detail) { $rows.Add([pscustomobject]@{ Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Check = $Name; Detail = $Detail }) }

    $sw = Get-VMSwitch -Name $EO.SwitchName
    Row 'eo-l2-int is an Internal switch' ("$($sw.SwitchType)" -eq 'Internal') "$($sw.SwitchType)"
    $others = @(Get-VMNetworkAdapter -All | Where-Object { $_.SwitchName -eq $EO.SwitchName -and -not $_.IsManagementOs -and $_.VMName -ne $EO.VmName })
    Row 'No other VM on eo-l2-int' ($others.Count -eq 0) (($others | ForEach-Object VMName) -join ', ')
    $ifc = Get-NetIPInterface -InterfaceAlias $EO.HostIf -AddressFamily IPv4
    Row 'Host vNIC forwarding off' ("$($ifc.Forwarding)" -eq 'Disabled') "$($ifc.Forwarding)"
    $v6 = Get-NetAdapterBinding -Name $EO.HostIf -ComponentID ms_tcpip6
    Row 'Host vNIC IPv6 unbound' (-not $v6.Enabled) ''
    $addr = @(Get-NetIPAddress -InterfaceAlias $EO.HostIf -ErrorAction SilentlyContinue)
    Row 'Host vNIC has only 192.168.250.1/29' ($addr.Count -eq 1 -and $addr[0].IPAddress -eq $EO.HostIp -and $addr[0].PrefixLength -eq $EO.PrefixLength) (($addr | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', ')
    $nat = @(Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $p, $l = $_.InternalIPInterfaceAddressPrefix -split '/'; Test-EoOverlap $p ([int]$l) })
    Row 'No NAT covers 192.168.250.0/29' ($nat.Count -eq 0) ''
    $dr = @(Get-NetRoute -InterfaceAlias $EO.HostIf -ErrorAction SilentlyContinue | Where-Object DestinationPrefix -in '0.0.0.0/0', '::/0')
    Row 'No default route on eo-l2-int' ($dr.Count -eq 0) ''
    # Read from the active policy, so a rule that exists but is not in force fails.
    $active = @(Get-NetFirewallRule -PolicyStore ActiveStore -Group $EO.FwGroup -ErrorAction SilentlyContinue)
    $byName = @{}; foreach ($r in $active) { $byName[$r.Name] = $r }
    function RuleOk($Name, $Direction) { $r = $byName[$Name]; return [bool]($r -and "$($r.Enabled)" -eq 'True' -and "$($r.Action)" -eq 'Block' -and "$($r.Direction)" -eq $Direction -and "$($r.Profile)" -eq 'Any') }
    $sub = $byName['eo-l2-block-guest-subnet']
    $subAddr = if ($sub) { @(($sub | Get-NetFirewallAddressFilter).RemoteAddress) } else { @() }
    Row 'Rule eo-l2-block-guest-subnet in force: inbound block from 192.168.250.0/29, all profiles' ((RuleOk 'eo-l2-block-guest-subnet' 'Inbound') -and $subAddr.Count -eq 1 -and $subAddr[0] -in @('192.168.250.0/29', '192.168.250.0/255.255.255.248')) ($subAddr -join ', ')
    $ifr = $byName['eo-l2-block-interface']
    $ifAlias = if ($ifr) { @(($ifr | Get-NetFirewallInterfaceFilter).InterfaceAlias) } else { @() }
    Row "Rule eo-l2-block-interface in force: inbound block on '$($EO.HostIf)', all profiles" ((RuleOk 'eo-l2-block-interface' 'Inbound') -and $ifAlias.Count -eq 1 -and $ifAlias[0] -eq $EO.HostIf) ($ifAlias -join ', ')
    $guard = @($EO.GuardRules | Where-Object { $byName.ContainsKey($_) })
    if ($guard.Count) {
        $nb = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $((Get-NetAdapter -Name $EO.HostIf).ifIndex)").TcpipNetbiosOptions
        $guardOk = $guard.Count -eq $EO.GuardRules.Count -and -not ($EO.GuardRules | Where-Object { -not (RuleOk $_ 'Outbound') -or @(($byName[$_] | Get-NetFirewallInterfaceFilter).InterfaceAlias) -join ',' -ne $EO.HostIf })
        $tcpPorts = if ($byName['eo-l2-out-block-tcp']) { @(($byName['eo-l2-out-block-tcp'] | Get-NetFirewallPortFilter).RemotePort) -join ',' } else { '' }
        Row 'Host guard: all three outbound block rules in force on eo-l2-int; TCP leaves only port 22; NetBIOS off' ($guardOk -and $tcpPorts -eq '1-21,23-65535' -and $nb -eq 2) "rules=$($guard -join ',') tcp=$tcpPorts netbios=$nb"
    } else {
        Write-Host 'Host guard (01b) not present.'
    }
    $unexpected = @($active | Where-Object { $_.Name -notin @('eo-l2-block-guest-subnet', 'eo-l2-block-interface') + $EO.GuardRules })
    Row 'No other rules in group eo-l2' ($unexpected.Count -eq 0) (($unexpected | ForEach-Object Name) -join ', ')
    $prof = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    $badProf = @($prof | Where-Object { "$($_.Enabled)" -ne 'True' -or "$($_.DefaultInboundAction)" -notin @('Block', 'NotConfigured') -or "$($_.AllowLocalFirewallRules)" -eq 'False' })
    Row 'Windows Firewall on for every profile, inbound default Block, local rules applied' ($prof.Count -eq 3 -and $badProf.Count -eq 0) (($prof | ForEach-Object { "$($_.Name)=$($_.Enabled)/$($_.DefaultInboundAction)/$($_.AllowLocalFirewallRules)" }) -join ' ')
    $router = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -ErrorAction SilentlyContinue).IPEnableRouter
    Row 'Host-wide IP routing off (IPEnableRouter)' (-not $router) "IPEnableRouter=$router"
    if (-not $SwitchOnly) {
        $vm = Get-VM -Name $EO.VmName
        $nics = @(Get-VMNetworkAdapter -VMName $EO.VmName)
        Row 'Exactly one VM network adapter' ($nics.Count -eq 1) (($nics | ForEach-Object { "$($_.Name)@$($_.SwitchName)/$($_.MacAddress)" }) -join ', ')
        Row 'Adapter is on eo-l2-int with MAC 00155DE00202' ($nics.Count -eq 1 -and $nics[0].SwitchName -eq $EO.SwitchName -and $nics[0].MacAddress -eq $EO.IntMac) ''
        Row 'No adapter on the Default Switch' (-not ($nics | Where-Object SwitchName -eq $EO.SetupSwitch)) ''
        Row 'No legacy network adapter' (@(Get-VMNetworkAdapter -VMName $EO.VmName -IsLegacy $true -ErrorAction SilentlyContinue).Count -eq 0) ''
        Row 'MAC spoofing off, DHCP and router guard on' ($nics.Count -eq 1 -and "$($nics[0].MacAddressSpoofing)" -eq 'Off' -and "$($nics[0].DhcpGuard)" -eq 'On' -and "$($nics[0].RouterGuard)" -eq 'On') ''
        Row 'Checkpoints disabled' ("$($vm.CheckpointType)" -eq 'Disabled' -and -not $vm.AutomaticCheckpointsEnabled) "$($vm.CheckpointType)"
        Row 'No checkpoints exist' (@(Get-VMSnapshot -VMName $EO.VmName).Count -eq 0) ''
        $icsOn = @($EO.IcsOff.Keys | Where-Object { (Get-EoIntegrationService $EO.VmName $_ $EO.IcsOff[$_]).Enabled })
        Row 'Guest Service Interface, KVP and VSS off (matched by service GUID)' ($icsOn.Count -eq 0) ($icsOn -join ', ')
        Row 'No DVD drive attached' (@(Get-VMDvdDrive -VMName $EO.VmName).Count -eq 0) ''
        Row 'No passthrough or extra disks' (@(Get-VMHardDiskDrive -VMName $EO.VmName).Count -eq 2) ''
        $assigned = try { @(Get-VMAssignableDevice -VMName $EO.VmName -ErrorAction Stop).Count } catch { 0 }
        Row 'No assigned (passthrough) devices' ($assigned -eq 0) "$assigned"
        Row 'Nested virtualization off' (-not (Get-VMProcessor -VMName $EO.VmName).ExposeVirtualizationExtensions) ''
    }
    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    if (-not $SwitchOnly) { Get-VMNetworkAdapter -VMName $EO.VmName | Format-List VMName, Name, SwitchName, MacAddress, Status, IPAddresses | Out-String | Write-Host }
    $failed = @($rows | Where-Object Result -eq 'FAIL').Count
    Write-Host $(if ($failed) { "VERIFY-HOST FAILED: $failed check(s)." } else { 'VERIFY-HOST PASSED.' })
    $code = [int]($failed -gt 0)
} finally {
    if (-not $NoLog) { Stop-EoLog }
}
exit $code
