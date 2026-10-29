# eo-l2: attended provisioning runbook (M2 Phase B)

This folder holds every script that changes RH-DT-M3 or the `eo-l2` guest. Each changing script prints its plan and waits until the operator types the step name; anything else stops it before a change. Each one writes a transcript, plus a before-and-after host snapshot with the differences, to `%USERPROFILE%\eo-l2-evidence` (host) or `/var/log/eo-l2` (guest).

The five approved host changes, and the script for each:

| Approved change | Script | Privilege | Undo |
|---|---|---|---|
| 1. Internal switch `eo-l2-int`, host vNIC 192.168.250.1/29, two inbound block rules | `host/01-switch.ps1` | Elevated | `host/undo-01-switch.ps1` |
| 2. Folder `C:\Hyper-V\eo-l2`, two VHDX files, VM `eo-l2` | `host/02-vm.ps1` | Elevated | `host/undo-02-vm.ps1` |
| 3. Debian 13 ISO, signature and checksum verified | `host/03-fetch-iso.ps1` (download), `host/02-vm.ps1` (placement) | Standard user, then elevated | delete `%USERPROFILE%\Downloads\eo-l2-iso`; the ISO in the VM folder goes with undo 02 |
| 4. Temporary setup NIC on the Default Switch | `host/04a-add-setup-nic.ps1`, removed by `host/04b-remove-setup-nic.ps1` | Elevated | 04b is the undo, and it is mandatory |
| 5. Passphrase-protected key and `Host eo-l2` entry | `host/05-ssh.ps1` | Standard user | `host/undo-05-ssh.ps1` |

Read-only helpers: `host/00-preflight.ps1`, `host/verify-host.ps1`, `host/b9-targets.ps1`.

Nothing here installs software on Windows or changes WSL, Docker Desktop, VirtualBox, VPN software, the Default Switch, existing VMs, existing firewall rules, the Hyper-V host settings or global VS Code settings. The snapshot diff printed by each step shows that.

## Order

Every line marked **(you)** is typed by the operator in an attended session. "Elevated" means a PowerShell started with *Run as administrator*. Run the host scripts from this repository checkout, for example `cd <checkout>\infra\l2\host`.

1. **Preflight** (elevated, read-only): `powershell -ExecutionPolicy Bypass -File .\00-preflight.ps1`. Stop if it prints `PREFLIGHT FAILED`.
2. **ISO** (normal PowerShell): `.\03-fetch-iso.ps1`. It stops unless `SHA256SUMS` is signed by the Debian CD key `DF9B 9C49 EAA9 2984 3258 9D76 DA87 E80D 6294 BE9B` and the ISO matches.
3. **Switch** (elevated): `.\01-switch.ps1`.
4. **VM** (elevated): `.\02-vm.ps1`. The VM is created switched off.
5. **SSH key** (normal PowerShell): `.\05-ssh.ps1`. Choose the passphrase when asked.
6. **Setup NIC** (elevated): `.\04a-add-setup-nic.ps1`.
7. **Positive-control targets** (normal PowerShell): `.\b9-targets.ps1`.
8. **Install Debian (you)**: `Start-VM eo-l2; vmconnect localhost eo-l2` (elevated), then follow *Installer answers* below.
9. **First login (you)**, at the VM console as `eo-admin`:
   ```sh
   sudo ip addr add 192.168.250.2/29 dev "$(ip -br link | awk '/00:15:5d:e0:02:02/{print $1}')"
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```
   Keep the fingerprint on screen for step 10.
10. **Copy the guest scripts (you)**, in a normal PowerShell. The first connection asks you to accept the guest's host key: accept only if the fingerprint matches the console. It uses the installer password, because the key is not installed yet:
    ```powershell
    $b = "$env:USERPROFILE\eo-l2-evidence\guest-setup"
    New-Item -ItemType Directory -Force $b | Out-Null
    Copy-Item -Recurse -Force ..\guest "$b\guest"
    Copy-Item "$env:USERPROFILE\.ssh\eo-l2_ed25519.pub" $b
    Copy-Item "$env:USERPROFILE\eo-l2-evidence\b9-targets.json" $b
    tar -cf "$env:USERPROFILE\eo-l2-evidence\guest-setup.tar" -C $b .
    scp "$env:USERPROFILE\eo-l2-evidence\guest-setup.tar" eo-l2:
    ssh -t eo-l2 "mkdir -p eo-l2 && tar -xf guest-setup.tar -C eo-l2 && sudo bash eo-l2/guest/10-bootstrap.sh eo-l2/eo-l2_ed25519.pub"
    ```
11. **Reboot the guest (you)**: `ssh -t eo-l2 sudo systemctl reboot`. From now on SSH uses the key and its passphrase only; password login is off.
12. **Storage (you)**: `ssh -t eo-l2 sudo bash eo-l2/guest/11-storage.sh`.
13. **B9 positive control (you)**: `ssh -t eo-l2 "sudo python3 -I eo-l2/guest/b9-probe.py setup --targets eo-l2/b9-targets.json --out /var/log/eo-l2/b9-setup.json"`. It must print `POSITIVE CONTROL OK`.
14. **Seal (you)**: `ssh -t eo-l2 sudo bash eo-l2/guest/20-seal.sh`. The guest powers off.
15. **Remove the setup NIC** (elevated): `.\04b-remove-setup-nic.ps1`. It ends with `verify-host.ps1`, which must print `VERIFY-HOST PASSED`.
16. **B9 sealed and attack (you)**: `Start-VM eo-l2`, then
    ```powershell
    ssh -t eo-l2 "sudo python3 -I eo-l2/guest/b9-probe.py sealed --targets eo-l2/b9-targets.json --out /var/log/eo-l2/b9-sealed.json"
    ssh -t eo-l2 "sudo python3 -I eo-l2/guest/b9-probe.py attack --targets eo-l2/b9-targets.json --out /var/log/eo-l2/b9-attack.json"
    ```
    Both must print `PASSED`. Only after this does any eo code enter the guest.
17. **Collect evidence (you)**: `ssh eo-l2 sudo tar -C /var/log -cf - eo-l2 > "$env:USERPROFILE\eo-l2-evidence\guest-logs.tar"`.

Rerun step 16, with `b9-targets.ps1` first, after every Windows update and once with the VPN connected.

## Installer answers (Debian 13 netinst, step 8)

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
- Finish. When the installer asks you to remove the installation media, use the VM window's **Media > DVD Drive > Eject** first, then continue; the VM reboots from its disk. (Step 15 removes the DVD drive completely.)

## What each guest script does

- `guest/10-bootstrap.sh`: Debian packages only (Podman rootless, nftables, LVM, Python 3, git, debootstrap); Node.js 22.23.4 from nodejs.org, checked against a pinned SHA-256 whose signature was verified with a Node release key; a Debian minbase worker image built with debootstrap; interface names by MAC; `ipv6.disable=1`; hv_sock, vsock and Bluetooth modules blocked; nftables allowing only SSH from 192.168.250.1; the accounts `eo`, `eo-anchor` and `eo-worker`; sshd limited to `eo-admin` from 192.168.250.1 with keys only and no agent, remote or socket forwarding; VS Code port auto-forwarding off for this remote only.
- `guest/11-storage.sh`: the anchor volume group on the 4 GB disk; `eo-state` (fixed, 32 GB) for the state root; a separate thin pool for worker storage, not over-provisioned, autoextend off.
- `guest/b9-probe.py`: B9 inventory, reachability and alternate-adapter attack.
- `guest/20-seal.sh`: removes every setup-time network allowance and powers off.

## Rolling back

To undo everything, run in this order: `undo-02-vm.ps1` (elevated; deletes the guest), `undo-01-switch.ps1` (elevated), `undo-05-ssh.ps1` (normal), then delete `%USERPROFILE%\Downloads\eo-l2-iso`. Keep `%USERPROFILE%\eo-l2-evidence` as the record. Each undo prints its own before-and-after diff.
