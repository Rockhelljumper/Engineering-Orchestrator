# Step 05 (approved change 5): the guest-only SSH key and the "Host eo-l2" entry.
# Run from a normal (not elevated) PowerShell as Kyle. ssh-keygen asks for the
# passphrase; the step refuses a key without one. Global VS Code settings are not
# touched: port auto-forwarding is turned off only for this remote, inside the
# guest (VS Code Machine settings written by guest/10-bootstrap.sh), and sshd in
# the guest refuses remote and agent forwarding regardless of client settings.
#
# ssh takes the first value it finds for each option, so the block goes at the TOP
# of ~/.ssh/config, ahead of any "Host *", "Match" or global line, and ends with a
# "Host *" line so the lines that follow keep applying to every host as before.
# The effective settings are then read back with "ssh -G eo-l2" and checked.
# Undo: undo-05-ssh.ps1.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoNotAdmin

$begin = '# >>> eo-l2 (managed by Engineering-Orchestrator infra/l2/host/05-ssh.ps1) >>>'
$end = '# <<< eo-l2 <<<'
$block = @(
    $begin
    'Host eo-l2'
    "    HostName $($EO.GuestIp)"
    '    User eo-admin'
    '    IdentityFile ~/.ssh/eo-l2_ed25519'
    '    IdentitiesOnly yes'
    '    UserKnownHostsFile ~/.ssh/known_hosts_eo-l2'
    '    StrictHostKeyChecking ask'
    '    ForwardAgent no'
    '    ForwardX11 no'
    '    PermitLocalCommand no'
    '    ExitOnForwardFailure yes'
    '# The lines after this one applied to every host before eo-l2 was added, and still do.'
    'Host *'
    $end
)

$stamp = Start-EoLog 'ssh'
try {
    if (Test-Path $EO.SshKey) { throw "$($EO.SshKey) already exists; stopping." }
    if ((Test-Path $EO.SshConfig) -and (Select-String -Path $EO.SshConfig -SimpleMatch $begin -Quiet)) { throw 'The eo-l2 block is already in ~/.ssh/config; stopping.' }
    if ((Test-Path $EO.SshConfig) -and (Select-String -Path $EO.SshConfig -Pattern '^\s*Host\s+(.*\s)?eo-l2(\s|$)' -Quiet)) { throw 'Another "Host eo-l2" entry exists in ~/.ssh/config; stopping.' }
    $backup = "$($EO.SshConfig).before-eo-l2-$stamp"
    Confirm-EoPlan 'ssh' @(
        "ssh-keygen -t ed25519 -a 100 -f $($EO.SshKey) (you type a passphrase; an empty one is refused)"
        $(if (Test-Path $EO.SshConfig) { "Back up ~/.ssh/config to $backup, then insert the 'Host eo-l2' block at the top, closed by 'Host *'" } else { "Create ~/.ssh/config containing only the 'Host eo-l2' block" })
        "Check 'ssh -G eo-l2': host, user, this key only, its known_hosts file, no agent/X11 forwarding, no proxy, no configured forwards"
        'Block: HostName 192.168.250.2, User eo-admin, this key only, its own known_hosts file, no agent or X11 forwarding'
        'No change to existing keys, other Host entries, known_hosts, the ssh-agent service or VS Code settings'
    )
    New-Item -ItemType Directory -Force -Path $EO.SshDir | Out-Null
    if (Test-Path $EO.SshConfig) { Copy-Item $EO.SshConfig $backup }

    & ssh-keygen.exe -t ed25519 -a 100 -C "eo-l2 $env:USERNAME@$env:COMPUTERNAME" -f $EO.SshKey
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $EO.SshKey)) { throw 'ssh-keygen failed.' }
    if (-not (Test-EoKeyEncrypted $EO.SshKey)) {
        Remove-Item -Force $EO.SshKey, "$($EO.SshKey).pub"
        throw 'The key has no passphrase; it was deleted. Run the step again and set a passphrase.'
    }

    $text = ($block -join "`n") + "`n"
    if (Test-Path $EO.SshConfig) {
        $existing = [IO.File]::ReadAllText($EO.SshConfig)
        [IO.File]::WriteAllText($EO.SshConfig, $text + $existing, (New-Object Text.UTF8Encoding $false))
    } else {
        [IO.File]::WriteAllText($EO.SshConfig, $text, (New-Object Text.UTF8Encoding $false))
    }
    Copy-Item "$($EO.SshKey).pub" (Join-Path $EO.Evidence "$stamp-eo-l2_ed25519.pub")
    Invoke-EoNative ssh-keygen.exe @('-lf', "$($EO.SshKey).pub") | Write-Host

    # What ssh will actually use for eo-l2.
    $g = @(Invoke-EoNative ssh.exe @('-G', 'eo-l2'))
    $g | Set-Content -Encoding UTF8 (Join-Path $EO.Evidence "$stamp-ssh-G-eo-l2.txt")
    function Opt([string]$k) { @($g | Where-Object { $_ -match "^$k " } | ForEach-Object { $_.Substring($k.Length + 1).Trim() }) }
    $want = [ordered]@{ hostname = $EO.GuestIp; user = 'eo-admin'; identitiesonly = 'yes'; forwardagent = 'no'; forwardx11 = 'no'; stricthostkeychecking = 'ask'; permitlocalcommand = 'no' }
    $problems = @()
    foreach ($k in $want.Keys) { $v = @(Opt $k); if ($v.Count -ne 1 -or $v[0] -ne $want[$k]) { $problems += "$k=$($v -join '|') (want $($want[$k]))" } }
    $ids = @(Opt 'identityfile')
    if ($ids.Count -ne 1 -or $ids[0] -notmatch 'eo-l2_ed25519$') { $problems += "identityfile=$($ids -join '|') (want only eo-l2_ed25519)" }
    $known = @(Opt 'userknownhostsfile')
    if ($known.Count -ne 1 -or $known[0] -notmatch 'known_hosts_eo-l2$') { $problems += "userknownhostsfile=$($known -join '|') (want only known_hosts_eo-l2)" }
    foreach ($k in 'proxyjump', 'proxycommand', 'localforward', 'remoteforward', 'dynamicforward', 'localcommand', 'remotecommand') {
        $v = @(Opt $k | Where-Object { $_ -ne 'none' })
        if ($v.Count) { $problems += "$k=$($v -join '|') (want none)" }
    }
    $g | Where-Object { $_ -match '^(hostname|user|identityfile|identitiesonly|userknownhostsfile|stricthostkeychecking|forwardagent|forwardx11|proxyjump|proxycommand|localforward|remoteforward|dynamicforward) ' } | Write-Host
    if ($problems.Count) { throw "ssh -G eo-l2 does not give the planned settings: $($problems -join '; '). Run undo-05-ssh.ps1, fix the conflicting entry in ~/.ssh/config, and rerun." }
    Write-Host 'STEP 05 DONE: key created with a passphrase; Host eo-l2 added.'
} finally {
    Stop-EoLog
}
