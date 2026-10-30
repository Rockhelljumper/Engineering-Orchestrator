# Undo step 02 (and 04): turns off and removes VM eo-l2 with all its adapters, then
# deletes C:\Hyper-V\eo-l2 (both VHDX files, the ISO and the VM configuration).
# This destroys the guest and everything in it. Needs an elevated PowerShell.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'undo-vm'
try {
    $vm = Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue
    Confirm-EoPlan 'undo-vm' @(
        $(if ($vm) { "Stop-VM $($EO.VmName) -TurnOff (state now: $($vm.State)); Remove-VM $($EO.VmName)" } else { "VM $($EO.VmName) not present" })
        "Delete $($EO.Root) and everything in it (guest disks, anchor disk, ISO, VM configuration). This cannot be undone."
        'The eo-l2-int switch and firewall rules stay; remove them with undo-01-switch.ps1'
    )
    $before = Save-EoSnapshot $stamp 'before'
    if ($vm) {
        if ($vm.State -ne 'Off') { Stop-VM -Name $EO.VmName -TurnOff -Force }
        Remove-VM -Name $EO.VmName -Force
    }
    if (Test-Path $EO.Root) { Remove-Item -LiteralPath $EO.Root -Recurse -Force }
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if (Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue) { throw 'VM still present.' }
    if (Test-Path $EO.Root) { throw "$($EO.Root) still present." }
    Write-Host 'UNDO 02 DONE: VM and its folder removed.'
} finally {
    Stop-EoLog
}
