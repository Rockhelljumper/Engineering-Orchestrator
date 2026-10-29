# CI self-test for the eo-l2 host scripts. Changes nothing: it parses every
# script and exercises the pure helpers in _common.ps1. Runs under Windows
# PowerShell 5.1 and PowerShell 7.
#   -KeyDir: folder holding "plain" (no passphrase) and "locked" (passphrase)
#            ed25519 private keys made by ssh-keygen.
param([Parameter(Mandatory)][string]$KeyDir)

$hostDir = Split-Path $PSScriptRoot
. (Join-Path $hostDir '_common.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Expect([string]$Name, $Actual, $Expected) {
    if ("$Actual" -ceq "$Expected") { Write-Host "ok   $Name" } else { Write-Host "FAIL $Name (got '$Actual', want '$Expected')"; $failures.Add($Name) }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

foreach ($f in Get-ChildItem -Path $hostDir -Recurse -Filter *.ps1) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    Expect "parses: $($f.Name)" $errors.Count 0
    foreach ($e in $errors) { Write-Host "     $($e.Extent.StartLineNumber): $($e.Message)" }
}

Expect 'overlap: same /29' (Test-EoOverlap '192.168.250.0' 29) $true
Expect 'overlap: host address' (Test-EoOverlap '192.168.250.5' 32) $true
Expect 'overlap: next /29' (Test-EoOverlap '192.168.250.8' 29) $false
Expect 'overlap: previous address' (Test-EoOverlap '192.168.249.255' 32) $false
Expect 'overlap: 192.168.0.0/16' (Test-EoOverlap '192.168.0.0' 16) $true
Expect 'overlap: 192.168.250.0/24' (Test-EoOverlap '192.168.250.0' 24) $true
Expect 'overlap: 10.0.0.0/8' (Test-EoOverlap '10.0.0.0' 8) $false
Expect 'overlap: 0.0.0.0/1' (Test-EoOverlap '0.0.0.0' 1) $false
Expect 'overlap: 128.0.0.0/1' (Test-EoOverlap '128.0.0.0' 1) $true
Expect 'overlap: 172.16.0.0/12' (Test-EoOverlap '172.16.0.0' 12) $false

Expect 'network: /24' (Get-EoNetwork '192.168.1.57' 24) '192.168.1.0/24'
Expect 'network: /20' (Get-EoNetwork '172.20.150.1' 20) '172.20.144.0/20'
Expect 'network: /32' (Get-EoNetwork '10.1.2.3' 32) '10.1.2.3/32'
Expect 'network: /0' (Get-EoNetwork '10.1.2.3' 0) '0.0.0.0/0'

$out = Invoke-EoNative cmd.exe @('/c', 'echo to-stdout & echo to-stderr 1>&2 & exit 0')
Expect 'native: stdout kept' (@($out) -contains 'to-stdout') $true
Expect 'native: stderr kept, not thrown' (@($out | ForEach-Object { $_.Trim() }) -contains 'to-stderr') $true
$threw = $false
try { Invoke-EoNative cmd.exe @('/c', 'exit 3') | Out-Null } catch { $threw = $true }
Expect 'native: non-zero exit throws' $threw $true
$threw = $false
try { Invoke-EoNative cmd.exe @('/c', 'exit 3') -AllowFail | Out-Null } catch { $threw = $true }
Expect 'native: -AllowFail does not throw' $threw $false

Expect 'key: no passphrase detected' (Test-EoKeyEncrypted (Join-Path $KeyDir 'plain')) $false
Expect 'key: passphrase detected' (Test-EoKeyEncrypted (Join-Path $KeyDir 'locked')) $true
$threw = $false
try { Test-EoKeyEncrypted (Join-Path $KeyDir 'plain.pub') | Out-Null } catch { $threw = $true }
Expect 'key: public key rejected' $threw $true

if ($failures.Count) { Write-Host "$($failures.Count) failure(s)"; exit 1 }
Write-Host 'all host-script self-tests passed'
exit 0
