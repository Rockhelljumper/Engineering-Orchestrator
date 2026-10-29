# Step 05 (approved change 5): the guest-only SSH key and the "Host eo-l2" entry.
# Run from a normal (not elevated) PowerShell as Kyle. ssh-keygen asks for the
# passphrase; the step refuses a key without one. Global VS Code settings are not
# touched: port auto-forwarding is turned off only for this remote, inside the
# guest (guest/13-ssh-hardening.sh), and sshd in the guest refuses remote and
# agent forwarding regardless of client settings. Undo: undo-05-ssh.ps1.

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
        $(if (Test-Path $EO.SshConfig) { "Back up ~/.ssh/config to $backup, then append the 'Host eo-l2' block" } else { "Create ~/.ssh/config containing only the 'Host eo-l2' block" })
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
        if ($existing.Length -and -not $existing.EndsWith("`n")) { $text = "`n" + $text }
        [IO.File]::AppendAllText($EO.SshConfig, "`n" + $text, (New-Object Text.UTF8Encoding $false))
    } else {
        [IO.File]::WriteAllText($EO.SshConfig, $text, (New-Object Text.UTF8Encoding $false))
    }
    Copy-Item "$($EO.SshKey).pub" (Join-Path $EO.Evidence "$stamp-eo-l2_ed25519.pub")
    Invoke-EoNative ssh-keygen.exe @('-lf', "$($EO.SshKey).pub") | Write-Host
    Invoke-EoNative ssh.exe @('-G', 'eo-l2') | Where-Object { $_ -match '^(hostname|user|identityfile|identitiesonly|userknownhostsfile|stricthostkeychecking|forwardagent|forwardx11) ' } | Write-Host
    Write-Host 'STEP 05 DONE: key created with a passphrase; Host eo-l2 added.'
} finally {
    Stop-EoLog
}
