# Undo step 05: deletes the eo-l2 key pair and its known_hosts file and removes
# exactly the marked eo-l2 block from ~/.ssh/config (a backup is kept). Run from a
# normal (not elevated) PowerShell.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoNotAdmin

$begin = '# >>> eo-l2 (managed by Engineering-Orchestrator infra/l2/host/05-ssh.ps1) >>>'
$end = '# <<< eo-l2 <<<'

$stamp = Start-EoLog 'undo-ssh'
try {
    Confirm-EoPlan 'undo-ssh' @(
        "Delete $($EO.SshKey), $($EO.SshKey).pub and $($EO.SshKnown) if present"
        "Remove the lines from '$begin' to '$end' in ~/.ssh/config, after copying it to config.before-undo-eo-l2-$stamp"
    )
    foreach ($f in $EO.SshKey, "$($EO.SshKey).pub", $EO.SshKnown) { if (Test-Path $f) { Remove-Item -Force $f } }
    if (Test-Path $EO.SshConfig) {
        Copy-Item $EO.SshConfig "$($EO.SshConfig).before-undo-eo-l2-$stamp"
        $out = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($line in [IO.File]::ReadAllLines($EO.SshConfig)) {
            if ($line -eq $begin) { $skip = $true; continue }
            if ($skip -and $line -eq $end) { $skip = $false; continue }
            if (-not $skip) { $out.Add($line) }
        }
        if ($skip) { throw 'Start marker without end marker; config left unchanged.' }
        [IO.File]::WriteAllLines($EO.SshConfig, $out, (New-Object Text.UTF8Encoding $false))
    }
    Write-Host 'UNDO 05 DONE.'
} finally {
    Stop-EoLog
}
