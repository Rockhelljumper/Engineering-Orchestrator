#!/usr/bin/env bash
# Guest step 11: storage layout. Run as: sudo bash 11-storage.sh
#   - anchor disk (the 4 GiB disk with no signatures): VG eo-anchor, LV anchor,
#     ext4 at /srv/eo-anchor, owner eo-anchor, mode 0700. Never snapshotted.
#   - system disk free space in VG eo-sys: LV eo-state (32 GiB, fixed) at /srv/eo
#     for the controller's state root and mirror, owner eo, mode 0700; thin pool
#     eo-work (autoextend off) with thin LV worker at /home/eo-worker for rootless
#     container storage and per-attempt volumes.
# No network needed.
# shellcheck source=_lib.sh
source "$(dirname "$0")/_lib.sh"
eo_need_root
eo_log_start storage

vgs eo-sys >/dev/null || eo_die "volume group eo-sys missing"
! vgs eo-anchor >/dev/null 2>&1 || eo_die "volume group eo-anchor already exists"
! lvs eo-sys/eo-state >/dev/null 2>&1 || eo_die "LV eo-sys/eo-state already exists"

# The anchor disk: exactly 4 GiB, not holding the root PV, with no signatures.
ROOT_PVS=$(pvs --noheadings -o pv_name --select vg_name=eo-sys | tr -d ' ')
ANCHOR=''
while read -r name size type; do
    [[ $type == disk && $size == 4294967296 ]] || continue
    dev=/dev/$name
    if grep -q "^$dev" <<<"$ROOT_PVS"; then continue; fi
    if [[ -n $(wipefs -n "$dev" 2>/dev/null | tail -n +2) ]]; then eo_die "$dev has existing signatures; refusing"; fi
    [[ -z $ANCHOR ]] || eo_die "more than one 4 GiB candidate disk"
    ANCHOR=$dev
done < <(lsblk -b -dn -o NAME,SIZE,TYPE)
[[ -n $ANCHOR ]] || eo_die "anchor disk (4 GiB, blank) not found"
FREE=$(vgs --noheadings --units b --nosuffix -o vg_free eo-sys | tr -d ' ')
(( FREE > 100 * 1024**3 )) || eo_die "less than 100 GiB free in eo-sys ($FREE bytes)"

eo_confirm storage \
  "pvcreate $ANCHOR; vgcreate eo-anchor; lvcreate eo-anchor/anchor 100%FREE; mkfs.ext4; mount /srv/eo-anchor (eo-anchor, 0700)" \
  "lvcreate eo-sys/eo-state 32G; mkfs.ext4; mount /srv/eo (eo, 0700)" \
  "lvcreate thin pool eo-sys/eo-work (all but 8 GiB of the remaining space, autoextend off)" \
  "lvcreate thin eo-sys/worker (pool size less 1 GiB, not over-provisioned); mkfs.ext4; mount /home/eo-worker (eo-worker, 0750)" \
  "fstab entries with nodev,nosuid (and noexec for /srv/eo-anchor)"

pvcreate "$ANCHOR"
vgcreate eo-anchor "$ANCHOR"
lvcreate -y -n anchor -l 100%FREE eo-anchor
mkfs.ext4 -q -L eo-anchor /dev/eo-anchor/anchor

lvcreate -y -n eo-state -L 32G eo-sys
mkfs.ext4 -q -L eo-state /dev/eo-sys/eo-state

FREE=$(vgs --noheadings --units g --nosuffix -o vg_free eo-sys | tr -d ' ' | cut -d. -f1)
POOL=$(( FREE - 8 ))
lvcreate -y --type thin-pool -n eo-work -L "${POOL}G" eo-sys
lvchange --monitor y eo-sys/eo-work
# Not over-provisioned: the thin LV is no larger than its pool.
lvcreate -y --type thin -n worker -V "$(( POOL - 1 ))G" --thinpool eo-sys/eo-work
mkfs.ext4 -q -L eo-worker /dev/eo-sys/worker

# Autoextend stays off: a full worker pool must fail the worker, never the journal.
[[ $(lvmconfig --type full activation/thin_pool_autoextend_threshold) == *=100 ]] || \
    eo_die "thin_pool_autoextend_threshold is not 100 (autoextend on)"

install -d -m 0700 /srv/eo /srv/eo-anchor
cat >>/etc/fstab <<'EOF'
# eo-l2 (guest/11-storage.sh)
/dev/eo-sys/eo-state    /srv/eo         ext4 defaults,nodev,nosuid 0 2
/dev/eo-anchor/anchor   /srv/eo-anchor  ext4 defaults,nodev,nosuid,noexec 0 2
/dev/eo-sys/worker      /home/eo-worker ext4 defaults,nodev,nosuid 0 2
EOF
systemctl daemon-reload
mount /srv/eo
mount /srv/eo-anchor
# Move eo-worker's (still empty) home onto its own LV.
tmp=$(mktemp -d); cp -a /home/eo-worker/. "$tmp"/
mount /home/eo-worker
cp -a "$tmp"/. /home/eo-worker/; rm -rf "$tmp"
rm -rf /srv/eo/lost+found /srv/eo-anchor/lost+found /home/eo-worker/lost+found
chown eo:eo /srv/eo; chmod 0700 /srv/eo
chown eo-anchor:eo-anchor /srv/eo-anchor; chmod 0700 /srv/eo-anchor
chown eo-worker:eo-worker /home/eo-worker; chmod 0750 /home/eo-worker

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
lvs -a -o lv_name,vg_name,lv_size,pool_lv,lv_attr,data_percent
ls -ld /srv/eo /srv/eo-anchor /home/eo-worker
echo "GUEST STEP 11 DONE."
