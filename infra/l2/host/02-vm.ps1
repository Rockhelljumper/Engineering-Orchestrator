# Step 02 (approved change 2, plus the ISO placement half of change 3): the VM and
# its disks. Creates C:\Hyper-V\eo-l2 with an Administrators-and-SYSTEM-only ACL,
# copies the verified ISO from step 03 into it, creates the two VHDX files and the
# Generation 2 VM eo-l2 with its one adapter on eo-l2-int. The VM is left off.
# Needs an elevated PowerShell. Undo: undo-02-vm.ps1.

. (Join-Path $PSScriptRoot '_common.ps1')
Assert-EoAdmin

$stamp = Start-EoLog 'vm'
$before = $null
try {
    if (Get-VM -Name $EO.VmName -ErrorAction SilentlyContinue) { throw "VM $($EO.VmName) already exists; stopping." }
    if (Test-Path $EO.Root) { throw "$($EO.Root) already exists; stopping." }
    if (-not (Get-VMSwitch -Name $EO.SwitchName -ErrorAction SilentlyContinue)) { throw "Switch $($EO.SwitchName) is missing; run 01-switch.ps1 first." }
    $verified = Join-Path $EO.Download 'verified.json'
    if (-not (Test-Path $verified)) { throw "No verified ISO; run 03-fetch-iso.ps1 first." }
    $v = Get-Content $verified -Raw | ConvertFrom-Json
    $srcIso = Join-Path $EO.Download $v.iso
    if ((Get-FileHash -Algorithm SHA256 $srcIso).Hash.ToLower() -ne $v.sha256) { throw 'Downloaded ISO no longer matches its verified hash; stopping.' }
    # verified.json sits in a folder the standard user can write, so check its claim
    # again here against the signed SHA256SUMS that 03 verified and kept.
    $sums = Join-Path $EO.Download 'SHA256SUMS'
    $sumLine = @(Get-Content $sums | Where-Object { $_ -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($v.iso))$" })
    if ($sumLine.Count -ne 1 -or ($sumLine[0] -split '\s+')[0] -ne $v.sha256) { throw "SHA256SUMS does not list $($v.iso) with hash $($v.sha256); stopping." }
    Assert-EoDebianSignature $sums (Join-Path $EO.Download 'SHA256SUMS.sign') (Join-Path $EO.Download 'debian-cd-key.asc')
    $free = (Get-Volume -DriveLetter C).SizeRemaining
    if ($free -lt 200GB) { throw "Only $([math]::Round($free / 1GB)) GB free on C:; stopping." }
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.FreePhysicalMemory * 1KB -lt 20GB) { throw 'Less than 20 GB of free memory; stopping.' }

    $iso = Join-Path $EO.IsoDir $v.iso
    Confirm-EoPlan 'vm' @(
        $(if (-not (Test-Path 'C:\Hyper-V')) { 'Create C:\Hyper-V (absent now; inherits the C:\ ACL)' } else { 'C:\Hyper-V exists; unchanged' })
        "Create $($EO.Root) and $($EO.IsoDir); ACL: inheritance off, full control for Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18) only"
        "Copy $($v.iso) (sha256 $($v.sha256), listed in SHA256SUMS signed by $($EO.DebianCdKeys -join ', ')) to $($EO.IsoDir) and re-check the hash"
        "Compare that hash with https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS before typing 'vm'"
        "New-VHD $($EO.SystemVhd) 160 GB dynamic; New-VHD $($EO.AnchorVhd) 4 GB fixed (4 GB written now)"
        "New-VM $($EO.VmName): Generation 2, 16 GB static memory, 8 vCPU, config under $($EO.Root)"
        'Checkpoints disabled, automatic checkpoints off, automatic start Nothing, automatic stop ShutDown, nested virtualization off'
        'Secure Boot on with template MicrosoftUEFICertificateAuthority; no vTPM; no COM ports'
        'Integration services: Guest Service Interface, Key-Value Pair Exchange and VSS off; heartbeat, shutdown and time sync on'
        "One adapter '$($EO.IntNic)' on $($EO.SwitchName), MAC $($EO.IntMac) static, MAC spoofing off, DHCP guard on, router guard on"
        'Disks on SCSI 0: system at location 0, anchor at location 1; DVD with the ISO at location 2; first boot device DVD'
        'VM stays off. No change to the Hyper-V host settings, other VMs or other switches'
    )
    $before = Save-EoSnapshot $stamp 'before'

    New-Item -ItemType Directory -Path $EO.Root | Out-Null
    # Inheritance off, then only Administrators and SYSTEM. Hyper-V adds the VM's own
    # account to each disk and ISO file when it attaches them.
    Invoke-EoNative icacls.exe @($EO.Root, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F') | Write-Host
    New-Item -ItemType Directory -Path $EO.IsoDir | Out-Null
    Copy-Item $srcIso $iso
    if ((Get-FileHash -Algorithm SHA256 $iso).Hash.ToLower() -ne $v.sha256) { throw 'Copied ISO hash mismatch.' }

    New-VHD -Path $EO.SystemVhd -SizeBytes $EO.SystemBytes -Dynamic | Format-List Path, VhdType, Size
    New-VHD -Path $EO.AnchorVhd -SizeBytes $EO.AnchorBytes -Fixed | Format-List Path, VhdType, Size

    New-VM -Name $EO.VmName -Generation 2 -MemoryStartupBytes $EO.MemoryBytes -Path $EO.Root -NoVHD | Out-Null
    Set-VM -Name $EO.VmName -ProcessorCount $EO.Cpus -StaticMemory -CheckpointType Disabled -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -Notes 'eo-l2 Phase B guest. Do not enable checkpoints: they would capture the anchor disk.'
    Set-VMProcessor -VMName $EO.VmName -ExposeVirtualizationExtensions $false
    Get-VMNetworkAdapter -VMName $EO.VmName | Remove-VMNetworkAdapter
    Add-VMNetworkAdapter -VMName $EO.VmName -Name $EO.IntNic -SwitchName $EO.SwitchName -StaticMacAddress $EO.IntMac
    Set-VMNetworkAdapter -VMName $EO.VmName -Name $EO.IntNic -MacAddressSpoofing Off -DhcpGuard On -RouterGuard On
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

    $vm | Format-List Name, State, Generation, ProcessorCount, MemoryStartup, CheckpointType, AutomaticCheckpointsEnabled, AutomaticStartAction, AutomaticStopAction, Path | Out-String | Write-Host
    $nics | Format-List Name, SwitchName, MacAddress, DynamicMacAddressEnabled, MacAddressSpoofing, DhcpGuard, RouterGuard | Out-String | Write-Host
    $disks | Format-Table ControllerType, ControllerNumber, ControllerLocation, Path -AutoSize | Out-String | Write-Host
    Get-VHD -Path $EO.SystemVhd, $EO.AnchorVhd | Format-Table Path, VhdType, Size, FileSize -AutoSize | Out-String | Write-Host
    $fw | Format-List SecureBoot, SecureBootTemplate | Out-String | Write-Host
    Invoke-EoNative icacls.exe @($EO.Root) | Write-Host

    $after = Save-EoSnapshot $stamp 'after'
    Compare-EoSnapshot $before $after
    if ($problems.Count) { throw "Verification failed: $($problems -join ', '). Run undo-02-vm.ps1." }
    Write-Host 'STEP 02 DONE: VM eo-l2 created, verified, and left off.'
} catch {
    Write-Host "STEP 02 STOPPED: $($_.Exception.Message)"
    if ($before) { Write-Host 'Changes may be partly made. Run undo-02-vm.ps1 to remove the VM and its folder, then fix the cause and rerun.' }
    throw
} finally {
    Stop-EoLog
}
