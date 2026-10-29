# Step 01b (sixth host change, approved by the owner on 2026-10-29; run it only
# after its corrected version has been reviewed and presented):
# the host guard on eo-l2-int. Turns NetBIOS over TCP/IP off on the host vNIC and
# adds outbound block rules on it for all UDP, all ICMPv4, and TCP to every port
# but 22. The host then sends the guest no name queries (LLMNR, mDNS, NetBIOS),
# no UDP broadcasts and no TCP connection but SSH (IGMP and other rare IP
# protocols are not covered), so guest root cannot answer a
# host lookup and draw a host client (and its credentials) to the guest.
# Before changing anything it records the NetBIOS value, the adapter, the switch
# and an instance id in host-guard-state.json; the undo restores only from that.
# Needs an elevated PowerShell, after step 01. Undo: undo-01b-host-guard.ps1.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'host-guard'
$before = $null
try {
    $nic = Get-NetAdapter -Name $EO.HostIf -ErrorAction SilentlyContinue
    if (-not $nic) { throw "Host interface '$($EO.HostIf)' is missing; run 01-switch.ps1 first." }
    # By name, in any group: a rule already holding one of these names would make
    # New-NetFirewallRule fail after NetBIOS was changed.
    $existing = @($EO.GuardRules | ForEach-Object { Get-NetFirewallRule -Name $_ -ErrorAction SilentlyContinue })
    if ($existing.Count) { throw "Rules with the host guard names already exist: $(($existing | ForEach-Object { "$($_.Name) (group '$($_.Group)')" }) -join ', '); stopping before any change." }
    if (Test-Path -LiteralPath $EO.GuardState) { throw "$($EO.GuardState) exists: an earlier 01b was not undone. Run undo-01b-host-guard.ps1 first." }
    # A folder already there must be protected and empty; checked again before writing.
    if (Test-Path -LiteralPath $EO.GuardDir) {
        $dp = @(Test-EoAclFacts (Get-EoAclFacts $EO.GuardDir) -Container) + @(@(Get-ChildItem -LiteralPath $EO.GuardDir -Force) | ForEach-Object { "contains $($_.Name)" })
        if ($dp.Count) { throw "$($EO.GuardDir) exists and is not safe to use: $($dp -join '; '). Check who made it, remove it, and rerun; stopping before any change." }
    }
    $cur = Get-EoGuardCurrent
    if (-not $cur.SwitchId -or -not $cur.Adapter) { throw "Switch $($EO.SwitchName) or its host adapter is missing; run 01-switch.ps1 first." }
    $cfg = $cur.Adapter.Config
    $raw = $cfg.TcpipNetbiosOptions
    if ($null -eq $raw -or "$raw" -notmatch '^[012]$') { throw "TcpipNetbiosOptions on '$($EO.HostIf)' is '$raw', not 0, 1 or 2; stopping before any change." }
    $nbBefore = [int]$raw
    $instance = [guid]::NewGuid().ToString('N')
    $tag = Get-EoGuardInstanceTag $instance
    Confirm-EoPlan 'host-guard' @(
        "NetBIOS over TCP/IP off on '$($EO.HostIf)' (TcpipNetbiosOptions $($cfg.TcpipNetbiosOptions) -> 2)"
        "Firewall (group $($EO.FwGroup)): block outbound TCP to remote ports 1-21 and 23-65535 on '$($EO.HostIf)', all profiles"
        "Firewall (group $($EO.FwGroup)): block outbound UDP on '$($EO.HostIf)', all profiles"
        "Firewall (group $($EO.FwGroup)): block outbound ICMPv4 on '$($EO.HostIf)', all profiles"
        "Create $($EO.GuardDir) if absent, Administrators and SYSTEM only and owned by Administrators, and check it is empty and not a link"
        "First, record the NetBIOS value ($nbBefore), this adapter (GUID $($cur.Adapter.InterfaceGuid), MAC $($cur.Adapter.MacAddress)), the switch id and instance $instance in $($EO.GuardState); the undo restores only from that record"
        'SSH from the host to 192.168.250.2:22 keeps working; nothing else on the host changes'
    )
    $before = Save-EoSnapshot $stamp 'before'
    $state = [ordered]@{
        schema = $EoGuardSchema; instanceId = $instance; createdAt = (Get-Date).ToUniversalTime().ToString('o'); computer = $env:COMPUTERNAME
        switchId = $cur.SwitchId
        adapter = [ordered]@{ name = $EO.HostIf; interfaceGuid = $cur.Adapter.InterfaceGuid; macAddress = $cur.Adapter.MacAddress; settingId = $cur.Adapter.SettingId }
        netbiosBefore = $nbBefore; rules = $EO.GuardRules
    }
    # Kept under %ProgramData% in a folder only Administrators and SYSTEM can write,
    # so a standard-user process cannot edit the value the elevated undo will restore.
    Initialize-EoGuardDir
    # Written whole to a temporary file, then moved into place, so a crash leaves no half record.
    $tmp = "$($EO.GuardState).tmp"
    $state | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $tmp
    Move-Item -LiteralPath $tmp -Destination $EO.GuardState
    Invoke-EoNative icacls.exe @($EO.GuardState, '/setowner', '*S-1-5-32-544') | Write-Host
    Copy-Item -LiteralPath $EO.GuardState (Join-Path $EO.Evidence "$stamp-host-guard-state.json")
    $check = @(Test-EoGuardState (Read-EoGuardState) (Get-EoGuardCurrent))
    if ($check.Count) { throw "The state record does not read back cleanly: $($check -join '; ')" }

    $r = Invoke-CimMethod -InputObject $cfg -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 }
    if ($r.ReturnValue -ne 0) { throw "SetTcpipNetbios returned $($r.ReturnValue)" }
    New-EoGuardRules $tag

    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    & (Join-Path $PSScriptRoot 'verify-host.ps1') -NoLog -SwitchOnly
    if ($LASTEXITCODE -ne 0) { throw 'Host-side verification failed. Run undo-01b-host-guard.ps1.' }
    Write-Host 'STEP 01b DONE: host guard on eo-l2-int added and verified.'
} catch {
    Write-Host "STEP 01b STOPPED: $($_.Exception.Message)"
    if ($before) { Write-Host 'Changes may be partly made. Run undo-01b-host-guard.ps1, then fix the cause and rerun.' }
    throw
} finally {
    Stop-EoLog
}
