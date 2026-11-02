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
| 7. Filter guard on `eo-l2-int` (B9-R1): the Npcap (`INSECURE_NPCAP`) and VirtualBox (`oracle_VBoxNetLwf`) NDIS filters unbound from the host vNIC only, and the Microsoft NDIS Capture vSwitch extension disabled on the `eo-l2-int` switch only. **Implemented for review; not approved to run** | `host/01c-filter-guard.ps1` | Elevated | `host/undo-01c-filter-guard.ps1` (re-enables only the targets 01c recorded as enabled; refuses otherwise) |

Read-only helpers: `host/00-preflight.ps1`, `host/verify-host.ps1`, `host/b9-targets.ps1`.

The guest scripts and `b9-probe.py` are provisioning and test tooling. No Engineering Orchestrator code (the controller, the anchor service, workers) enters the guest until step 17 has passed.

Nothing here installs software on Windows or changes WSL, Docker Desktop, VirtualBox, VPN software, the Default Switch, existing VMs, existing firewall rules, the Hyper-V host settings or global VS Code settings. The snapshot diff printed by each step shows that.

## Order

Every line marked **(you)** is typed by the operator in an attended session. "Elevated" means a PowerShell started with *Run as administrator*. Run the host scripts from this repository checkout, for example `cd <checkout>\infra\l2\host`. The checkout must have LF endings in `infra\l2\guest` (the repository's `.gitattributes` makes sure of it); step 9 checks again.

1. **Preflight** (elevated, read-only): `powershell -ExecutionPolicy Bypass -File .\00-preflight.ps1`. Stop if it prints `PREFLIGHT FAILED`.
2. **ISO** (normal PowerShell): `.\03-fetch-iso.ps1`. It stops unless `SHA256SUMS` is signed by the Debian CD key `DF9B 9C49 EAA9 2984 3258 9D76 DA87 E80D 6294 BE9B` and the ISO matches.
3. **Switch** (elevated): `.\01-switch.ps1`, then the host guard: `.\01b-host-guard.ps1`, then, once approved, the filter guard: `.\01c-filter-guard.ps1`. 01c refuses unless 01b is recorded and `verify-host.ps1 -SwitchOnly` passes. From 01c on, `verify-host.ps1` checks the filter guard whenever its record exists, and the full check (04b, B9) always requires it. So 01c must have run before step 6 (setup NIC): `04a-add-setup-nic.ps1` refuses, before and again after its prompt, unless the 01c record is valid for this host and `verify-host.ps1 -SwitchOnly -RequireFilterGuard` passes.
4. **VM** (elevated): `.\02-vm.ps1`. It checks the ISO's signature again and shows its hash; compare it with the published `SHA256SUMS` before typing `vm`. The VM is created switched off.
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

### The filter guard record and its undo

01c writes `%ProgramData%\eo-l2\filter-guard-state.json` before it changes a binding, in the folder 01b protected (Administrators and SYSTEM only, owned by Administrators, no link). It holds, per binding target and for the NDIS Capture extension, whether it was present and whether it was enabled, plus the computer, switch id, adapter GUID, MAC and SettingID and the 01b instance it builds on. An evidence copy goes to `%USERPROFILE%\eo-l2-evidence`.

- If 01c stops after writing the record, the record still holds every original value. `undo-01c-filter-guard.ps1` then re-enables only the targets (bindings and the extension) the record shows as enabled before 01c and skips any already as recorded, so it also completes a 01c that stopped part way.
- The undo refuses before any change when the record is missing, malformed, unprotected or for another computer, switch, adapter or 01b instance; when a target that was enabled is no longer bound (it cannot be restored); or when a target that was off before 01c is enabled now (something else changed it).
- It closes the record (moves it to the evidence folder) only when every target reads back as recorded and no other binding on the adapter changed. Otherwise the record stays.
- Declining at its `undo-filter-guard` prompt changes nothing, so its plan can be reviewed ahead of time.
- If the switch is already gone, it only closes the record.

### Residual limits of the filter guard

01c removes two known paths onto the isolated segment from unprivileged software. It is not a complete boundary against the host, and it does not try to be:

- **Administrators and privileged processes.** Anything running elevated or as SYSTEM can re-bind the filters, load another NDIS filter or protocol driver, or open the adapter by other means. verify-host detects a re-bound target, a new enabled component in the default binding view and an enabled vSwitch extension, but only when it runs; it does not prevent them.
- **Hidden bindings (a deviation from the B9-R1 design, which asked for no unknown LWF at all).** The allowed list covers the default binding view, as inventoried on 2026-11-01. Hidden components (for example the WFP and NDIS Capture lightweight filters) are not allowlisted until a read-only `-AllBindings` inventory is reviewed. The two targets are checked in both views.
- **Built-in capture and mirroring.** 01c disables the NDIS Capture extension on the eo-l2-int switch only; it stays enabled (the Windows default) on the Default Switch and the WSL switch. `pktmon` and `netsh trace` (administrator-only) can still capture on the host vNIC through the `ms_ndiscap` filter, and Hyper-V port mirroring on a VM adapter can still copy its traffic. verify-host fails if NDIS Capture or any extension other than the Windows Filtering Platform is enabled on the switch.
- **Other NDIS paths.** `ms_l2bridge` and `ms_l1vhlwf` stay bound (Windows components needed by the vNIC); a network bridge built over eo-l2-int, or a kernel debugger over the network (KDNET; a hidden "Ethernet (Kernel Debugger)" adapter exists, check with an elevated `bcdedit /enum`), is outside 01c.
- **Other adapters and software.** Npcap stays installed with `AdminOnly=0`, so standard users can still capture on every other adapter; changing that (Npcap reinstall with admin-only mode) is a separate owner decision. The VirtualBox and BlueStacks kernel drivers stay loaded next to Hyper-V.
- **Drift.** A reinstall or upgrade of Npcap or VirtualBox, a Windows network reset or feature update, or recreating the switch can re-bind the filters. verify-host runs before every later step and in B9, so drift fails it; 01-switch.ps1 does not yet unbind the targets on a newly created adapter (a separate reviewed change).
