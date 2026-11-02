# Step 04a (approved change 4, first half): attach the temporary installation NIC
# eo-l2-setup to the existing Default Switch, for the attended Debian install and
# package download only. Step 04b removes it, and it must run before any eo code
# is copied into the guest. Fails closed unless the filter guard (01c) is installed
# and verified: the setup NIC is followed by 04b, whose full verification requires
# it, and the guest must not run while the segment is exposed to Npcap or
# VirtualBox. Needs an elevated PowerShell.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'add-setup-nic'
try {
    if (-not (Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue)) { throw "VM $($EO.VmName) missing; run 02-vm.ps1 first." }
    if (Get-VMNetworkAdapter -VMName $EO.VmName -Name $EO.SetupNic -ErrorAction SilentlyContinue) { throw 'Setup NIC already attached.' }
    if (-not (Get-VMSwitch -Name $EO.SetupSwitch -ErrorAction SilentlyContinue)) { throw "Switch '$($EO.SetupSwitch)' missing." }
    function Assert-FilterGuard {
        $fs = $null; $gid = $null
        try { $fs = Read-EoFilterState; $gid = Get-EoProp (Read-EoGuardState) 'instanceId' } catch { throw "Refusing 04a; nothing was changed: a guard record cannot be used ($($_.Exception.Message))." }
        $fp = @(Test-EoFilterInstalled $fs (Get-EoFilterCurrent) $gid)
        if ($fp.Count) { throw "Refusing 04a; nothing was changed: $($fp -join '; '). Run and verify 01c-filter-guard.ps1 first." }
        & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly -RequireFilterGuard
        if ($LASTEXITCODE -ne 0) { throw 'Refusing 04a; nothing was changed: verify-host.ps1 -SwitchOnly -RequireFilterGuard does not pass.' }
    }
    Assert-FilterGuard
    Confirm-EoPlan 'add-setup-nic' @(
        "Add-VMNetworkAdapter -VMName $($EO.VmName) -Name $($EO.SetupNic) -SwitchName '$($EO.SetupSwitch)' -StaticMacAddress $($EO.SetupMac)"
        'MAC spoofing off, DHCP guard on, router guard on'
        "The Default Switch itself is not modified. While this NIC exists the guest has NAT access to the host and LAN; only the Debian installer and package downloads run then"
    )
    # Checked again after the plan: the filter guard may have been undone while it waited.
    Assert-FilterGuard
    $before = Save-EoSnapshot $stamp 'before'
    Add-VMNetworkAdapter -VMName $EO.VmName -Name $EO.SetupNic -SwitchName $EO.SetupSwitch -StaticMacAddress $EO.SetupMac
    Set-VMNetworkAdapter -VMName $EO.VmName -Name $EO.SetupNic -MacAddressSpoofing Off -DhcpGuard On -RouterGuard On
    Get-VMNetworkAdapter -VMName $EO.VmName | Format-Table Name, SwitchName, MacAddress, MacAddressSpoofing, DhcpGuard, RouterGuard -AutoSize | Out-String | Write-Host
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    Write-Host 'STEP 04a DONE: temporary setup NIC attached. Remove it with 04b-remove-setup-nic.ps1 before any eo code enters the guest.'
} finally {
    Stop-EoLog
}
