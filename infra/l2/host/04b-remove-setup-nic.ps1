# Step 04b (approved change 4, mandatory second half): shut the guest down, remove
# the temporary NIC eo-l2-setup, eject the installer ISO, and verify the VM has
# exactly one adapter, on eo-l2-int. This is also the undo for step 04a.
# Needs an elevated PowerShell.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'remove-setup-nic'
try {
    $vm = Get-VM -Name $EO.VmName
    Confirm-EoPlan 'remove-setup-nic' @(
        "Stop-VM $($EO.VmName) (guest shutdown; state now: $($vm.State))"
        "Remove-VMNetworkAdapter -VMName $($EO.VmName) -Name $($EO.SetupNic)"
        'Remove the DVD drive (installer ISO) and set the first boot device to the system disk'
        'Verify: exactly one adapter, on eo-l2-int, MAC 00155DE00202; no adapter on any other switch'
    )
    $before = Save-EoSnapshot $stamp 'before'
    if ($vm.State -ne 'Off') { Stop-VM -Name $EO.VmName -Force }
    Get-VMNetworkAdapter -VMName $EO.VmName | Where-Object Name -eq $EO.SetupNic | Remove-VMNetworkAdapter
    Get-VMDvdDrive -VMName $EO.VmName | Remove-VMDvdDrive
    Set-VMFirmware -VMName $EO.VmName -FirstBootDevice (Get-VMHardDiskDrive -VMName $EO.VmName -ControllerLocation 0)
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog
    if ($LASTEXITCODE -ne 0) { throw 'Host-side adapter verification failed.' }
    Write-Host 'STEP 04b DONE: setup NIC removed and verified.'
} finally {
    Stop-EoLog
}
