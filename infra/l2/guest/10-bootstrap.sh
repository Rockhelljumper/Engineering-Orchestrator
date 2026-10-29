#!/usr/bin/env bash
# Guest step 10: base configuration while the temporary setup NIC is attached.
# Run as: sudo bash 10-bootstrap.sh <path to eo-l2_ed25519.pub>
#
# Downloads only from deb.debian.org (packages, worker base image) and nodejs.org
# (one tarball checked against a pinned SHA-256). No eo code is in the guest yet.
# Ends by asking for a reboot so the interface names and kernel options apply.
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
eo_need_root

PUBKEY=${1:-}
[[ -n $PUBKEY && -f $PUBKEY ]] || eo_die "usage: sudo bash 10-bootstrap.sh /path/to/eo-l2_ed25519.pub"
grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+ ' "$PUBKEY" || eo_die "$PUBKEY is not an ed25519 public key"
[[ $(wc -l <"$PUBKEY") -eq 1 ]] || eo_die "$PUBKEY must hold exactly one key"

eo_log_start bootstrap

# --- Preconditions ----------------------------------------------------------
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]] || eo_die "expected Debian 13, found $PRETTY_NAME"
[[ $(dpkg --print-architecture) == amd64 ]] || eo_die "expected amd64"
SB=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
[[ -f $SB && $(od -An -tu1 -j4 -N1 "$SB" | tr -d ' ') == 1 ]] || eo_die "Secure Boot is not enabled"
INT_IF=$(eo_if_for_mac "$EO_INT_MAC"); SETUP_IF=$(eo_if_for_mac "$EO_SETUP_MAC")
[[ -n $INT_IF ]] || eo_die "no interface with MAC $EO_INT_MAC"
[[ -n $SETUP_IF ]] || eo_die "no interface with MAC $EO_SETUP_MAC (setup NIC must be attached for this step)"
ETHERS=$(find /sys/class/net -mindepth 1 -maxdepth 1 ! -name lo -printf '%f\n' | sort | tr '\n' ' ')
echo "interfaces: $ETHERS (int=$INT_IF setup=$SETUP_IF)"
[[ $(wc -w <<<"$ETHERS") -eq 2 ]] || eo_die "expected exactly two network interfaces besides lo"
ip route show default | grep -q "dev $SETUP_IF" || eo_die "default route is not via the setup NIC"
ROOT_DEV=$(findmnt -no SOURCE /)
[[ $ROOT_DEV == /dev/mapper/eo--sys-root ]] || eo_die "root filesystem should be on LV eo-sys/root (found $ROOT_DEV); see the install answers"

PKGS=(podman uidmap passt catatonit dbus-user-session systemd-container
      nftables openssh-server sudo lvm2 thin-provisioning-tools
      python3 git ca-certificates xz-utils debootstrap
      iproute2 iputils-ping netcat-openbsd procps psmisc)

eo_confirm bootstrap \
  "apt sources: deb.debian.org trixie, trixie-updates, trixie-security; main only" \
  "apt full-upgrade, then install: ${PKGS[*]}" \
  "Node.js $EO_NODE_VERSION from nodejs.org into /opt/node, sha256 $EO_NODE_SHA256" \
  "Worker base image: debootstrap --variant=minbase trixie into /var/lib/eo-build, saved as a tar with its sha256" \
  "Interface names by MAC: eoint ($EO_INT_MAC) static $EO_GUEST_IP/$EO_PREFIX, no gateway; eosetup ($EO_SETUP_MAC) DHCP until step 20" \
  "Kernel: ipv6.disable=1; blacklist hv_sock, vsock and bluetooth modules and delete the vsock module files; sysctl hardening" \
  "nftables: inbound only SSH from $EO_HOST_IP on eoint; outbound only replies, plus eosetup until step 20" \
  "Accounts: eo, eo-anchor, eo-worker (no login shell, no sudo); eo-worker subuid/subgid range and lingering" \
  "sshd: listen on $EO_GUEST_IP only, key only, only eo-admin from $EO_HOST_IP, no agent/X11/remote/stream forwarding" \
  "eo-admin: authorized key from $PUBKEY; VS Code machine setting remote.autoForwardPorts=false for this remote only"

# --- Packages ---------------------------------------------------------------
rm -f /etc/apt/sources.list
cat >/etc/apt/sources.list.d/debian.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade
apt-get -y install --no-install-recommends "${PKGS[@]}"
# No rootful container runtime: docker and its friends must be absent.
for p in docker.io docker-ce containerd runc-rootful; do
    ! dpkg -s "$p" >/dev/null 2>&1 || eo_die "unexpected package $p installed"
done

# --- Node.js ----------------------------------------------------------------
NODE_TAR=/var/cache/eo-node-$EO_NODE_VERSION-linux-x64.tar.xz
python3 - "$NODE_TAR" "https://nodejs.org/dist/$EO_NODE_VERSION/node-$EO_NODE_VERSION-linux-x64.tar.xz" <<'EOF'
import sys, urllib.request, shutil
with urllib.request.urlopen(sys.argv[2], timeout=120) as r, open(sys.argv[1], 'wb') as f:
    shutil.copyfileobj(r, f)
EOF
echo "$EO_NODE_SHA256  $NODE_TAR" | sha256sum -c - || eo_die "Node.js tarball hash mismatch"
rm -rf "/opt/node-$EO_NODE_VERSION"
mkdir -p "/opt/node-$EO_NODE_VERSION"
tar -xJf "$NODE_TAR" -C "/opt/node-$EO_NODE_VERSION" --strip-components=1 --no-same-owner
chown -R root:root "/opt/node-$EO_NODE_VERSION"
ln -sfn "/opt/node-$EO_NODE_VERSION" /opt/node
ln -sfn /opt/node/bin/node /usr/local/bin/node
node --version

# --- Worker base image ------------------------------------------------------
# The fake worker and verification commands run in this image. Built from Debian
# packages only; tests later check it holds no shell history, keys or eo code.
BUILD=/var/lib/eo-build
rm -rf "$BUILD/rootfs"; install -d -m 0755 "$BUILD"
debootstrap --variant=minbase --include=git,python3,ca-certificates,procps,iproute2 \
    trixie "$BUILD/rootfs" http://deb.debian.org/debian
chroot "$BUILD/rootfs" sh -c 'apt-get clean; rm -rf /var/lib/apt/lists/* /var/cache/apt/*'
groupadd -R "$BUILD/rootfs" -g 10001 worker
useradd -R "$BUILD/rootfs" -u 10001 -g 10001 -M -d /work -s /usr/sbin/nologin worker
tar --numeric-owner --sort=name --mtime='2026-01-01 00:00:00Z' -C "$BUILD/rootfs" -cf "$BUILD/eo-worker-base.tar" .
sha256sum "$BUILD/eo-worker-base.tar" | tee "$BUILD/eo-worker-base.tar.sha256"
rm -rf "$BUILD/rootfs"

# --- Network ----------------------------------------------------------------
cat >/etc/systemd/network/10-eoint.link <<EOF
[Match]
MACAddress=$EO_INT_MAC
[Link]
Name=eoint
EOF
cat >/etc/systemd/network/11-eosetup.link <<EOF
[Match]
MACAddress=$EO_SETUP_MAC
[Link]
Name=eosetup
EOF
cat >/etc/network/interfaces <<EOF
# Managed by eo-l2 guest/10-bootstrap.sh
auto lo
iface lo inet loopback

auto eoint
iface eoint inet static
    address $EO_GUEST_IP/$EO_PREFIX

# Temporary setup NIC; removed by guest/20-seal.sh before any eo code runs.
allow-hotplug eosetup
iface eosetup inet dhcp
EOF

# --- Kernel -----------------------------------------------------------------
cat >/etc/modprobe.d/eo-l2-blacklist.conf <<'EOF'
# eo-l2: no host-guest socket channels, no Bluetooth.
install hv_sock /bin/false
install vsock /bin/false
install vsock_loopback /bin/false
install vmw_vsock_virtio_transport /bin/false
install vmw_vsock_virtio_transport_common /bin/false
install vmw_vsock_vmci_transport /bin/false
install bluetooth /bin/false
install btusb /bin/false
EOF
# The blacklist only stops modprobe; root could still insmod the (Debian-signed)
# module file. Remove the host-guest socket modules from the system and keep dpkg
# from installing them again with a kernel update.
cat >/etc/dpkg/dpkg.cfg.d/90-eo-l2-no-vsock <<'EOF'
path-exclude=/usr/lib/modules/*/kernel/net/vmw_vsock/*
path-exclude=/lib/modules/*/kernel/net/vmw_vsock/*
EOF
find /usr/lib/modules /lib/modules -path '*/kernel/net/vmw_vsock/*' -name '*.ko*' -print -delete 2>/dev/null || true
for k in /usr/lib/modules/*; do depmod -a "$(basename "$k")"; done
cat >/etc/sysctl.d/90-eo-l2.conf <<'EOF'
net.ipv4.ip_forward = 0
# sshd binds 192.168.250.2 even if eoint comes up after it.
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
EOF
if ! grep -q 'ipv6.disable=1' /etc/default/grub; then
    sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 ipv6.disable=1"/' /etc/default/grub
fi
grep -q 'ipv6.disable=1' /etc/default/grub || eo_die "could not set ipv6.disable=1"
update-grub
update-initramfs -u

# --- Firewall ---------------------------------------------------------------
install -d -m 0755 /etc/nftables.d
cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Managed by eo-l2. Sealed policy: SSH from the host only; nothing initiated outward.
flush ruleset
table inet eo {
    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state invalid drop
        ct state established,related accept
        iifname "eoint" ip saddr $EO_HOST_IP ip daddr $EO_GUEST_IP tcp dport 22 accept
        include "/etc/nftables.d/*-input.nft"
        limit rate 10/second log prefix "eo-drop-in " level info
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy drop;
        oif lo accept
        ct state established,related accept
        include "/etc/nftables.d/*-output.nft"
        limit rate 10/second log prefix "eo-drop-out " level info
    }
}
EOF
# Setup-only allowances; guest/20-seal.sh deletes these two files.
echo 'iifname "eosetup" udp sport 67 udp dport 68 accept' >/etc/nftables.d/50-setup-input.nft
echo 'oifname "eosetup" accept' >/etc/nftables.d/50-setup-output.nft
nft -c -f /etc/nftables.conf
systemctl enable nftables

# --- Accounts ---------------------------------------------------------------
id eo >/dev/null 2>&1        || useradd --system --create-home --home-dir /home/eo --shell /usr/sbin/nologin eo
id eo-anchor >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin eo-anchor
id eo-worker >/dev/null 2>&1 || useradd --create-home --home-dir /home/eo-worker --shell /usr/sbin/nologin eo-worker
passwd -l eo >/dev/null; passwd -l eo-anchor >/dev/null; passwd -l eo-worker >/dev/null
for u in eo eo-anchor eo-worker; do
    ! id -nG "$u" | grep -Eqw 'sudo|adm|disk|lxd|docker' || eo_die "$u is in a privileged group"
done
# --userns=auto takes per-container ranges from this block (30 x 65536 ids).
sed -i '/^eo-worker:/d' /etc/subuid /etc/subgid
echo 'eo-worker:1000000:1966080' >>/etc/subuid
echo 'eo-worker:1000000:1966080' >>/etc/subgid
loginctl enable-linger eo-worker
chmod 0750 /home/eo /home/eo-worker

# --- SSH --------------------------------------------------------------------
ADMIN_HOME=$(getent passwd eo-admin | cut -d: -f6)
[[ -n $ADMIN_HOME ]] || eo_die "user eo-admin missing (create it in the installer)"
install -d -m 0700 -o eo-admin -g eo-admin "$ADMIN_HOME/.ssh"
install -m 0600 -o eo-admin -g eo-admin "$PUBKEY" "$ADMIN_HOME/.ssh/authorized_keys"
install -d -m 0700 -o eo-admin -g eo-admin "$ADMIN_HOME/.vscode-server" "$ADMIN_HOME/.vscode-server/data" "$ADMIN_HOME/.vscode-server/data/Machine"
cat >"$ADMIN_HOME/.vscode-server/data/Machine/settings.json" <<'EOF'
{
    "remote.autoForwardPorts": false,
    "remote.restoreForwardedPorts": false
}
EOF
chown eo-admin:eo-admin "$ADMIN_HOME/.vscode-server/data/Machine/settings.json"
cat >/etc/ssh/sshd_config.d/10-eo-l2.conf <<EOF
# Managed by eo-l2 guest/10-bootstrap.sh
ListenAddress $EO_GUEST_IP
AddressFamily inet
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers eo-admin@$EO_HOST_IP
AllowAgentForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
X11Forwarding no
GatewayPorts no
PermitListen none
PermitUserEnvironment no
# VS Code Remote-SSH talks to its server through a local (host-initiated)
# forward to the guest's loopback; nothing else may be forwarded.
AllowTcpForwarding local
PermitOpen 127.0.0.1:* localhost:*
MaxAuthTries 3
LoginGraceTime 30
EOF
# sshd must start after eoint has its address.
install -d /etc/systemd/system/ssh.service.d
cat >/etc/systemd/system/ssh.service.d/10-eo-l2.conf <<'EOF'
[Unit]
Wants=network-online.target
After=network-online.target
EOF
sshd -t
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable ssh.service

dpkg-query -W -f='${Package} ${Version}\n' | sort >"$EO_EVIDENCE/$EO_STAMP-packages.txt"
echo "host key fingerprints:"; for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k"; done
echo
echo "GUEST STEP 10 DONE. Reboot now (sudo systemctl reboot); then run 11-storage.sh."
