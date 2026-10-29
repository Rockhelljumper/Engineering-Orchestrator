# Undo step 01b: removes the three host guard rules and sets NetBIOS on the host
# vNIC back to the value 01b recorded in host-guard-state.json.
# Fails closed: it changes nothing when that record is missing or malformed, is
# not protected (Administrators and SYSTEM only, no link), was made on another
# computer, for another switch or adapter, or when a guard rule carries another
# instance's tag. It checks all of that again after the plan is confirmed. It never
# falls back to a default NetBIOS value.
# If the switch is already gone (undo-01 ran), there is no adapter to restore and
# only the record is closed. Needs an elevated PowerShell.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'undo-host-guard'
try {
    $state = $null
    try { $state = Read-EoGuardState } catch { throw "Refusing to undo 01b; nothing was changed: $($EO.GuardState) cannot be used ($($_.Exception.Message))." }
    $cur = Get-EoGuardCurrent
    $problems = @(Test-EoGuardState $state $cur)
    if ($problems.Count) {
        throw "Refusing to undo 01b; nothing was changed: $($problems -join '; '). Restore NetBIOS on '$($EO.HostIf)' by hand only after checking its original value (adapter Properties > IPv4 > Advanced > WINS)."
    }
    # By name, in any group: a guard rule moved out of eo-l2 is still this instance's (its tag was checked).
    function Get-GuardRules { @($EO.GuardRules | ForEach-Object { Get-NetFirewallRule -PolicyStore PersistentStore -Name $_ -ErrorAction SilentlyContinue }) }
    $rules = Get-GuardRules
    $restore = [uint32]$state.netbiosBefore
    Confirm-EoPlan 'undo-host-guard' @(
        "Instance $($state.instanceId), made $($state.createdAt) on $($state.computer)"
        "Remove firewall rules: $(if ($rules.Count) { ($rules | ForEach-Object Name) -join ', ' } else { 'none present' })"
        $(if ($cur.Adapter) { "NetBIOS over TCP/IP on '$($EO.HostIf)' (GUID $($cur.Adapter.InterfaceGuid)): $($cur.Adapter.Netbios) -> $restore, the recorded value" } else { "Switch and adapter are gone; NetBIOS needs no change" })
        "Close the record: move $($EO.GuardState) to the evidence folder as host-guard-state.undone-$stamp.json, and remove $($EO.GuardDir) if it is then empty"
    )
    # The host may have changed while the plan waited: read and check everything again.
    $state2 = $null
    try { $state2 = Read-EoGuardState } catch { throw "Refusing to undo 01b; nothing was changed: $($EO.GuardState) cannot be used ($($_.Exception.Message))." }
    $cur2 = Get-EoGuardCurrent
    $problems = @(Test-EoGuardState $state2 $cur2)
    if ("$(Get-EoProp $state2 'instanceId')" -cne "$($state.instanceId)") { $problems += 'the record changed while the plan waited' }
    if ([bool]$cur2.Adapter -ne [bool]$cur.Adapter -or ($cur.Adapter -and "$($cur2.Adapter.InterfaceGuid)" -ne "$($cur.Adapter.InterfaceGuid)")) { $problems += 'the host adapter changed while the plan waited' }
    if ($problems.Count) { throw "Refusing to undo 01b; nothing was changed: $($problems -join '; ')" }
    $cur = $cur2; $rules = Get-GuardRules
    $before = Save-EoSnapshot $stamp 'before'
    $rules | Remove-NetFirewallRule
    if ($cur.Adapter) {
        $r = Invoke-CimMethod -InputObject $cur.Adapter.Config -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = $restore }
        if ($r.ReturnValue -ne 0) { throw "SetTcpipNetbios returned $($r.ReturnValue); the rules are removed, the record is kept" }
        $now = (Get-EoGuardCurrent).Adapter.Netbios
        if ([int]$now -ne [int]$restore) { throw "NetBIOS reads $now after the restore, want $restore; the record is kept" }
    }
    if ((Get-GuardRules).Count) { throw 'Host guard rules still present; the record is kept.' }
    Move-Item -LiteralPath $EO.GuardState -Destination (Join-Path $EO.Evidence "host-guard-state.undone-$stamp.json")
    if (-not @(Get-ChildItem -LiteralPath $EO.GuardDir -Force).Count) { Remove-Item -LiteralPath $EO.GuardDir }
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    Write-Host 'UNDO 01b DONE: host guard removed and NetBIOS restored to its recorded value.'
} finally {
    Stop-EoLog
}
