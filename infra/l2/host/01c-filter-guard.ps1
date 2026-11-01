# Step 01c (B9-R1; run it only with the owner's separate approval, after 01b is
# verified): the filter guard on eo-l2-int. Unbinds the Npcap and VirtualBox NDIS
# filters ($EO.FilterTargets: INSECURE_NPCAP, oracle_VBoxNetLwf) from the host vNIC
# 'vEthernet (eo-l2-int)' only. Both work below the Windows Filtering Platform, so
# the 01 and 01b firewall rules do not constrain what they capture or send there.
# No other adapter, binding, driver, service, Npcap or VirtualBox setting, firewall
# rule or NetBIOS value changes.
# Before changing anything it records each target's state, the adapter, the switch,
# the 01b instance it builds on and its own instance id in filter-guard-state.json,
# next to the 01b record; the undo restores only from that. On any problem it stops
# and prints the undo command; it never undoes anything by itself.
# Needs an elevated PowerShell, after 01 and 01b. Undo: undo-01c-filter-guard.ps1.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'filter-guard'
$before = $null; $changed = $false
try {
    # Every precondition is read-only; anything wrong stops here.
    function Get-Preconditions {
        $gs = $null
        try { $gs = Read-EoGuardState } catch { throw "Refusing 01c; nothing was changed: $($EO.GuardState) cannot be used ($($_.Exception.Message))." }
        if (-not (Test-Path -LiteralPath $EO.GuardDir)) { throw "Refusing 01c; nothing was changed: $($EO.GuardDir) does not exist, so 01b has not run." }
        $dir = @(Test-EoAclFacts (Get-EoAclFacts $EO.GuardDir) -Container)
        if ($dir.Count) { throw "Refusing 01c; nothing was changed: $($EO.GuardDir) is not protected: $($dir -join '; ')" }
        $cur = Get-EoFilterCurrent
        # Read only when the switch exists (its absence is reported below); a read error stops 01c.
        $ext = @(if ($cur.SwitchId) { @(Get-VMSwitchExtension -VMSwitchName $EO.SwitchName) | ForEach-Object { @{ Name = "$($_.Name)"; Vendor = "$($_.Vendor)"; Enabled = "$($_.Enabled)" } } })
        $names = @(@(Get-ChildItem -LiteralPath $EO.GuardDir -Force) | ForEach-Object { $_.Name })
        $p = @(Test-EoFilterPreconditions $gs $cur (Test-Path -LiteralPath $EO.FilterState) $names $ext)
        if ($p.Count) { throw "Refusing 01c; nothing was changed: $($p -join '; ')" }
        return @{ Guard = $gs; Current = $cur }
    }
    $pre = Get-Preconditions
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly
    if ($LASTEXITCODE -ne 0) { throw 'Refusing 01c; nothing was changed: verify-host.ps1 -SwitchOnly does not pass, so 01 and 01b are not verified.' }

    $cur = $pre.Current
    $plan = @(Get-EoFilterApplyPlan $cur.Bindings)
    $change = @($plan | Where-Object Action -eq 'disable' | ForEach-Object ComponentId)
    $instance = [guid]::NewGuid().ToString('N')
    Confirm-EoPlan 'filter-guard' @(
        "Adapter '$($EO.HostIf)' only: InterfaceGuid $($cur.Adapter.InterfaceGuid), MAC $($cur.Adapter.MacAddress), host guard instance $($pre.Guard.instanceId)"
        $(foreach ($e in $plan) {
                $dn = if ($cur.BindingNames.ContainsKey($e.ComponentId)) { " ($($cur.BindingNames[$e.ComponentId]))" } else { '' }
                switch ($e.Action) {
                    'disable' { "Disable-NetAdapterBinding -Name '$($EO.HostIf)' -ComponentID $($e.ComponentId)$dn (enabled now)" }
                    'already-off' { "$($e.ComponentId)$dn is already disabled on this adapter: no change" }
                    'absent' { "$($e.ComponentId) is not bound to this adapter: no change" }
                }
            })
        "First, record each target's state, this adapter, the switch id and instance $instance in $($EO.FilterState) (Administrators and SYSTEM only); the undo restores only from that record"
        $(if ($change.Count) { 'The adapter restarts briefly while a binding changes; no VM exists yet, so no session drops' } else { 'Nothing to change: the record is still written, so verify-host checks the filter guard from now on' })
        'No other adapter, binding, driver, service, Npcap or VirtualBox setting, firewall rule or NetBIOS value changes'
    )
    # The host may have changed while the plan waited: read and check everything again.
    $pre2 = Get-Preconditions
    if ("$($pre2.Guard.instanceId)" -cne "$($pre.Guard.instanceId)") { throw 'Refusing 01c; nothing was changed: the host guard record changed while the plan waited.' }
    if ("$($pre2.Current.Adapter.InterfaceGuid)" -ne "$($cur.Adapter.InterfaceGuid)" -or "$($pre2.Current.SwitchId)" -ne "$($cur.SwitchId)") { throw 'Refusing 01c; nothing was changed: the switch or host adapter changed while the plan waited.' }
    $plan2 = @(Get-EoFilterApplyPlan $pre2.Current.Bindings)
    if ((($plan2 | ForEach-Object { "$($_.ComponentId)=$($_.Action)" }) -join ',') -cne (($plan | ForEach-Object { "$($_.ComponentId)=$($_.Action)" }) -join ',')) { throw 'Refusing 01c; nothing was changed: a target binding changed while the plan waited.' }
    $cur = $pre2.Current

    $before = Save-EoSnapshot $stamp 'before'
    $drv = [ordered]@{}
    foreach ($f in 'npcap.sys', 'VBoxNetLwf.sys') {
        $i = Get-Item -LiteralPath (Join-Path $env:SystemRoot "System32\drivers\$f") -ErrorAction SilentlyContinue
        $drv[$f] = $(if ($i) { "$($i.VersionInfo.FileVersion)" } else { $null })
    }
    $state = [ordered]@{
        schema = $EoFilterSchema; instanceId = $instance; createdAt = (Get-Date).ToUniversalTime().ToString('o'); computer = $env:COMPUTERNAME
        switchId = $cur.SwitchId
        adapter = [ordered]@{ name = $EO.HostIf; interfaceGuid = $cur.Adapter.InterfaceGuid; macAddress = $cur.Adapter.MacAddress; settingId = $cur.Adapter.SettingId }
        hostGuardInstanceId = "$($pre2.Guard.instanceId)"
        bindings = @($plan2 | ForEach-Object { [ordered]@{ componentId = $_.ComponentId; displayName = $(if ($cur.BindingNames.ContainsKey($_.ComponentId)) { $cur.BindingNames[$_.ComponentId] } else { $null }); present = [bool]$_.Present; enabledBefore = [bool]$_.EnabledBefore } })
        drivers = $drv
    }
    # Written whole to a temporary file, then moved into place, so a crash leaves no
    # half record; in the folder 01b protected (Administrators and SYSTEM only).
    $tmp = "$($EO.FilterState).tmp"
    $state | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $tmp
    Move-Item -LiteralPath $tmp -Destination $EO.FilterState
    Invoke-EoNative icacls.exe @($EO.FilterState, '/setowner', '*S-1-5-32-544') | Write-Host
    $evid = Join-Path $EO.Evidence "$stamp-filter-guard-state.json"
    Copy-Item -LiteralPath $EO.FilterState $evid
    $h1 = (Get-FileHash -Algorithm SHA256 -LiteralPath $EO.FilterState).Hash; $h2 = (Get-FileHash -Algorithm SHA256 -LiteralPath $evid).Hash
    Write-Host "record SHA256 $h1; evidence copy SHA256 $h2"
    if ($h1 -ne $h2) { throw 'The evidence copy of the filter guard record does not match it.' }
    $rec = Read-EoFilterState
    $check = @(Test-EoFilterState $rec (Get-EoFilterCurrent) "$($pre2.Guard.instanceId)")
    $recPlan = @(@($rec.bindings) | ForEach-Object { "$($_.componentId)=$($_.enabledBefore)" }) -join ','
    $want = @($plan2 | ForEach-Object { "$($_.ComponentId)=$($_.EnabledBefore)" }) -join ','
    if ($recPlan -cne $want) { $check += "the record holds '$recPlan', want '$want'" }
    if ($check.Count) { throw "The filter guard record does not read back cleanly: $($check -join '; ')" }

    # The only binding change: the targets that are enabled, on the host vNIC only.
    $changed = $true
    Set-EoFilterBindings $change

    $now = Get-EoFilterCurrent
    $bad = @(Test-EoFilterBindings $now.Bindings)
    foreach ($id in @(@($cur.Bindings.Keys) + @($now.Bindings.Keys) | Sort-Object -Unique)) {
        if ($id -in $EO.FilterTargets) { continue }
        $was = if ($cur.Bindings.ContainsKey($id)) { "$($cur.Bindings[$id])" } else { 'absent' }
        $is = if ($now.Bindings.ContainsKey($id)) { "$($now.Bindings[$id])" } else { 'absent' }
        if ($was -ne $is) { $bad += "$id on '$($EO.HostIf)' changed from $was to $is" }
    }
    if ($bad.Count) { throw "Bindings do not read back as planned: $($bad -join '; ')" }

    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    # Enforced, not only printed: no other adapter's bindings changed, and on eo-l2-int
    # only the target entries did.
    $sb = Get-Content -LiteralPath $before -Raw | ConvertFrom-Json; $sa = Get-Content -LiteralPath $after -Raw | ConvertFrom-Json
    if ("$($sb.otherBindings.sha256)" -ne "$($sa.otherBindings.sha256)" -or "$($sb.otherBindings.count)" -ne "$($sa.otherBindings.count)") { throw "Bindings on another adapter changed during 01c (digest $($sb.otherBindings.sha256) -> $($sa.otherBindings.sha256))." }
    $nonTarget = { param($l) @(@($l) | Where-Object { ("$_" -split '\|')[0] -notin $EO.FilterTargets }) -join ',' }
    if ((& $nonTarget $sb.eoBindings) -ne (& $nonTarget $sa.eoBindings)) { throw "Bindings on '$($EO.HostIf)' other than the targets changed during 01c." }
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly -RequireFilterGuard
    if ($LASTEXITCODE -ne 0) { throw 'Host-side verification failed.' }
    Write-Host 'STEP 01c DONE: Npcap and VirtualBox filters unbound from eo-l2-int and verified.'
} catch {
    Write-Host "STEP 01c STOPPED: $($_.Exception.Message)"
    if ($changed) { Write-Host 'Bindings may be partly changed; the record keeps every original value. Review the transcript, then run undo-01c-filter-guard.ps1 (elevated, attended) to restore them.' }
    elseif ($before) { Write-Host "No binding was changed. If $($EO.FilterState) exists, review it, then run undo-01c-filter-guard.ps1 (elevated, attended) to close it." }
    throw
} finally {
    Stop-EoLog
}
