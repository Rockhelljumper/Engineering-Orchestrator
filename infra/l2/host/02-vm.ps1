# Step 02 (approved change 2, plus the ISO placement half of change 3): the VM and
# its disks. Creates C:\Hyper-V\eo-l2 with an Administrators-and-SYSTEM-only ACL,
# copies the verified ISO from step 03 into it, creates the two VHDX files and the
# Generation 2 VM eo-l2 with its one adapter on eo-l2-int. The VM is left off.
# Needs an elevated PowerShell. Undo: undo-02-vm.ps1.
#
# The folder chain C:\Hyper-V > eo-l2 > iso (rules in _vmfolder.ps1):
#   - C:\Hyper-V absent: created with owner Administrators and a protected ACL set in
#     the create call itself (Administrators and SYSTEM full control, Users read and
#     execute only), never with the C:\ ACL, which gives Authenticated Users Modify.
#   - C:\Hyper-V present: used only if it is not a link, is owned by an administrator,
#     gives no other account a write-class right, and holds no eo-l2 entry. Its other
#     contents (other VMs) stay as they are; with no write access for standard users
#     there, they cannot change what 02 creates.
#   - eo-l2 and iso: created the same way, Administrators and SYSTEM only.
#   - Each folder is read back after it is created (owner, ACL, empty, no link) and the
#     whole chain is checked again immediately before every create, the ISO copy, each
#     New-VHD and New-VM. Once C:\Hyper-V is admin-protected no standard user can
#     rename, replace or write into anything below it, so the remaining window between
#     a check and the next call is open to administrators only.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'vm'
$before = $null
try {
    if (Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue) { throw "VM $($EO.VmName) already exists; stopping." }
    # The chain first: no link from C:\ down, and an existing C:\Hyper-V admin-protected.
    $chainBad = @(Get-EoVmChainProblems)
    if ($chainBad.Count) { throw "Refusing step 02; nothing was changed: $($chainBad -join '; '). An existing $($EO.VmParent) must be owned by an administrator and give no other account write, delete or permission rights; investigate who made or changed it." }
    $parent = Get-EoPathFacts $EO.VmParent
    # An entry check, not Test-Path: a dangling link named eo-l2 counts too.
    if ($null -ne (Get-EoEntryAttributes $EO.Root)) { throw "$($EO.Root) already exists; stopping." }
    if ($parent.Exists -and @(Get-EoDirNames $EO.VmParent | Where-Object { $_ -ieq (Split-Path -Leaf $EO.Root) }).Count) { throw "$($EO.VmParent) holds an entry named $(Split-Path -Leaf $EO.Root); stopping." }
    if (-not (Get-VMSwitch -Name $EO.SwitchName -ErrorAction SilentlyContinue)) { throw "Switch $($EO.SwitchName) is missing; run 01-switch.ps1 first." }
    # The download folder is the standard user's: read nothing there through a link, and
    # trust nothing it holds until it is checked against the signed SHA256SUMS.
    Assert-EoNoLinkChain $EO.Download 'the download folder'
    $verified = Join-Path $EO.Download 'verified.json'
    if (-not (Test-Path -LiteralPath $verified)) { throw "No verified ISO; run 03-fetch-iso.ps1 first." }
    $v = Get-Content -LiteralPath $verified -Raw | ConvertFrom-Json
    # The ISO name ends up in paths (the download folder, the iso folder): a plain name only.
    $recBad = @(Test-EoIsoRecord $v)
    if ($recBad.Count) { throw "Refusing step 02; nothing was changed: $($recBad -join '; '). Run 03-fetch-iso.ps1 again." }
    # SHA256SUMS, its signature and the key are copied once into an admin-only scratch
    # folder; the signature is verified on that copy and the hash line read from the same
    # copy, so the file checked is the file read (a standard user cannot swap it between).
    $sumsDir = New-EoScratchDir 'sums'
    try {
        foreach ($n in @('SHA256SUMS', 'SHA256SUMS.sign', 'debian-cd-key.asc')) {
            $src = Join-Path $EO.Download $n
            $sf = Get-EoPathFacts $src -NoAcl
            if (-not $sf.Exists -or $sf.Reparse -or $sf.Container) { throw "$src is missing, a link or a folder; run 03-fetch-iso.ps1 again." }
            Copy-Item -LiteralPath $src -Destination (Join-Path $sumsDir $n)
        }
        $sums = Join-Path $sumsDir 'SHA256SUMS'
        Assert-EoDebianSignature $sums (Join-Path $sumsDir 'SHA256SUMS.sign') (Join-Path $sumsDir 'debian-cd-key.asc') | Out-Null
        $sumLine = @(Get-Content -LiteralPath $sums | Where-Object { $_ -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($v.iso))$" })
        if ($sumLine.Count -ne 1 -or ($sumLine[0] -split '\s+')[0] -ne $v.sha256) { throw "The signed SHA256SUMS does not list $($v.iso) with hash $($v.sha256); stopping." }
    } finally {
        try { Remove-EoVerifiedTree $sumsDir }
        catch { Write-Host "note: could not remove $sumsDir ($($_.Exception.Message)); check it holds no link (dir /AL /S) before deleting it by hand" }
    }
    # The source ISO is hashed here and its copy again after the copy.
    $srcIso = Join-Path $EO.Download $v.iso
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $srcIso).Hash.ToLower() -ne $v.sha256) { throw 'Downloaded ISO does not match its signed hash; stopping.' }
    $free = (Get-Volume -DriveLetter C).SizeRemaining
    if ($free -lt 200GB) { throw "Only $([math]::Round($free / 1GB)) GB free on C:; stopping." }
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.FreePhysicalMemory * 1KB -lt 20GB) { throw 'Less than 20 GB of free memory; stopping.' }

    $iso = Join-Path $EO.IsoDir $v.iso
    Confirm-EoPlan 'vm' @(
        $(if (-not $parent.Exists) { "Create $($EO.VmParent) (absent now) with its ACL set in the create call, not inherited from C:\: owner Administrators; inheritance off; full control for Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18), read and execute only for Users (S-1-5-32-545); no other entry. Then read it back (owner, ACL, empty, not a link) and stop if it differs" } else { "$($EO.VmParent) exists and passed the check: not a link, owner $($parent.Owner), no write, delete or permission right for any account but Administrators, SYSTEM or TrustedInstaller, no eo-l2 entry. It stays unchanged, its other contents too" })
        "Create $($EO.Root), then $($EO.IsoDir), each with its ACL set in the create call: owner Administrators; inheritance off; full control for Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18) only. Each is read back (owner, ACL, empty, not a link) before use"
        "Immediately before each create, the ISO copy, each New-VHD and New-VM: check again that no folder from C:\ down to $($EO.IsoDir) is a link (reparse point) and that each still has that owner and ACL; stop otherwise"
        "Copy $($v.iso) (sha256 $($v.sha256), listed in SHA256SUMS signed by $($EO.DebianCdKeys -join ', '); signature and hash line checked on one admin-only copy, the source ISO hashed) to $($EO.IsoDir) and hash the copy again"
        "Compare that hash with https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS before typing 'vm'"
        "New-VHD $($EO.SystemVhd) 160 GB dynamic; New-VHD $($EO.AnchorVhd) 4 GB fixed (4 GB written now)"
        'The ISO and both VHDX files inherit the folder ACL (Administrators and SYSTEM only); icacls sets each one''s owner to Administrators'
        "New-VM $($EO.VmName): Generation 2, 16 GB static memory, 8 vCPU, config under $($EO.Root); its id is written to $($EO.VmIdFile) (a new file, never overwritten, owner Administrators) so the undo knows this VM's own account"
        'Checkpoints disabled, automatic checkpoints off, automatic start Nothing, automatic stop ShutDown, nested virtualization off'
        'Secure Boot on with template MicrosoftUEFICertificateAuthority; no vTPM; no COM ports'
        'Integration services: Guest Service Interface, Key-Value Pair Exchange and VSS off; heartbeat, shutdown and time sync on'
        "One adapter '$($EO.IntNic)' on $($EO.SwitchName), MAC $($EO.IntMac) static, MAC spoofing off, DHCP guard on, router guard on"
        'Disks on SCSI 0: system at location 0, anchor at location 1; DVD with the ISO at location 2; first boot device DVD'
        "Then check every entry under $($EO.Root): no link; only the two VHDX files, $(Split-Path -Leaf $EO.VmIdFile), iso\*.iso and the VM configuration under $($EO.Root)\$($EO.VmName); disks, ISO and configuration accessible to Administrators, SYSTEM and this VM's own account only (no other VM's account, not the Virtual Machines group); $($EO.Root) and iso readable at most by this VM's account. The actual ACL of every path is printed (icacls) for the transcript"
        'VM stays off. No change to the Hyper-V host settings, other VMs or other switches'
        "undo-02-vm.ps1 deletes $($EO.Root) only; $($EO.VmParent) stays"
    )
    $before = Save-EoSnapshot $stamp 'before'

    # Each folder: chain checked, created with its ACL in the create call, read back.
    # Hyper-V adds the VM's own account to each disk and ISO file when it attaches them.
    if (-not $parent.Exists) {
        Assert-EoVmChain "create $($EO.VmParent)"
        New-EoSecureDir $EO.VmParent -Parent
        Assert-EoNewDir $EO.VmParent -Parent
    }
    Assert-EoVmChain "create $($EO.Root)"
    if (@(Get-EoDirNames $EO.VmParent | Where-Object { $_ -ieq (Split-Path -Leaf $EO.Root) }).Count) { throw "$($EO.VmParent) now holds an entry named $(Split-Path -Leaf $EO.Root); stopping." }
    New-EoSecureDir $EO.Root
    Assert-EoNewDir $EO.Root
    Assert-EoVmChain "create $($EO.IsoDir)"
    New-EoSecureDir $EO.IsoDir
    Assert-EoNewDir $EO.IsoDir

    Assert-EoVmChain "copy the ISO to $iso"
    if ($null -ne (Get-EoEntryAttributes $iso)) { throw "$iso already exists; stopping." }
    Copy-Item -LiteralPath $srcIso -Destination $iso
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $iso).Hash.ToLower() -ne $v.sha256) { throw 'Copied ISO hash mismatch.' }
    # The files inherit the folder's ACL; their owner is set to Administrators so it does
    # not depend on the default-owner policy (an owner may always change the ACL).
    Invoke-EoNative icacls.exe @($iso, '/setowner', '*S-1-5-32-544') | Write-Host

    Assert-EoVmChain "create $($EO.SystemVhd)"
    if ($null -ne (Get-EoEntryAttributes $EO.SystemVhd)) { throw "$($EO.SystemVhd) already exists; stopping." }
    New-VHD -Path $EO.SystemVhd -SizeBytes $EO.SystemBytes -Dynamic | Format-List Path, VhdType, Size
    Invoke-EoNative icacls.exe @($EO.SystemVhd, '/setowner', '*S-1-5-32-544') | Write-Host
    Assert-EoVmChain "create $($EO.AnchorVhd)"
    if ($null -ne (Get-EoEntryAttributes $EO.AnchorVhd)) { throw "$($EO.AnchorVhd) already exists; stopping." }
    New-VHD -Path $EO.AnchorVhd -SizeBytes $EO.AnchorBytes -Fixed | Format-List Path, VhdType, Size
    Invoke-EoNative icacls.exe @($EO.AnchorVhd, '/setowner', '*S-1-5-32-544') | Write-Host

    Assert-EoVmChain "create VM $($EO.VmName) under $($EO.Root)"
    if ($null -ne (Get-EoEntryAttributes (Join-Path $EO.Root $EO.VmName))) { throw "$(Join-Path $EO.Root $EO.VmName) already exists; stopping." }
    New-VM -Name $EO.VmName -Generation 2 -MemoryStartupBytes $EO.MemoryBytes -Path $EO.Root -NoVHD | Out-Null
    # The VM's id gives its account (NT VIRTUAL MACHINE\<id>), the only VM account the
    # checks accept; recorded in the admin-only root for the undo.
    $vmId = "$((Get-VM -Name $EO.VmName).Id)"
    $vmSid = ConvertTo-EoVmSid $vmId
    if (-not $vmSid) { throw "VM $($EO.VmName) has no id; stopping. Run undo-02-vm.ps1." }
    Assert-EoVmChain "record the VM id in $($EO.VmIdFile)" $vmId
    Write-EoNewFile $EO.VmIdFile $vmId $EO.Root
    Invoke-EoNative icacls.exe @($EO.VmIdFile, '/setowner', '*S-1-5-32-544') | Write-Host
    Write-Host "VM id $vmId recorded in $($EO.VmIdFile); VM account $vmSid"
    Set-VM -Name $EO.VmName -ProcessorCount $EO.Cpus -StaticMemory -CheckpointType Disabled -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -Notes 'eo-l2 Phase B guest. Do not enable checkpoints: they would capture the anchor disk.'
    Set-VMProcessor -VMName $EO.VmName -ExposeVirtualizationExtensions $false
    Get-VMNetworkAdapter -VMName $EO.VmName | Remove-VMNetworkAdapter
    Add-VMNetworkAdapter -VMName $EO.VmName -Name $EO.IntNic -SwitchName $EO.SwitchName -StaticMacAddress $EO.IntMac
    Set-VMNetworkAdapter -VMName $EO.VmName -Name $EO.IntNic -MacAddressSpoofing Off -DhcpGuard On -RouterGuard On
    # Hyper-V opens the files at these paths and grants the VM's account access to them.
    Assert-EoVmChain 'attach the disks and the ISO' $vmId
    $files = @(@($EO.SystemVhd, $EO.AnchorVhd, $iso) | ForEach-Object { Test-EoPathFacts (Get-EoPathFacts $_) 'vm' -VmSid $vmSid })
    if ($files.Count) { throw "Refusing to attach the disks and the ISO: $($files -join '; ')" }
    Add-VMHardDiskDrive -VMName $EO.VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $EO.SystemVhd
    Add-VMHardDiskDrive -VMName $EO.VmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1 -Path $EO.AnchorVhd
    Add-VMDvdDrive -VMName $EO.VmName -ControllerNumber 0 -ControllerLocation 2 -Path $iso
    Set-VMFirmware -VMName $EO.VmName -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority -FirstBootDevice (Get-VMDvdDrive -VMName $EO.VmName)
    foreach ($k in $EO.IcsOff.Keys) { Get-EoIntegrationService $EO.VmName $k $EO.IcsOff[$k] | Disable-VMIntegrationService }
    foreach ($k in $EO.IcsOn.Keys) { Get-EoIntegrationService $EO.VmName $k $EO.IcsOn[$k] | Enable-VMIntegrationService }
    foreach ($port in 1, 2) { Set-VMComPort -VMName $EO.VmName -Number $port -Path '' -ErrorAction SilentlyContinue }

    # Verify every planned setting and fail if any differs.
    $vm = Get-VM -Name $EO.VmName
    $nics = @(Get-VMNetworkAdapter -VMName $EO.VmName)
    $disks = @(Get-VMHardDiskDrive -VMName $EO.VmName)
    $fw = Get-VMFirmware -VMName $EO.VmName
    $mem = Get-VMMemory -VMName $EO.VmName
    $ics = Get-VMIntegrationService -VMName $EO.VmName
    $problems = @()
    if ($vm.Generation -ne 2) { $problems += 'generation' }
    if ($vm.ProcessorCount -ne $EO.Cpus) { $problems += 'cpus' }
    if ($mem.DynamicMemoryEnabled -or $mem.Startup -ne $EO.MemoryBytes) { $problems += 'memory' }
    if ("$($vm.CheckpointType)" -ne 'Disabled' -or $vm.AutomaticCheckpointsEnabled) { $problems += 'checkpoints' }
    if ("$($vm.AutomaticStartAction)" -ne 'Nothing') { $problems += 'automatic start' }
    if ((Get-VMProcessor -VMName $EO.VmName).ExposeVirtualizationExtensions) { $problems += 'nested virtualization' }
    if ($nics.Count -ne 1 -or $nics[0].SwitchName -ne $EO.SwitchName -or $nics[0].MacAddress -ne $EO.IntMac -or "$($nics[0].MacAddressSpoofing)" -ne 'Off' -or "$($nics[0].DhcpGuard)" -ne 'On' -or "$($nics[0].RouterGuard)" -ne 'On') { $problems += 'network adapter' }
    if ($disks.Count -ne 2) { $problems += 'disk count' }
    if ("$($fw.SecureBoot)" -ne 'On' -or $fw.SecureBootTemplate -ne 'MicrosoftUEFICertificateAuthority') { $problems += 'secure boot' }
    if ((Get-VMSecurity -VMName $EO.VmName).TpmEnabled) { $problems += 'vTPM enabled' }
    foreach ($svc in $ics) { Write-Host ("integration service: {0} ({1}) = {2}" -f $svc.Name, $svc.Id, $svc.Enabled) }
    foreach ($k in $EO.IcsOff.Keys) { if ((Get-EoIntegrationService $EO.VmName $k $EO.IcsOff[$k]).Enabled) { $problems += "integration service $k on" } }
    foreach ($k in $EO.IcsOn.Keys) { if (-not (Get-EoIntegrationService $EO.VmName $k $EO.IcsOn[$k]).Enabled) { $problems += "integration service $k off" } }
    if (@(Get-VMSnapshot -VMName $EO.VmName).Count) { $problems += 'checkpoint exists' }
    # The folder chain and everything in it, as verify-host checks it later ('INFO '
    # entries are notes, not checks).
    $vf = Get-EoVmFolderReport $vmId
    foreach ($k in $vf.Keys) {
        if ("$k".StartsWith('INFO ')) { Write-Host "$k`: $(@($vf[$k]) -join ', ')"; continue }
        foreach ($x in @($vf[$k])) { $problems += "folder check '$k': $x" }
    }

    $vm | Format-List Name, State, Generation, ProcessorCount, MemoryStartup, CheckpointType, AutomaticCheckpointsEnabled, AutomaticStartAction, AutomaticStopAction, Path | Out-String | Write-Host
    $nics | Format-List Name, SwitchName, MacAddress, DynamicMacAddressEnabled, MacAddressSpoofing, DhcpGuard, RouterGuard | Out-String | Write-Host
    $disks | Format-Table ControllerType, ControllerNumber, ControllerLocation, Path -AutoSize | Out-String | Write-Host
    Get-VHD -Path $EO.SystemVhd, $EO.AnchorVhd | Format-Table Path, VhdType, Size, FileSize -AutoSize | Out-String | Write-Host
    $fw | Format-List SecureBoot, SecureBootTemplate | Out-String | Write-Host
    # The actual ACL of every path in the chain and under the root (what Hyper-V added
    # included), for the transcript.
    Show-EoVmFolderAcls
    # What New-VM and the attach calls created, for the record (Test-EoVmTree's layout).
    @(Get-EoTreeEntries $EO.Root) | ForEach-Object { "  $(if ($_.Container) { 'dir ' } else { 'file' }) $($_.Rel)" } | Write-Host

    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if ($problems.Count) { throw "Verification failed: $($problems -join ', '). Run undo-02-vm.ps1." }
    Write-Host 'STEP 02 DONE: VM eo-l2 created, verified, and left off.'
} catch {
    Write-Host "STEP 02 STOPPED: $($_.Exception.Message)"
    if ($before) {
        Show-EoVmFolderAcls
        Write-Host 'Changes may be partly made. Run undo-02-vm.ps1 to remove the VM and its folder, then fix the cause and rerun.'
    }
    throw
} finally {
    Stop-EoLog
}
