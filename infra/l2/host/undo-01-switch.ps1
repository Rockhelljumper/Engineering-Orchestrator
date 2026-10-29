# Undo step 01: removes the eo-l2 firewall rules and the eo-l2-int switch (which
# also removes its host vNIC and address). Refuses while any VM adapter is still
# connected to the switch. Needs an elevated PowerShell.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'undo-switch'
try {
    $attached = @(Get-VMNetworkAdapter -All | Where-Object { $_.SwitchName -eq $EO.SwitchName -and -not $_.IsManagementOs })
    if (Test-Path -LiteralPath $EO.GuardState) { throw "The host guard (01b) is still recorded in $($EO.GuardState). Run undo-01b-host-guard.ps1 first, so NetBIOS is restored from its record." }
    if ($attached.Count) { throw "VM adapters still on $($EO.SwitchName): $($attached | ForEach-Object { "$($_.VMName)/$($_.Name)" }). Run undo-02-vm.ps1 first." }
    Confirm-EoPlan 'undo-switch' @(
        "Remove-NetFirewallRule -Group $($EO.FwGroup) ($(@(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue).Count) rules)"
        "Remove-VMSwitch -Name $($EO.SwitchName) (removes '$($EO.HostIf)' and $($EO.HostIp))"
    )
    $before = Save-EoSnapshot $stamp 'before'
    Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (Get-VMSwitch -Name $EO.SwitchName -ErrorAction SilentlyContinue) { Remove-VMSwitch -Name $EO.SwitchName -Force }
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if (Get-VMSwitch -Name $EO.SwitchName -ErrorAction SilentlyContinue) { throw 'Switch still present.' }
    if (@(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue).Count) { throw 'Firewall rules still present.' }
    Write-Host 'UNDO 01 DONE: switch and firewall rules removed.'
} finally {
    Stop-EoLog
}
