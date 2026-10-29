# Read-only host-side checks for B9 and the isolation boundary. Changes nothing.
# Elevated PowerShell (reads Hyper-V state). Exit code 0 when every check passes.
#   B9(1): the VM has exactly one adapter, on eo-l2-int, with the expected MAC;
#          nothing on the Default Switch or any other switch.
#   Plus: no checkpoints, checkpoints disabled, guest services/KVP/VSS off, no DVD,
#   eo-l2-int has no NAT, no default route, forwarding off, firewall rules present.
param([switch]$NoLog)

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

if (-not $NoLog) { $null = Start-EoLog 'verify-host' }
$code = 2
try {
    $rows = New-Object System.Collections.Generic.List[object]
    function Row([string]$Name, [bool]$Ok, [string]$Detail) { $rows.Add([pscustomobject]@{ Result = $(if ($Ok) { 'PASS' } else { 'FAIL' }); Check = $Name; Detail = $Detail }) }

    $vm = Get-VM -Name $EO.VmName
    $nics = @(Get-VMNetworkAdapter -VMName $EO.VmName)
    Row 'Exactly one VM network adapter' ($nics.Count -eq 1) (($nics | ForEach-Object { "$($_.Name)@$($_.SwitchName)/$($_.MacAddress)" }) -join ', ')
    Row 'Adapter is on eo-l2-int with MAC 00155DE00202' ($nics.Count -eq 1 -and $nics[0].SwitchName -eq $EO.SwitchName -and $nics[0].MacAddress -eq $EO.IntMac) ''
    Row 'No adapter on the Default Switch' (-not ($nics | Where-Object SwitchName -eq $EO.SetupSwitch)) ''
    Row 'No legacy network adapter' (@(Get-VMNetworkAdapter -VMName $EO.VmName -IsLegacy $true -ErrorAction SilentlyContinue).Count -eq 0) ''
    Row 'MAC spoofing off, DHCP and router guard on' ($nics.Count -eq 1 -and "$($nics[0].MacAddressSpoofing)" -eq 'Off' -and "$($nics[0].DhcpGuard)" -eq 'On' -and "$($nics[0].RouterGuard)" -eq 'On') ''
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
    $rules = @(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue)
    Row 'Both eo-l2 block rules present and enabled' ($rules.Count -eq 2 -and -not ($rules | Where-Object { "$($_.Enabled)" -ne 'True' -or "$($_.Action)" -ne 'Block' })) (($rules | ForEach-Object { "$($_.Name)=$($_.Enabled)/$($_.Action)" }) -join ', ')
    Row 'Checkpoints disabled' ("$($vm.CheckpointType)" -eq 'Disabled' -and -not $vm.AutomaticCheckpointsEnabled) "$($vm.CheckpointType)"
    Row 'No checkpoints exist' (@(Get-VMSnapshot -VMName $EO.VmName).Count -eq 0) ''
    $ics = @(Get-VMIntegrationService -VMName $EO.VmName | Where-Object { $_.Enabled -and $_.Name -in 'Guest Service Interface', 'Key-Value Pair Exchange', 'VSS' })
    Row 'Guest services, KVP and VSS off' ($ics.Count -eq 0) (($ics | ForEach-Object Name) -join ', ')
    Row 'No DVD drive attached' (@(Get-VMDvdDrive -VMName $EO.VmName).Count -eq 0) ''
    Row 'No passthrough or extra disks' (@(Get-VMHardDiskDrive -VMName $EO.VmName).Count -eq 2) ''
    $assigned = try { @(Get-VMAssignableDevice -VMName $EO.VmName -ErrorAction Stop).Count } catch { 0 }
    Row 'No assigned (passthrough) devices' ($assigned -eq 0) "$assigned"
    Row 'Nested virtualization off' (-not (Get-VMProcessor -VMName $EO.VmName).ExposeVirtualizationExtensions) ''

    $rows | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    Get-VMNetworkAdapter -VMName $EO.VmName | Format-List VMName, Name, SwitchName, MacAddress, Status, IPAddresses | Out-String | Write-Host
    $failed = @($rows | Where-Object Result -eq 'FAIL').Count
    Write-Host $(if ($failed) { "VERIFY-HOST FAILED: $failed check(s)." } else { 'VERIFY-HOST PASSED.' })
    $code = [int]($failed -gt 0)
} finally {
    if (-not $NoLog) { Stop-EoLog }
}
exit $code
