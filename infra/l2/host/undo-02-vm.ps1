# Undo step 02 (and 04): turns off and removes VM eo-l2 with all its adapters, then
# deletes C:\Hyper-V\eo-l2 (both VHDX files, the ISO and the VM configuration).
# This destroys the guest and everything in it. Needs an elevated PowerShell.
#
# It deletes nothing it has not checked (rules in _vmfolder.ps1): before the plan,
# again after the typed confirmation, and again after Remove-VM, no folder from C:\
# down to C:\Hyper-V\eo-l2\iso may be a link (reparse point), C:\Hyper-V must be
# owned by an administrator with no write-class right for any other account, eo-l2
# and iso must be Administrators and SYSTEM only, and eo-l2 may hold only what 02 and
# Hyper-V put there, with no link anywhere inside. Otherwise it stops before any
# change (or before the delete) and says what it found. The delete itself goes entry
# by entry, deepest first, re-checking each entry and every folder above it for a
# link right before each call (Remove-EoVerifiedTree), never a recursive Remove-Item
# on a path string, which follows a junction above it. C:\Hyper-V itself stays: it is
# admin-protected and may hold other VMs; 02 accepts it again when rerun.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'undo-vm'
try {
    $refuse = 'Nothing was changed. Investigate who made or changed these folders before deleting anything by hand; do not delete through a link.'
    $treeBad = @(Get-EoVmTreeProblems)
    if ($treeBad.Count) { throw "Refusing undo 02: $($treeBad -join '; '). $refuse" }
    $vm = Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue
    $rootThere = $null -ne (Get-EoEntryAttributes $EO.Root)
    Confirm-EoPlan 'undo-vm' @(
        $(if ($vm) { "Stop-VM $($EO.VmName) -TurnOff (state now: $($vm.State)); Remove-VM $($EO.VmName)" } else { "VM $($EO.VmName) not present" })
        $(if ($rootThere) { "Delete $($EO.Root) and everything in it (guest disks, anchor disk, ISO, VM configuration). This cannot be undone." } else { "$($EO.Root) not present" })
        "Checked now, again after you confirm and again after Remove-VM: no link (reparse point) from C:\ down to $($EO.IsoDir); $($EO.VmParent) owned by an administrator with no write right for others; $($EO.Root) and its iso folder Administrators and SYSTEM only; $($EO.Root) holding only the two VHDX files, iso\*.iso and the VM configuration, with no link inside. The undo stops if any check fails"
        "Delete entry by entry, deepest first, each entry and the folders above it re-checked for a link right before it is deleted; folders only when empty"
        "$($EO.VmParent) stays (admin-protected; it may hold other VMs)"
        'The eo-l2-int switch and firewall rules stay; remove them with undo-01-switch.ps1'
    )
    $treeBad = @(Get-EoVmTreeProblems)
    if ($treeBad.Count) { throw "Refusing undo 02 after the confirmation: $($treeBad -join '; '). $refuse" }
    $before = Save-EoSnapshot $stamp 'before'
    if ($vm) {
        if ($vm.State -ne 'Off') { Stop-VM -Name $EO.VmName -TurnOff -Force }
        Remove-VM -Name $EO.VmName -Force
    }
    $treeBad = @(Get-EoVmTreeProblems)
    if ($treeBad.Count) { throw "Refusing to delete $($EO.Root) (the VM is removed, its folder is not): $($treeBad -join '; '). Investigate before deleting anything by hand; do not delete through a link." }
    Remove-EoVerifiedTree $EO.Root
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if (Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue) { throw 'VM still present.' }
    if ($null -ne (Get-EoEntryAttributes $EO.Root)) { throw "$($EO.Root) still present." }
    Write-Host "UNDO 02 DONE: VM and its folder removed; $($EO.VmParent) left in place."
} finally {
    Stop-EoLog
}
