# Step 01c (B9-R1; run it only with the owner's separate approval, after 01b is
# verified): the filter guard on eo-l2-int. Unbinds the Npcap and VirtualBox NDIS
# filters ($EO.FilterTargets: INSECURE_NPCAP, oracle_VBoxNetLwf) from the host vNIC
# 'vEthernet (eo-l2-int)' only. Both work below the Windows Filtering Platform, so
# the 01 and 01b firewall rules do not constrain what they capture or send there.
# It also disables the Microsoft NDIS Capture vSwitch extension ($EO.SwitchExtTargets)
# on the eo-l2-int switch only (Windows enables it on every switch by default), so
# frames inside the switch cannot be captured through it.
# No other adapter, binding, switch, extension, driver, service, Npcap or VirtualBox
# setting, firewall rule or NetBIOS value changes.
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
        $names = @(@(Get-ChildItem -LiteralPath $EO.GuardDir -Force) | ForEach-Object { $_.Name })
        $p = @(Test-EoFilterPreconditions $gs $cur (Test-Path -LiteralPath $EO.FilterState) $names $cur.Extensions)
        if ($p.Count) { throw "Refusing 01c; nothing was changed: $($p -join '; ')" }
        return @{ Guard = $gs; Current = $cur }
    }
    $pre = Get-Preconditions
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly
    if ($LASTEXITCODE -ne 0) { throw 'Refusing 01c; nothing was changed: verify-host.ps1 -SwitchOnly does not pass, so 01 and 01b are not verified.' }

    $cur = $pre.Current
    $plan = @(Get-EoFilterApplyPlan $cur.Bindings)
    $change = @($plan | Where-Object Action -eq 'disable' | ForEach-Object ComponentId)
    $xplan = @(Get-EoFilterApplyPlan $cur.ExtensionStates $EO.SwitchExtTargets)
    $xchange = @($xplan | Where-Object Action -eq 'disable' | ForEach-Object ComponentId)
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
        $(foreach ($e in $xplan) {
                switch ($e.Action) {
                    'disable' { "Disable-VMSwitchExtension -VMSwitchName $($EO.SwitchName) -Name '$($e.ComponentId)' (enabled now; this switch only, not the Default Switch or WSL)" }
                    'already-off' { "Switch extension '$($e.ComponentId)' is already disabled on $($EO.SwitchName): no change" }
                    'absent' { "Switch extension '$($e.ComponentId)' does not exist on $($EO.SwitchName): no change" }
                }
            })
        "First, record each target's state (bindings and extension), this adapter, the switch id and instance $instance in $($EO.FilterState) (Administrators and SYSTEM only); the undo restores only from that record"
        $(if ($change.Count) { 'The adapter restarts briefly while a binding changes; an SSH session to the guest over eo-l2-int may drop' } elseif (-not $xchange.Count) { 'Nothing to change: the record is still written, so verify-host checks the filter guard from now on' })
        'No other adapter, binding, switch, extension, driver, service, Npcap or VirtualBox setting, firewall rule or NetBIOS value changes'
    )
    # The host may have changed while the plan waited: read and check everything again.
    $pre2 = Get-Preconditions
    if ("$($pre2.Guard.instanceId)" -cne "$($pre.Guard.instanceId)") { throw 'Refusing 01c; nothing was changed: the host guard record changed while the plan waited.' }
    if ("$($pre2.Current.Adapter.InterfaceGuid)" -ne "$($cur.Adapter.InterfaceGuid)" -or "$($pre2.Current.SwitchId)" -ne "$($cur.SwitchId)") { throw 'Refusing 01c; nothing was changed: the switch or host adapter changed while the plan waited.' }
    $plan2 = @(Get-EoFilterApplyPlan $pre2.Current.Bindings)
    $xplan2 = @(Get-EoFilterApplyPlan $pre2.Current.ExtensionStates $EO.SwitchExtTargets)
    $sig = { param($pl) (@($pl) | ForEach-Object { "$($_.ComponentId)=$($_.Action)" }) -join ',' }
    if ((& $sig ($plan2 + $xplan2)) -cne (& $sig ($plan + $xplan))) { throw 'Refusing 01c; nothing was changed: a target binding or extension changed while the plan waited.' }
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
        switchExtensions = @($xplan2 | ForEach-Object { [ordered]@{ name = $_.ComponentId; present = [bool]$_.Present; enabledBefore = [bool]$_.EnabledBefore } })
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
    $recPlan += ';' + (@(@($rec.switchExtensions) | ForEach-Object { "$($_.name)=$($_.enabledBefore)" }) -join ',')
    $want = (@($plan2 | ForEach-Object { "$($_.ComponentId)=$($_.EnabledBefore)" }) -join ',') + ';' + (@($xplan2 | ForEach-Object { "$($_.ComponentId)=$($_.EnabledBefore)" }) -join ',')
    if ($recPlan -cne $want) { $check += "the record holds '$recPlan', want '$want'" }
    if ($check.Count) { throw "The filter guard record does not read back cleanly: $($check -join '; ')" }

    # The only changes: the enabled binding targets on the host vNIC, then the enabled
    # extension targets on the eo-l2-int switch.
    $changed = $true
    Set-EoFilterBindings $change
    Set-EoSwitchExtensions $xchange $cur.SwitchId

    $now = Get-EoFilterCurrent
    $bad = @(Test-EoFilterBindings $now.Bindings)
    foreach ($id in @(@($cur.Bindings.Keys) + @($now.Bindings.Keys) | Sort-Object -Unique)) {
        if ($id -in $EO.FilterTargets) { continue }
        $was = if ($cur.Bindings.ContainsKey($id)) { "$($cur.Bindings[$id])" } else { 'absent' }
        $is = if ($now.Bindings.ContainsKey($id)) { "$($now.Bindings[$id])" } else { 'absent' }
        if ($was -ne $is) { $bad += "$id on '$($EO.HostIf)' changed from $was to $is" }
    }
    $bad += @(Test-EoFilterExtensions $now.ExtensionStates)
    foreach ($n in @(@($cur.ExtensionStates.Keys) + @($now.ExtensionStates.Keys) | Sort-Object -Unique)) {
        if ($n -in $EO.SwitchExtTargets) { continue }
        $was = if ($cur.ExtensionStates.ContainsKey($n)) { "$($cur.ExtensionStates[$n])" } else { 'absent' }
        $is = if ($now.ExtensionStates.ContainsKey($n)) { "$($now.ExtensionStates[$n])" } else { 'absent' }
        if ($was -ne $is) { $bad += "switch extension '$n' on $($EO.SwitchName) changed from $was to $is" }
    }
    if ($bad.Count) { throw "Bindings or extensions do not read back as planned: $($bad -join '; ')" }

    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    # Enforced, not only printed: no other adapter's bindings changed, and on eo-l2-int
    # only the target entries did.
    $sb = Get-Content -LiteralPath $before -Raw | ConvertFrom-Json; $sa = Get-Content -LiteralPath $after -Raw | ConvertFrom-Json
    if ("$($sb.otherBindings.sha256)" -ne "$($sa.otherBindings.sha256)" -or "$($sb.otherBindings.count)" -ne "$($sa.otherBindings.count)") { throw "Bindings on another adapter changed during 01c (digest $($sb.otherBindings.sha256) -> $($sa.otherBindings.sha256))." }
    if ("$($sb.otherSwitchExtensions.sha256)" -ne "$($sa.otherSwitchExtensions.sha256)" -or "$($sb.otherSwitchExtensions.count)" -ne "$($sa.otherSwitchExtensions.count)") { throw 'Extensions on another Hyper-V switch changed during 01c.' }
    if ("$($sb.firewall.sha256)" -ne "$($sa.firewall.sha256)" -or (@($sb.firewall.eoRules) -join ',') -ne (@($sa.firewall.eoRules) -join ',')) { throw 'Firewall rules changed during 01c; the 01b host guard must stay as it is.' }
    $nonTarget = { param($l) @(@($l) | Where-Object { ("$_" -split '\|')[0] -notin $EO.FilterTargets }) -join ',' }
    if ((& $nonTarget $sb.eoBindings) -ne (& $nonTarget $sa.eoBindings)) { throw "Bindings on '$($EO.HostIf)' other than the targets changed during 01c." }
    if (-not @($sb.eoSwitchExtensions).Count -and @($cur.Extensions).Count) { throw "The before snapshot holds no switch extensions though $($EO.SwitchName) has $(@($cur.Extensions).Count); the extension diff cannot be checked." }
    $nonTargetExt = { param($l) @(@($l) | Where-Object { ("$_" -split '\|')[0] -notin $EO.SwitchExtTargets }) -join ',' }
    if ((& $nonTargetExt $sb.eoSwitchExtensions) -ne (& $nonTargetExt $sa.eoSwitchExtensions)) { throw "Extensions on $($EO.SwitchName) other than the targets changed during 01c." }
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly -RequireFilterGuard
    if ($LASTEXITCODE -ne 0) { throw 'Host-side verification failed.' }
    Write-Host 'STEP 01c DONE: Npcap and VirtualBox filters unbound from eo-l2-int, NDIS Capture disabled on its switch, and verified.'
} catch {
    Write-Host "STEP 01c STOPPED: $($_.Exception.Message)"
    if ($changed) { Write-Host 'Bindings or the extension may be partly changed; the record keeps every original value. Review the transcript, then run undo-01c-filter-guard.ps1 (elevated, attended) to restore them.' }
    elseif ($before) { Write-Host "No binding or extension was changed. If $($EO.FilterState) exists, review it, then run undo-01c-filter-guard.ps1 (elevated, attended) to close it." }
    throw
} finally {
    Stop-EoLog
}
