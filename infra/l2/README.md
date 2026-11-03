# eo-l2: attended provisioning runbook (M2 Phase B)

This folder holds every script that changes RH-DT-M3 or the `eo-l2` guest. Each changing script prints its plan and waits until the operator types the step name; anything else stops it before a change. Each one writes a transcript, plus a before-and-after host snapshot with the differences, to `%USERPROFILE%\eo-l2-evidence` (host) or `/var/log/eo-l2` (guest).

The host changes, and the script for each:

| Approved change | Script | Privilege | Undo |
|---|---|---|---|
| 1. Internal switch `eo-l2-int`, host vNIC 192.168.250.1/29, two inbound block rules | `host/01-switch.ps1` | Elevated | `host/undo-01-switch.ps1` |
| 2. Folder `C:\Hyper-V\eo-l2`, two VHDX files, VM `eo-l2` | `host/02-vm.ps1` | Elevated | `host/undo-02-vm.ps1` |
| 3. Debian 13 ISO, signature and checksum verified | `host/03-fetch-iso.ps1` (download), `host/02-vm.ps1` (placement) | Standard user, then elevated | delete `%USERPROFILE%\Downloads\eo-l2-iso`; the ISO in the VM folder goes with undo 02 |
| 4. Temporary setup NIC on the Default Switch | `host/04a-add-setup-nic.ps1`, removed by `host/04b-remove-setup-nic.ps1` | Elevated | 04b is the undo, and it is mandatory |
| 5. Passphrase-protected key and `Host eo-l2` entry | `host/05-ssh.ps1` | Standard user | `host/undo-05-ssh.ps1` |
| 6. Host guard on `eo-l2-int` (NetBIOS off; outbound UDP, ICMPv4 and TCP other than port 22 blocked), approved 2026-10-29 | `host/01b-host-guard.ps1` | Elevated | `host/undo-01b-host-guard.ps1` (restores NetBIOS only from the value 01b recorded; refuses otherwise) |
| 7. Filter guard on `eo-l2-int` (B9-R1): the Npcap (`INSECURE_NPCAP`) and VirtualBox (`oracle_VBoxNetLwf`) NDIS filters, PPPoE (`ms_pppoe`) and NDIS user-mode I/O (`ms_ndisuio`) unbound from the host vNIC only, and the Microsoft NDIS Capture vSwitch extension disabled on the `eo-l2-int` switch only. **Implemented for review; not approved to run** | `host/01c-filter-guard.ps1` | Elevated | `host/undo-01c-filter-guard.ps1` (re-enables only the targets 01c recorded as enabled; refuses otherwise) |

Read-only helpers: `host/00-preflight.ps1`, `host/verify-host.ps1`, `host/b9-targets.ps1`.

The guest scripts and `b9-probe.py` are provisioning and test tooling. No Engineering Orchestrator code (the controller, the anchor service, workers) enters the guest until step 17 has passed.

Nothing here installs software on Windows or changes WSL, Docker Desktop, VirtualBox, VPN software, the Default Switch, existing VMs, existing firewall rules, the Hyper-V host settings or global VS Code settings. The snapshot diff printed by each step shows that.

## Order

Every line marked **(you)** is typed by the operator in an attended session. "Elevated" means a PowerShell started with *Run as administrator*. Run the host scripts from this repository checkout, for example `cd <checkout>\infra\l2\host`. The checkout must have LF endings in `infra\l2\guest` (the repository's `.gitattributes` makes sure of it); step 9 checks again.

1. **Preflight** (elevated, read-only): `powershell -ExecutionPolicy Bypass -File .\00-preflight.ps1`. Stop if it prints `PREFLIGHT FAILED`.
2. **ISO** (normal PowerShell): `.\03-fetch-iso.ps1`. It stops unless `SHA256SUMS` is signed by the Debian CD key `DF9B 9C49 EAA9 2984 3258 9D76 DA87 E80D 6294 BE9B` and the ISO matches.
3. **Switch** (elevated): `.\01-switch.ps1`, then the host guard: `.\01b-host-guard.ps1`, then, once approved, the filter guard: `.\01c-filter-guard.ps1`. 01c refuses unless 01b is recorded and `verify-host.ps1 -SwitchOnly` passes. From 01c on, `verify-host.ps1` checks the filter guard whenever its record exists, and the full check (04b, B9) always requires it. So 01c must have run before step 6 (setup NIC): `04a-add-setup-nic.ps1` refuses, before and again after its prompt, unless the 01c record is valid for this host and `verify-host.ps1 -SwitchOnly -RequireFilterGuard` passes.
4. **VM** (elevated): `.\02-vm.ps1`. It checks the ISO's signature again and shows its hash; compare it with the published `SHA256SUMS` before typing `vm`. The VM is created switched off. It refuses an existing `C:\Hyper-V` that is a link or that a standard user could change (see *The VM folders* below).
5. **SSH key** (normal PowerShell): `.\05-ssh.ps1`. Choose the passphrase when asked. It stops if `ssh -G eo-l2` shows anything but the planned settings.
6. **Setup NIC** (elevated): `.\04a-add-setup-nic.ps1`.
7. **Install Debian (you)**: `Start-VM eo-l2; vmconnect localhost eo-l2` (elevated), then follow *Installer answers* below.
8. **First login (you)**, at the VM console as `eo-admin`:
   ```sh
   IF="$(ip -br link | awk '/00:15:5d:e0:02:02/{print $1}')"
   sudo ip link set dev "$IF" up
   sudo ip addr add 192.168.250.2/29 dev "$IF"
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```
   Keep the fingerprint on screen for step 9.
9. **Copy the guest scripts (you)**, in a normal PowerShell in `infra\l2\host`. The first connection asks you to accept the guest's host key: accept only if the fingerprint matches the console. It uses the installer password, because the key is not installed yet:
   ```powershell
   $b = "$env:USERPROFILE\eo-l2-evidence\guest-setup"
   if (Test-Path $b) { Remove-Item -Recurse -Force $b }
   New-Item -ItemType Directory $b | Out-Null
   Copy-Item -Recurse ..\guest "$b\guest"
   $crlf = @(Get-ChildItem -Recurse -File "$b\guest" | Where-Object { [IO.File]::ReadAllText($_.FullName).Contains("`r") })
   if ($crlf.Count) { throw "CRLF line endings in: $($crlf.FullName -join ', '). Re-clone with the repository's .gitattributes." }
   Copy-Item "$env:USERPROFILE\.ssh\eo-l2_ed25519.pub" $b
   tar -cf "$env:USERPROFILE\eo-l2-evidence\guest-setup.tar" -C $b .
   scp "$env:USERPROFILE\eo-l2-evidence\guest-setup.tar" eo-l2:
   ssh -t eo-l2 "rm -rf eo-l2 && mkdir eo-l2 && tar -xf guest-setup.tar -C eo-l2 && sudo bash eo-l2/guest/10-bootstrap.sh eo-l2/eo-l2_ed25519.pub"
   ```
10. **Reboot the guest (you)**: `ssh -t eo-l2 sudo systemctl reboot`. From now on SSH uses the key and its passphrase only; password login is off.
11. **Storage (you)**: `ssh -t eo-l2 sudo bash eo-l2/guest/11-storage.sh`.
12. **B9 positive control (you)**: fresh targets, then the probe. It must print `POSITIVE CONTROL OK`:
    ```powershell
    .\b9-targets.ps1
    scp "$env:USERPROFILE\eo-l2-evidence\b9-targets.json" eo-l2:eo-l2/
    ssh -t eo-l2 "sudo python3 -I eo-l2/guest/b9-probe.py setup --targets eo-l2/b9-targets.json --out /var/log/eo-l2/b9-setup.json"
    ```
13. **Seal (you)**: `ssh -t eo-l2 sudo bash eo-l2/guest/20-seal.sh`. It refuses unless step 12 passed. The guest powers off.
14. **Remove the setup NIC** (elevated): `.\04b-remove-setup-nic.ps1`. It refuses while the guest runs, and ends with `verify-host.ps1`, which must print `VERIFY-HOST PASSED`.
15. **B9 sealed and attack (you)**: `Start-VM eo-l2` (elevated), then in a normal PowerShell:
    ```powershell
    .\b9-targets.ps1
    scp "$env:USERPROFILE\eo-l2-evidence\b9-targets.json" eo-l2:eo-l2/
    ssh -t eo-l2 "sudo python3 -I eo-l2/guest/b9-probe.py sealed --targets eo-l2/b9-targets.json --out /var/log/eo-l2/b9-sealed.json"
    ssh -t eo-l2 "sudo python3 -I eo-l2/guest/b9-probe.py attack --targets eo-l2/b9-targets.json --out /var/log/eo-l2/b9-attack.json"
    ssh -t eo-l2 sudo systemctl reboot
    ```
    Both must print `PASSED`. The reboot clears anything the attack changed at runtime.
16. **B9 sealed after reboot (you)**: run the `sealed` line of step 15 again, with `--out /var/log/eo-l2/b9-sealed-after-attack.json`. It must print `PASSED`.
17. **Collect evidence (you)**: `ssh eo-l2 sudo tar -C /var/log -cf - eo-l2 > "$env:USERPROFILE\eo-l2-evidence\guest-logs.tar"`. Only after this does any eo code enter the guest.

Rerun steps 15 to 16, each time with fresh targets copied in, after every Windows update, and once with the VPN connected.

## Installer answers (Debian 13 netinst, step 7)

- Choose **Install** (text mode), English, your location and keyboard.
- **Network**: when asked for the primary interface, pick the one whose DHCP works. That is the setup NIC, MAC `00:15:5d:e0:02:99`. If the installer picks the other one and DHCP fails, go back and choose the other interface.
- **Hostname** `eo-l2`, domain left empty.
- **Root password**: leave it empty. That locks root and gives the first user sudo.
- **User**: full name `eo admin`, user name `eo-admin`, a strong password (used for sudo).
- **Partitioning**: *Manual*. Pick only the **160 GB** disk; leave the 4 GB disk untouched, because step 12 checks that it is blank.
  - New GPT partition table on the 160 GB disk.
  - 512 MB, *EFI System Partition*.
  - 1 GB, ext4, mount point `/boot`.
  - The rest, *physical volume for LVM*.
  - *Configure the Logical Volume Manager*: create volume group `eo-sys` on that physical volume only, then logical volumes `root` (40 GB) and `swap` (4 GB). Leave the rest of the volume group unallocated.
  - Use `eo-sys/root` as ext4 mounted at `/`, and `eo-sys/swap` as swap.
- **Mirror**: your country, `deb.debian.org`, no HTTP proxy.
- **Popularity contest**: No.
- **Software selection**: only *SSH server* and *standard system utilities*. No desktop.
- Finish. When the installer asks you to remove the installation media, use the VM window's **Media > DVD Drive > Eject** first, then continue; the VM reboots from its disk. (Step 14 removes the DVD drive completely.)

## What each guest script does

- `guest/10-bootstrap.sh`: Debian packages only (Podman rootless, nftables, LVM, Python 3, git, debootstrap); Node.js 22.23.4 from nodejs.org, checked against a pinned SHA-256 whose signature was verified with a Node release key; a Debian minbase worker image built with debootstrap; interface names by MAC; `ipv6.disable=1`; hv_sock, vsock and Bluetooth modules blocked and the vsock module files deleted (and kept out of later kernel packages); nftables allowing only SSH from 192.168.250.1; the accounts `eo`, `eo-anchor` and `eo-worker`; sshd limited to `eo-admin` from 192.168.250.1 with keys only and no agent, remote or socket forwarding; VS Code port auto-forwarding off for this remote only.
- `guest/11-storage.sh`: the anchor volume group on the 4 GB disk; `eo-state` (fixed, 32 GB) for the state root; a separate thin pool for worker storage, not over-provisioned, autoextend off.
- `guest/b9-probe.py`: B9 inventory (one interface, no other route or policy rule, no IPv6, no vsock, the host vNIC reachable at layer 2), reachability of every host address on its service and listening ports, a capture on `eoint` of anything the host sends besides SSH, and the alternate-adapter attack (route via the host, spoofed sources, on-link subnets, hv_sock), with the guest restored and checked afterwards.
- `guest/20-seal.sh`: removes every setup-time network allowance and powers off.

## Rolling back

To undo everything, run in this order: `undo-02-vm.ps1` (elevated; deletes the guest), `undo-01c-filter-guard.ps1` if 01c ran (elevated), `undo-01b-host-guard.ps1` if 01b ran (elevated), `undo-01-switch.ps1` (elevated), `undo-05-ssh.ps1` (normal), then delete `%USERPROFILE%\Downloads\eo-l2-iso`. Keep `%USERPROFILE%\eo-l2-evidence` as the record. Each undo prints its own before-and-after diff.

`undo-01b-host-guard.ps1` refuses while the 01c record exists and the adapter is present, and `undo-01-switch.ps1` refuses while either record exists.

### The VM folders (02, its undo, verify-host)

The VM, its disks and the ISO live in `C:\Hyper-V\eo-l2`. `C:\` lets every authenticated user create folders and gives them Modify, delete included, on whatever inherits from it, so a `C:\Hyper-V` with the inherited ACL, or one a standard user made, could be renamed or replaced and a planted VM folder opened by Hyper-V; and a junction anywhere in the path would send an elevated delete elsewhere (measured on RH-DT-M3: `Remove-Item` through a junction deletes the redirected target, for example `C:\ProgramData\eo-l2` with the 01b/01c records). The rules are in `host/_vmfolder.ps1`:

- **No link.** No folder from `C:\` down to `C:\Hyper-V\eo-l2\iso` may be a reparse point (junction, symbolic link, mount point). Each level is checked on its own, because a path through a junction reads like the real one. 02 checks before its plan and again immediately before each create, the ISO copy, each `New-VHD`, `New-VM`, the VM id record and the attach calls.
- **`C:\Hyper-V`.** When absent, 02 creates it with its ACL in the create call itself (owner Administrators; inheritance off; full control for Administrators and SYSTEM; read and execute for Users; nothing else) and reads it back. When present, 02 uses it only if it is owned by Administrators, SYSTEM or TrustedInstaller and no other account has a write-class right (write, append, delete, delete child, write attributes, change permissions, take ownership, or a generic write or all) in any entry, inherited or not. Read-only entries for others are accepted, and so is an inherit-only CREATOR OWNER entry (it stands for whoever creates a child, which the rule limits to administrators). Other folders in it (other VMs) are left alone. With no write right for standard users there, none can rename, replace or write into anything below it, which closes the window between each check and the next call to all but administrators.
- **Creating a folder with its ACL in one step, or not at all.** 02 and the scratch folders below use `DirectoryInfo.Create(DirectorySecurity)` (Windows PowerShell 5.1) or `FileSystemAclExtensions.Create` (PowerShell 7). An edition with neither makes the step throw before it creates anything; there is no create-then-set-ACL fallback, because in that window a standard user could open a handle that keeps its access.
- **`eo-l2` and `iso`.** Created the same way: owner Administrators, inheritance off, Administrators and SYSTEM only; each read back (owner, ACL, empty, no link) before use. Later only this VM's own account may be added (Hyper-V may add it), with read and list rights at most.
- **This VM's own account.** Hyper-V gives each VM an account `NT VIRTUAL MACHINE\<VM id>`. Its SID is built from the VM id (`(Get-VM eo-l2).Id`): `S-1-5-83-1-` and the id's 16 bytes (`Guid.ToByteArray`) read as four little-endian UInt32, joined by `-` (`ConvertTo-EoVmSid`; for example `3d1cfb06-8390-426d-8579-bd79b6bf3aa4` gives `S-1-5-83-1-1025309446-1114473360-2042460549-2755313590`). Only that SID is accepted, and only once the VM exists; another VM's account and the Virtual Machines group (`S-1-5-83-0`) never are. Right after `New-VM`, 02 writes the id to `C:\Hyper-V\eo-l2\eo-l2.vmid` (a new file in the admin-only folder, never overwritten) so the undo still knows the account after `Remove-VM`, or on a rerun after the VM is gone; when both exist, the record and the VM id must agree.
- **Disks, ISO and VM configuration.** Owner Administrators, SYSTEM or this VM's account; access for Administrators, SYSTEM and this VM's account only. 02 checks this at its end, verify-host on every full check. 02 prints the actual ACL (`icacls`) of every level of the chain and every path under `eo-l2` to the transcript, at its end and when it stops after a change, so the first run records what Hyper-V really added.
- **Contents.** `eo-l2` may hold only `eo-l2-system.vhdx`, `eo-l2-anchor.vhdx`, `eo-l2.vmid`, `iso\*.iso` and `eo-l2\Virtual Machines` and `eo-l2\Snapshots` (what `New-VM -Path` creates; 02 prints the tree it found so the first run records the real layout). Every folder must be listable, except, while the VM runs, its runtime folder `eo-l2\Virtual Machines\<id>`: verify-host then shows it as an INFO row.
- **The ISO record and SHA256SUMS.** `verified.json` sits in the standard user's download folder, so 02 accepts its ISO name only as a plain file name (`\A[A-Za-z0-9._-]+\.iso\z`, no `..`). It copies `SHA256SUMS`, `SHA256SUMS.sign` and the key once into an admin-only folder `%ProgramData%\eo-l2-sums-<random>`, verifies the signature on that copy, reads the hash line from the same copy, hashes the source ISO, and hashes the copy in `iso` again. The folder is deleted again before the plan.
- **Undo.** `undo-02-vm.ps1`, in this order: (1) before the plan, the chain has no link, the VM id comes from Hyper-V or the record, and all of the above holds; a running VM's unreadable runtime folder is only listed in the plan, not passed as checked. (2) After the typed confirmation, the same checks again, and the plan must still be true: the VM and the folder present or absent as listed, with the same VM id; otherwise it stops and must be run again for a new plan. (3) `Stop-VM -TurnOff`, `Remove-VM`. (4) The full strict check, every folder now readable, and the ACL of every entry below `eo-l2`: only Administrators, SYSTEM and the removed VM's account may have access (`iso` as `eo-l2`). (5) The delete: entry by entry, deepest first, re-checking each entry and every folder above it for a link right before each delete, folders only when empty; never a recursive `Remove-Item`. Any failed check stops it and prints the actual ACLs. The delete refuses outright the 01b/01c record folder, the evidence folder, ProgramData, Windows, the user profile, any path with `~` (8.3 names), or anything holding them; there is no parameter to skip that. It is also an allow-list: it accepts only `C:\Hyper-V\eo-l2` itself and the admin-only scratch folders `%ProgramData%\eo-l2-gpg-`, `eo-l2-sums-` and `eo-l2-selftest-` followed by 32 hex digits (or a folder inside one); any other path is refused. `C:\Hyper-V` stays.
- **verify-host** also lists, as an INFO row that never fails, the members of Hyper-V Administrators (`S-1-5-32-578`); they can manage VMs and their files without being administrators. Whether that list is acceptable is the operator's call; nothing checks it.
- **Typed confirmations.** Every step's confirmation (`Confirm-EoPlan`) refuses before asking when standard input is redirected, so piped text, a file or a script cannot answer it; the operator types it at the console.
- **What remains.** An administrator could still swap a folder for a junction between the last re-check and the next call; PowerShell offers no handle-relative create or delete to close that. The Hyper-V layout (which folders New-VM creates, which ACL entries Hyper-V adds and where) is taken from the documentation and has not yet been seen on RH-DT-M3; the first 02 run prints it, and a difference makes 02 fail its final check, not pass silently.

#### Recovering from a refused undo-02

When `undo-02-vm.ps1` refuses (a link, an unexpected owner, ACL entry or file, a VM id mismatch, a folder it cannot list), it changes nothing, or, when it refuses after `Remove-VM`, it deletes nothing. First find out who changed the folders and why; do not delete anything through a link. If the content is to be removed anyway, this is an **attended manual procedure**, done by the operator in an elevated `cmd.exe`, one command at a time, reading each output before the next:

The order matters: first make every level above and at `eo-l2` admin-only and not a link, so nobody else can add a link while the recursive commands run; only then look inside and reset it.

1. Fix `C:\Hyper-V` first. `dir /AL C:\` must list no `Hyper-V` link, then check `icacls C:\Hyper-V`: owner an administrator, no write-class right for any other account. Fix it if not (owner, and remove the extra entries with `icacls C:\Hyper-V /remove:g <sid>`), without touching other VMs' folders inside it.
2. Lock `eo-l2` itself, not recursively. `dir /AL C:\Hyper-V` must list no `eo-l2` link; then:
   ```bat
   takeown /F C:\Hyper-V\eo-l2 /A
   icacls C:\Hyper-V\eo-l2 /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F
   icacls C:\Hyper-V\eo-l2
   ```
   The last line must show, owner aside, only `BUILTIN\Administrators` and `NT AUTHORITY\SYSTEM` (explicit entries below may still differ; step 4 resets them).
3. Only now look inside. This must list no `<JUNCTION>`, `<SYMLINKD>` or `<SYMLINK>` entry (an empty listing, or "File Not Found", is the good result):
   ```bat
   dir /AL /S C:\Hyper-V\eo-l2
   ```
   If any link shows, stop and investigate; do not go on. A process that already held write access below `eo-l2` before step 2 may still do so through an explicit entry; if anything else could be running as another account, stop it first.
4. Take ownership for Administrators below the folder, drop every explicit entry there, and make `iso` protected and admin-only:
   ```bat
   takeown /F C:\Hyper-V\eo-l2 /A /R /D Y
   icacls C:\Hyper-V\eo-l2 /reset /T /C
   icacls C:\Hyper-V\eo-l2 /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F
   icacls C:\Hyper-V\eo-l2\iso /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F
   icacls C:\Hyper-V\eo-l2 /T
   dir /AL /S C:\Hyper-V\eo-l2
   ```
   (skip the `iso` line when there is no `iso` folder). `/reset` makes `eo-l2` inherit from `C:\Hyper-V` for a moment, which step 1 made safe; the next line protects it again. The `icacls ... /T` listing must show, owner aside, only `BUILTIN\Administrators` and `NT AUTHORITY\SYSTEM`, and the last line must still show no link.
5. Run `undo-02-vm.ps1` again and read its plan; it must now pass its checks and delete the folder itself. Do not delete the folder by hand.

The procedure resets every ACL under `C:\Hyper-V\eo-l2`, so run it only once the guest and its disks are to be destroyed. It never touches `C:\ProgramData\eo-l2` or the evidence folder.

### Elevated writes into the evidence and download folders

`%USERPROFILE%\eo-l2-evidence` and `%USERPROFILE%\Downloads\eo-l2-iso` belong to the standard user, and most steps write or read there elevated. So (in `host/_common.ps1`, for every step):

- Before each transcript and snapshot, no folder from `C:\` down to the evidence folder may be a link (each level checked); the transcript's chain is checked again immediately before `Start-Transcript`.
- Each evidence file is created new (`FileMode.CreateNew`, `Start-Transcript -NoClobber`); an existing file of that name is refused, never overwritten. File names and formats are unchanged (the snapshot is the same JSON, with a byte order mark on Windows PowerShell 5.1 and without one on PowerShell 7, as `Set-Content -Encoding UTF8` wrote it).
- The elevated gpg check (02) keeps its gpg home and status file in an admin-only `%ProgramData%\eo-l2-gpg-<random>`, made with its ACL in the create call and deleted with the link-checked delete. Not elevated (03), it uses `%TEMP%` as before: gpg runs as that user there, so protecting the folder from them would gain nothing.
- 02 reads nothing in the download folder through a link (see *The ISO record and SHA256SUMS* above).

Not covered: 01b, 01c, their undos, 03 and 05 also copy or move files into the evidence folder themselves (for example 01c's closed record); those lines are unchanged here, so only the chain check at their start (in `Start-EoLog`) protects them, not a check right before each write.

### The filter guard record and its undo

01c writes `%ProgramData%\eo-l2\filter-guard-state.json` (schema `eo-l2-filter-guard/3`) before it changes a binding, in the folder 01b protected (Administrators and SYSTEM only, owned by Administrators, no link). It holds, per binding target and for the NDIS Capture extension, whether it was present and whether it was enabled, plus the computer, switch id, adapter GUID, MAC and SettingID and the 01b instance it builds on. An evidence copy goes to `%USERPROFILE%\eo-l2-evidence`. `ms_pppoe` and `ms_ndisuio` are hidden bindings: they appear only with `-AllBindings`, so 01c, its undo and verify-host read and change the targets with `-AllBindings`.

Hyper-V gives each switch a hidden `vSwitch (<switch>)` adapter, and a switch extension's Enabled state is its component's binding on that adapter (NDIS Capture is `ms_ndiscap` there). So disabling NDIS Capture on eo-l2-int also turns off `ms_ndiscap` on `vSwitch (eo-l2-int)`. Snapshots list that adapter's bindings in full (`eoSwitchAdapterBindings`) and leave it out of the other-adapter digest. 01c and its undo enforce that only that entry changed there, that the digest of every other adapter (the Default Switch and WSL switch adapters included) is unchanged, and, before 01c changes anything, that the `ms_ndiscap` binding on that adapter reads as the extension does. The separate `ms_ndiscap` binding on the host vNIC `vEthernet (eo-l2-int)` is the host-side capture filter and stays (see residual limits).

- If 01c stops after writing the record, the record still holds every original value. `undo-01c-filter-guard.ps1` then re-enables only the targets (bindings and the extension) the record shows as enabled before 01c and skips any already as recorded, so it also completes a 01c that stopped part way.
- The undo refuses before any change when the record is missing, malformed, unprotected or for another computer, switch, adapter or 01b instance; when a target that was enabled is no longer bound (it cannot be restored); or when a target that was off before 01c is enabled now (something else changed it).
- It closes the record (moves it to the evidence folder) only when every target reads back as recorded and nothing else on the adapter or switch changed (identity, NetBIOS, other bindings and extensions). Otherwise the record stays.
- Both 01c and its undo then enforce, from their before and after snapshots, that no other adapter's bindings, no other switch's extensions, no switch, no firewall rule (so the 01b guard) and no IPv4 address or route on the host vNIC changed (`Test-EoSnapshotCollateral`).
- Only after its final `verify-host -SwitchOnly -RequireFilterGuard` passes does 01c write its completion stamp `%ProgramData%\eo-l2\filter-guard-verified.json` (same protection; it names the record's instance and SHA256). 04a refuses without a stamp that matches the record, so a 01c that stopped after its change never counts as installed. The undo closes the stamp before the record.
- After a binding or extension change, 01c and its undo wait (up to 30 s) until the host vNIC reads as settled (up, `192.168.250.1` Preferred, on-link route) on three polls in a row before reading back.
- Declining at its `undo-filter-guard` prompt changes nothing, so its plan can be reviewed ahead of time.
- If the switch is already gone, it only closes the record.

### Residual limits of the filter guard

01c removes known paths onto the isolated segment from unprivileged software. It is not a complete boundary against the host, and it does not try to be:

- **Administrators and privileged processes.** Anything running elevated or as SYSTEM can re-bind the filters, load another NDIS filter or protocol driver, or open the adapter by other means. verify-host detects a re-bound target, a new enabled component in the default binding view and an enabled vSwitch extension, but only when it runs; it does not prevent them.
- **Hidden bindings (a deviation from the B9-R1 design, which asked for no unknown LWF at all).** The allowed list covers the default binding view, as inventoried on 2026-11-01. The hidden components on the host vNIC were inventoried read-only on 2026-11-02 (`-AllBindings`) and classified in the provisioning log; the two that could carry frames for an unprivileged host user, `ms_pppoe` and `ms_ndisuio`, are 01c targets since the owner decision of 2026-11-02; the rest (`ms_wfplwf_*`, `ms_netbt`, `ms_netbios`, `ms_rdma_ndk`, `ms_ndiscap`) are classified necessary or acceptable residual and are not yet enforced by an allowlist. All four targets are checked in both views.
- **Built-in capture and mirroring.** 01c disables the NDIS Capture extension on the eo-l2-int switch only; it stays enabled (the Windows default) on the Default Switch and the WSL switch. `pktmon` and `netsh trace` (administrator-only) can still capture on the host vNIC through the `ms_ndiscap` filter, and Hyper-V port mirroring on a VM adapter can still copy its traffic. verify-host fails if NDIS Capture or any extension other than the Windows Filtering Platform is enabled on the switch. While the temporary setup NIC (04a to 04b) is on the Default Switch, the guest's installer traffic there stays visible to NDIS Capture, as to anything else on the host's NAT network. 01c changes the extension only on the switch with the recorded id, which must be the single Internal switch named eo-l2-int.
- **Other NDIS paths.** `ms_l2bridge` and `ms_l1vhlwf` stay bound (Windows components needed by the vNIC); a network bridge built over eo-l2-int, or a kernel debugger over the network (KDNET; a hidden "Ethernet (Kernel Debugger)" adapter exists, check with an elevated `bcdedit /enum`), is outside 01c.
- **Other adapters and software.** Npcap stays installed with `AdminOnly=0`, so standard users can still capture on every other adapter; changing that (Npcap reinstall with admin-only mode) is a separate owner decision. The VirtualBox and BlueStacks kernel drivers stay loaded next to Hyper-V.
- **Drift.** A reinstall or upgrade of Npcap or VirtualBox, a reinstall of the PPPoE or NDISUIO protocol, a Windows network reset or feature update, or recreating the switch can re-bind the filters. verify-host runs before every later step and in B9, so drift fails it; 01-switch.ps1 does not yet unbind the targets on a newly created adapter (a separate reviewed change).
