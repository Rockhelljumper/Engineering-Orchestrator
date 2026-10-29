# Step 03 (approved change 3, download half): fetch the Debian 13 netinst ISO and
# verify it. Run from a normal (not elevated) PowerShell. Writes only to
# %USERPROFILE%\Downloads\eo-l2-iso (about 0.8 GB) and the evidence folder.
# Step 02 re-checks the hash and copies the ISO into the admin-only VM folder.
#
# Trust chain: SHA256SUMS must carry a valid signature by a key whose primary
# fingerprint is in $EO.DebianCdKeys (gpg from Git for Windows, with a throwaway
# keyring in %TEMP%), and the ISO must match its line in SHA256SUMS.
# The key download source does not matter: only the fingerprint is trusted.
# Undo: delete %USERPROFILE%\Downloads\eo-l2-iso.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoNotAdmin

$base = 'https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/'
$keySources = $EO.DebianCdKeys | ForEach-Object {
    "https://keyring.debian.org/pks/lookup?op=get&options=mr&search=0x$_"
    "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$_"
}

$stamp = Start-EoLog 'fetch-iso'
try {
    Confirm-EoPlan 'fetch-iso' @(
        "Download SHA256SUMS and SHA256SUMS.sign from $base"
        "Download the Debian CD signing key (fingerprints: $($EO.DebianCdKeys -join ', ')) into a throwaway keyring"
        'Verify the signature and the key fingerprint; stop if either fails'
        'Download the debian-13.*-amd64-netinst.iso named in SHA256SUMS and check its SHA-256'
        "All files go to $($EO.Download); nothing else on the host changes"
    )
    New-Item -ItemType Directory -Force -Path $EO.Download | Out-Null
    $sums = Join-Path $EO.Download 'SHA256SUMS'
    $sign = Join-Path $EO.Download 'SHA256SUMS.sign'
    Invoke-WebRequest -UseBasicParsing -Uri "${base}SHA256SUMS" -OutFile $sums
    Invoke-WebRequest -UseBasicParsing -Uri "${base}SHA256SUMS.sign" -OutFile $sign

    $keyFile = Join-Path $EO.Download 'debian-cd-key.asc'
    $got = $false
    foreach ($u in $keySources) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $keyFile
            if ((Get-Content $keyFile -Raw) -match '-----BEGIN PGP PUBLIC KEY BLOCK-----') { Write-Host "key from: $u"; $got = $true; break }
            Write-Host "key source returned no key block: $u"
        } catch { Write-Host "key source failed: $u ($($_.Exception.Message))" }
    }
    if (-not $got) { throw 'Could not download the Debian CD signing key.' }

    $primary = Assert-EoDebianSignature $sums $sign $keyFile

    $lines = @(Get-Content $sums | Where-Object { $_ -match '^([0-9a-f]{64})\s+(debian-13\.\d+\.\d+-amd64-netinst\.iso)$' })
    if ($lines.Count -ne 1) { throw "Expected exactly one Debian 13 netinst line in SHA256SUMS, found $($lines.Count)." }
    $null = $lines[0] -match '^([0-9a-f]{64})\s+(\S+)$'
    $want = $Matches[1]; $name = $Matches[2]
    $iso = Join-Path $EO.Download $name
    if (-not (Test-Path $iso) -or (Get-FileHash -Algorithm SHA256 $iso).Hash.ToLower() -ne $want) {
        Invoke-WebRequest -UseBasicParsing -Uri "$base$name" -OutFile $iso
    }
    $have = (Get-FileHash -Algorithm SHA256 $iso).Hash.ToLower()
    if ($have -ne $want) { throw "ISO hash mismatch: have $have, want $want" }
    Write-Host "ISO OK: $name sha256 $have"

    $record = [ordered]@{
        iso = $name; sha256 = $have; bytes = (Get-Item $iso).Length
        sha256sumsSha256 = (Get-FileHash -Algorithm SHA256 $sums).Hash.ToLower()
        signedBy = $primary; source = $base; verifiedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $record | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $EO.Download 'verified.json')
    $record | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $EO.Evidence "$stamp-iso-verified.json")
    Copy-Item $sums (Join-Path $EO.Evidence "$stamp-SHA256SUMS")
    Copy-Item $sign (Join-Path $EO.Evidence "$stamp-SHA256SUMS.sign")
    Copy-Item $keyFile (Join-Path $EO.Evidence "$stamp-debian-cd-key.asc")
    Write-Host 'STEP 03 DONE: ISO downloaded and verified.'
} finally {
    Stop-EoLog
}
