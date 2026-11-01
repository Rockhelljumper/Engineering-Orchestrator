# Undo step 01c: re-enables, on the host vNIC only, the filter targets that 01c
# recorded as enabled before it ran, then closes the record.
# Fails closed: it changes nothing when the record is missing or malformed, is not
# protected (Administrators and SYSTEM only, no link), was made on another
# computer, for another switch or adapter or on another 01b instance, or when a
# recorded target can no longer be restored (unbound) or was enabled by something
# else since. It checks all of that again after the plan is confirmed. It enables
# only $EO.FilterTargets components, never another binding, and never one the
# record shows as off. A target already as recorded is skipped, so it also completes
# a 01c that stopped part way. The record is closed only when every target reads
# back as recorded; otherwise it stays for another attempt.
# If the switch is already gone, there is nothing to restore and only the record is
# closed. Undo order: this before undo-01b-host-guard.ps1, and that before
# undo-01-switch.ps1. Needs an elevated PowerShell.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'undo-filter-guard'
try {
    function Get-UndoFacts {
        $st = $null
        try { $st = Read-EoFilterState } catch { throw "Refusing to undo 01c; nothing was changed: $($EO.FilterState) cannot be used ($($_.Exception.Message))." }
        if ($null -eq $st) { throw "Refusing to undo 01c; nothing was changed: there is no record at $($EO.FilterState), so 01c is not applied (or was already undone)." }
        $gid = $null
        try { $gid = Get-EoProp (Read-EoGuardState) 'instanceId' } catch { throw "Refusing to undo 01c; nothing was changed: $($EO.GuardState) cannot be used ($($_.Exception.Message))." }
        $cur = Get-EoFilterCurrent
        $p = @(Test-EoFilterState $st $cur $gid)
        $plan = @()
        if (-not $p.Count -and $cur.Adapter) {
            $plan = @(Get-EoFilterRestorePlan $st $cur.Bindings)
            $p += @(Test-EoFilterRestorePlan $plan)
        }
        if ($p.Count) { throw "Refusing to undo 01c; nothing was changed: $($p -join '; ')" }
        return @{ State = $st; Current = $cur; Plan = $plan }
    }
    $u = Get-UndoFacts
    $st = $u.State; $cur = $u.Current; $plan = $u.Plan
    Confirm-EoPlan 'undo-filter-guard' @(
        "Instance $($st.instanceId), made $($st.createdAt) on $($st.computer), on host guard instance $($st.hostGuardInstanceId)"
        $(if ($cur.Adapter) {
                "Adapter '$($EO.HostIf)' only: InterfaceGuid $($cur.Adapter.InterfaceGuid), MAC $($cur.Adapter.MacAddress)"
                foreach ($e in $plan) {
                    switch ($e.Action) {
                        'enable' { "Enable-NetAdapterBinding -Name '$($EO.HostIf)' -ComponentID $($e.ComponentId) (enabled before 01c, disabled now)" }
                        'skip' { "$($e.ComponentId) is already enabled as recorded: no change" }
                        'leave-off' { "$($e.ComponentId) was not enabled before 01c: stays as it is" }
                    }
                }
            } else { 'Switch and adapter are gone; no binding needs a change' })
        "Close the record: move $($EO.FilterState) to the evidence folder as filter-guard-state.undone-$stamp.json"
        'No other adapter, binding, driver, firewall rule or NetBIOS value changes; the host guard (01b) stays'
    )
    # The host may have changed while the plan waited: read and check everything again.
    $u2 = Get-UndoFacts
    $problems = @()
    if ("$($u2.State.instanceId)" -cne "$($st.instanceId)") { $problems += 'the record changed while the plan waited' }
    if ([bool]$u2.Current.Adapter -ne [bool]$cur.Adapter -or ($cur.Adapter -and "$($u2.Current.Adapter.InterfaceGuid)" -ne "$($cur.Adapter.InterfaceGuid)")) { $problems += 'the host adapter changed while the plan waited' }
    if ((@($u2.Plan | ForEach-Object { "$($_.ComponentId)=$($_.Action)" }) -join ',') -cne (@($plan | ForEach-Object { "$($_.ComponentId)=$($_.Action)" }) -join ',')) { $problems += 'a target binding changed while the plan waited' }
    if ($problems.Count) { throw "Refusing to undo 01c; nothing was changed: $($problems -join '; ')" }
    $st = $u2.State; $cur = $u2.Current; $plan = $u2.Plan

    $before = Save-EoSnapshot $stamp 'before'
    if ($cur.Adapter) {
        # The only binding change: targets the record shows as enabled, on the host vNIC only.
        Set-EoFilterBindings @($plan | Where-Object Action -eq 'enable' | ForEach-Object ComponentId) -Enable
        $now = Get-EoFilterCurrent
        $bad = @()
        foreach ($r in @($st.bindings)) {
            $id = "$($r.componentId)"
            $on = $now.Bindings.ContainsKey($id) -and [bool]$now.Bindings[$id]
            if ($on -ne [bool]$r.enabledBefore) { $bad += "$id reads $(if ($on) { 'enabled' } else { 'not enabled' }), the record has enabledBefore $($r.enabledBefore)" }
        }
        foreach ($id in @(@($cur.Bindings.Keys) + @($now.Bindings.Keys) | Sort-Object -Unique)) {
            if ($id -in $EO.FilterTargets) { continue }
            $was = if ($cur.Bindings.ContainsKey($id)) { "$($cur.Bindings[$id])" } else { 'absent' }
            $is = if ($now.Bindings.ContainsKey($id)) { "$($now.Bindings[$id])" } else { 'absent' }
            if ($was -ne $is) { $bad += "$id on '$($EO.HostIf)' changed from $was to $is" }
        }
        if ($bad.Count) { throw "Bindings do not read back as recorded: $($bad -join '; '). The record is kept; rerun this undo after checking." }
    }
    Move-Item -LiteralPath $EO.FilterState -Destination (Join-Path $EO.Evidence "filter-guard-state.undone-$stamp.json")
    if (-not @(Get-ChildItem -LiteralPath $EO.GuardDir -Force).Count) { Remove-Item -LiteralPath $EO.GuardDir }
    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if ($cur.Adapter) {
        & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly
        if ($LASTEXITCODE -ne 0) { throw 'Host-side verification failed after the undo; the bindings are restored and the record is closed. Review the transcript.' }
    }
    Write-Host 'UNDO 01c DONE: filter bindings on eo-l2-int restored to their recorded values.'
} finally {
    Stop-EoLog
}
