# Step 04b (approved change 4, mandatory second half): remove the temporary NIC
# eo-l2-setup, eject the installer ISO, and verify the VM has exactly one adapter,
# on eo-l2-int. Run it after guest/20-seal.sh has powered the guest off; it
# refuses a running VM. -Abort (stop an unsealed guest, e.g. to abandon a failed
# install) is the undo for step 04a. Needs an elevated PowerShell.
param([switch]$Abort)

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'remove-setup-nic'
try {
    $vm = Get-VM -Name $EO.VmName
    if ($vm.State -ne 'Off' -and -not $Abort) { throw "VM is $($vm.State). Run guest/20-seal.sh, which powers the guest off, then rerun. (To abandon an unsealed install instead, rerun with -Abort.)" }
    # Boot from the guest's own "debian" entry when it exists, not the generic disk
    # entry, which needs \EFI\BOOT\BOOTX64.EFI that Debian does not install by default.
    $order = @((Get-VMFirmware -VMName $EO.VmName).BootOrder)
    $fileEntry = @($order | Where-Object { "$($_.BootType)" -eq 'File' } | Select-Object -First 1)
    Confirm-EoPlan 'remove-setup-nic' @(
        $(if ($vm.State -ne 'Off') { "Stop-VM $($EO.VmName) -Force (abort: guest is $($vm.State) and not sealed)" } else { "VM is Off (sealed by 20-seal.sh)" })
        "Remove-VMNetworkAdapter -VMName $($EO.VmName) -Name $($EO.SetupNic)"
        'Remove the DVD drive (installer ISO)'
        $(if ($fileEntry.Count) { "First boot device: the guest's '$($fileEntry[0].Description)' entry" } else { 'First boot device: the system disk (no guest boot entry found)' })
        'Verify: exactly one adapter, on eo-l2-int, MAC 00155DE00202; no adapter on any other switch'
    )
    $before = Save-EoSnapshot $stamp 'before'
    if ($vm.State -ne 'Off') { Stop-VM -Name $EO.VmName -Force }
    Get-VMNetworkAdapter -VMName $EO.VmName | Where-Object Name -eq $EO.SetupNic | Remove-VMNetworkAdapter
    Get-VMDvdDrive -VMName $EO.VmName | Remove-VMDvdDrive
    # Read the order again now the DVD and setup NIC entries are gone.
    $order = @((Get-VMFirmware -VMName $EO.VmName).BootOrder)
    $first = @($order | Where-Object { "$($_.BootType)" -eq 'File' } | Select-Object -First 1)
    if ($first.Count) { Set-VMFirmware -VMName $EO.VmName -BootOrder (@($first[0]) + @($order | Where-Object { $_ -ne $first[0] })) }
    else { Set-VMFirmware -VMName $EO.VmName -FirstBootDevice (Get-VMHardDiskDrive -VMName $EO.VmName -ControllerLocation 0) }
    (Get-VMFirmware -VMName $EO.VmName).BootOrder | Format-Table BootType, Description, Device -AutoSize | Out-String | Write-Host
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog
    if ($LASTEXITCODE -ne 0) { throw 'Host-side adapter verification failed.' }
    Write-Host 'STEP 04b DONE: setup NIC removed and verified.'
} catch {
    Write-Host "STEP 04b STOPPED: $($_.Exception.Message)"
    Write-Host 'Do not start the guest. Check Get-VMNetworkAdapter -VMName eo-l2 and rerun this step (it is safe to repeat) until VERIFY-HOST PASSED.'
    throw
} finally {
    Stop-EoLog
}
