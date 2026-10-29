#!/usr/bin/env bash
# Guest step 20: seal the guest before the setup NIC is removed on the host
# (host/04b-remove-setup-nic.ps1). Run as: sudo bash 20-seal.sh
# Removes every setup-time network allowance, then powers the guest off.
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
eo_need_root
eo_log_start seal

[[ -z $(ls -A /srv/eo 2>/dev/null) ]] || eo_die "/srv/eo is not empty: eo code or data arrived before sealing"
[[ ! -e /opt/eo ]] || eo_die "/opt/eo exists before sealing"
mountpoint -q /srv/eo-anchor || eo_die "run 11-storage.sh first"

eo_confirm seal \
  "Remove the eosetup stanza from /etc/network/interfaces and its .link file" \
  "Delete /etc/nftables.d/50-setup-*.nft and reload nftables (sealed policy)" \
  "Empty /etc/resolv.conf; mask apt-daily timers (there is no network to update from)" \
  "Record the sealed configuration, then power off so the host can remove the setup NIC"

python3 - <<'EOF'
import re
p = '/etc/network/interfaces'
s = open(p).read()
s = re.sub(r'\n# Temporary setup NIC.*?\niface eosetup inet dhcp\n', '\n', s, flags=re.S)
assert 'eosetup' not in s, s
open(p, 'w').write(s)
EOF
rm -f /etc/systemd/network/11-eosetup.link /etc/nftables.d/50-setup-input.nft /etc/nftables.d/50-setup-output.nft
ifdown --force eosetup 2>/dev/null || true
: >/etc/resolv.conf
rm -f /etc/dhcp/dhclient-exit-hooks.d/eo-* 2>/dev/null || true
systemctl mask --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
systemctl restart nftables
nft list ruleset
if grep -q eosetup /etc/network/interfaces; then eo_die "eosetup still configured"; fi
if compgen -G "/etc/nftables.d/*setup*" >/dev/null; then eo_die "setup firewall allowances still present"; fi
sha256sum /etc/network/interfaces /etc/nftables.conf /etc/ssh/sshd_config.d/10-eo-l2.conf /etc/modprobe.d/eo-l2-blacklist.conf /etc/sysctl.d/90-eo-l2.conf /etc/default/grub
update-initramfs -u
echo "GUEST STEP 20 DONE. Powering off; next run host/04b-remove-setup-nic.ps1."
sync
systemctl poweroff
