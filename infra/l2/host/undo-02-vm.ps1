# Undo step 02 (and 04): turns off and removes VM eo-l2 with all its adapters, then
# deletes C:\Hyper-V\eo-l2 (both VHDX files, the ISO and the VM configuration).
# This destroys the guest and everything in it. Needs an elevated PowerShell.
#
# It deletes nothing it has not checked (rules in _vmfolder.ps1). The order:
#   1. before the plan: no folder from C:\ down to C:\Hyper-V\eo-l2\iso is a link
#      (reparse point); the VM id comes from Hyper-V, or, when the VM is gone, from the
#      eo-l2.vmid record 02 wrote (they must agree when both exist); C:\Hyper-V is owned
#      by an administrator with no write-class right for any other account; eo-l2 and
#      iso are Administrators and SYSTEM only (this VM's own account read at most); eo-l2
#      holds only what 02 and Hyper-V put there, with no link anywhere inside. A running
#      VM's runtime folder (Virtual Machines\<id>) may be unreadable here: it is listed
#      in the plan, not entered, and checked in step 4;
#   2. after the typed confirmation: the same checks again, and the plan must still be
#      true (the VM and the folder present or absent as planned, the same VM id);
#      otherwise it stops, to be run again for a new plan;
#   3. Stop-VM -TurnOff, Remove-VM;
#   4. the full strict check of eo-l2, now with every folder readable;
#   5. the delete: entry by entry, deepest first, each entry and every folder above it
#      re-checked for a link right before its call (Remove-EoVerifiedTree), never a
#      recursive Remove-Item on a path string, which follows a junction above it.
# Any failed check stops it (before any change in 1 and 2, before the delete in 4),
# prints the actual ACLs and says what it found; README "Recovering from a refused
# undo-02" is the attended manual procedure. C:\Hyper-V itself stays: it is
# admin-protected and may hold other VMs; 02 accepts it again when rerun.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

# What the plan rests on: the VM, the root and the VM id (from Hyper-V when the VM
# exists, else from 02's record; a disagreement between the two throws).
function Get-EoUndoView {
    $chain = @(Get-EoChainProblems $EO.IsoDir)
    if ($chain.Count) { throw "Refusing undo 02: $($chain -join '; ')." }
    $vm = Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue
    $recorded = Read-EoVmIdFile
    $id = if ($vm) { ([guid]"$($vm.Id)").ToString() } else { $recorded }
    if ($vm -and $recorded -and $recorded -ne $id) { throw "Refusing undo 02: $($EO.VmIdFile) records VM id $recorded, but VM $($EO.VmName) has id $id." }
    return @{ Vm = $vm; VmPresent = [bool]$vm; RootPresent = ($null -ne (Get-EoEntryAttributes $EO.Root)); VmId = $id }
}

$stamp = Start-EoLog 'undo-vm'
try {
    $refuse = 'Nothing was changed. Investigate who made or changed these folders; to clean up by hand follow README "Recovering from a refused undo-02" (attended; never delete through a link).'
    try { $plan = Get-EoUndoView } catch { Show-EoVmFolderAcls; throw "$($_.Exception.Message) $refuse" }
    $treeBad = @(Get-EoVmTreeProblems $plan.VmId -AllowUnreadable)
    if ($treeBad.Count) { Show-EoVmFolderAcls; throw "Refusing undo 02: $($treeBad -join '; '). $refuse" }
    $unread = @(if ($plan.RootPresent) { Get-EoTreeEntries $EO.Root -Tolerant | Where-Object { $_.Unreadable } | ForEach-Object { $_.Full } })
    $vm = $plan.Vm
    Confirm-EoPlan 'undo-vm' @(
        $(if ($vm) { "Stop-VM $($EO.VmName) -TurnOff (state now: $($vm.State)); Remove-VM $($EO.VmName) (id $($plan.VmId))" } else { "VM $($EO.VmName) not present$(if ($plan.VmId) { " (02 recorded id $($plan.VmId))" })" })
        $(if ($plan.RootPresent) { "Delete $($EO.Root) and everything in it (guest disks, anchor disk, ISO, VM configuration, $(Split-Path -Leaf $EO.VmIdFile)). This cannot be undone." } else { "$($EO.Root) not present" })
        "Checked now and again after you confirm: no link (reparse point) from C:\ down to $($EO.IsoDir); $($EO.VmParent) owned by an administrator with no write right for others; $($EO.Root) and its iso folder Administrators and SYSTEM only (this VM's own account read at most); $($EO.Root) holding only the two VHDX files, $(Split-Path -Leaf $EO.VmIdFile), iso\*.iso and the VM configuration, with no link inside. After you confirm, the VM and the folder must still be as listed here"
        $(if ($unread.Count) { "Not readable while the VM runs, so not checked yet: $($unread -join ', '). Checked after Remove-VM" } else { 'Every folder under the root was readable and checked' })
        "After Stop-VM and Remove-VM: the full check again, every folder readable, before anything is deleted. The undo stops if any check fails"
        "Delete entry by entry, deepest first, each entry and the folders above it re-checked for a link right before it is deleted; folders only when empty"
        "$($EO.VmParent) stays (admin-protected; it may hold other VMs)"
        'The eo-l2-int switch and firewall rules stay; remove them with undo-01-switch.ps1'
    )
    # The plan the operator confirmed must still be what happens.
    try { $now = Get-EoUndoView } catch { Show-EoVmFolderAcls; throw "$($_.Exception.Message) (after the confirmation) $refuse" }
    $changed = @(Test-EoUndoPlanStill $plan $now)
    if ($changed.Count) { throw "Refusing undo 02 after the confirmation: what is there is not what the plan showed ($($changed -join '; ')). Nothing was changed; run undo-02-vm.ps1 again for a new plan." }
    $treeBad = @(Get-EoVmTreeProblems $now.VmId -AllowUnreadable)
    if ($treeBad.Count) { Show-EoVmFolderAcls; throw "Refusing undo 02 after the confirmation: $($treeBad -join '; '). $refuse" }
    $before = Save-EoSnapshot $stamp 'before'
    if ($now.VmPresent) {
        if ((Get-VM -Name $EO.VmName).State -ne 'Off') { Stop-VM -Name $EO.VmName -TurnOff -Force }
        Remove-VM -Name $EO.VmName -Force
    }
    if (Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue) { throw 'VM still present after Remove-VM; nothing was deleted.' }
    # Strict now: the VM is off and removed, so every folder must be readable and pass,
    # and every entry's ACL must leave writing to Administrators, SYSTEM and the VM's account.
    $treeBad = @(Get-EoVmTreeProblems $now.VmId -Acls)
    if ($treeBad.Count) { Show-EoVmFolderAcls; throw "Refusing to delete $($EO.Root) (the VM is removed, its folder is not): $($treeBad -join '; '). Nothing was deleted; follow README `"Recovering from a refused undo-02`" (attended; never delete through a link)." }
    Remove-EoVerifiedTree $EO.Root
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if ($null -ne (Get-EoEntryAttributes $EO.Root)) { throw "$($EO.Root) still present." }
    Write-Host "UNDO 02 DONE: VM and its folder removed; $($EO.VmParent) left in place."
} finally {
    Stop-EoLog
}
