# Undo step 01b: removes the three host guard rules and sets NetBIOS on the host
# vNIC back to the value recorded before 01b (default 0, "use DHCP setting").
# Needs an elevated PowerShell.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'undo-host-guard'
try {
    $rules = @(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue | Where-Object Name -in $EO.GuardRules)
    $saved = @(Get-ChildItem $EO.Evidence -Filter '*-netbios-before.txt' -ErrorAction SilentlyContinue | Sort-Object Name)
    $restore = if ($saved.Count) { [uint32]((Get-Content $saved[-1].FullName -Raw).Trim()) } else { [uint32]0 }
    $nic = Get-NetAdapter -Name $EO.HostIf -ErrorAction SilentlyContinue
    Confirm-EoPlan 'undo-host-guard' @(
        "Remove firewall rules: $(($rules | ForEach-Object Name) -join ', ')"
        $(if ($nic) { "NetBIOS over TCP/IP on '$($EO.HostIf)' back to $restore" } else { "'$($EO.HostIf)' is gone; NetBIOS needs no change" })
    )
    $before = Save-EoSnapshot $stamp 'before'
    $rules | Remove-NetFirewallRule
    if ($nic) {
        $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $($nic.ifIndex)"
        $r = Invoke-CimMethod -InputObject $cfg -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = $restore }
        if ($r.ReturnValue -ne 0) { throw "SetTcpipNetbios returned $($r.ReturnValue)" }
    }
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if (@(Get-NetFirewallRule -Group $EO.FwGroup -ErrorAction SilentlyContinue | Where-Object Name -in $EO.GuardRules).Count) { throw 'Host guard rules still present.' }
    Write-Host 'UNDO 01b DONE: host guard removed.'
} finally {
    Stop-EoLog
}
