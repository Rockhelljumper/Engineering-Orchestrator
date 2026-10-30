# Shared settings and helpers for the eo-l2 guest scripts. Sourced, never run.
# shellcheck disable=SC2034  # settings used by the scripts that source this file
# shellcheck shell=bash

set -Eeuo pipefail
umask 022

EO_INT_MAC='00:15:5d:e0:02:02'
EO_SETUP_MAC='00:15:5d:e0:02:99'
EO_GUEST_IP='192.168.250.2'
EO_HOST_IP='192.168.250.1'
EO_PREFIX='29'
EO_EVIDENCE='/var/log/eo-l2'

# Node.js 22 (Debian 13 ships 20, and the controller needs >= 22.18 for type
# stripping). Hash from https://nodejs.org/dist/v22.23.4/SHASUMS256.txt, whose
# signature was checked against release key 5BE8A3F6C8A5C01D106C0AD820B1A390B168D356
# (Antoine du Hamel, listed in the nodejs/node README) on 2026-10-29.
EO_NODE_VERSION='v22.23.4'
EO_NODE_SHA256='1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce'

eo_die() { echo "STOP: $*" >&2; exit 1; }
eo_need_root() { [[ $EUID -eq 0 ]] || eo_die "run with sudo"; }

# Every script logs its full output under /var/log/eo-l2 (root-only).
eo_log_start() {
    local step=$1
    install -d -m 0750 -o root -g adm "$EO_EVIDENCE"
    EO_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    EO_LOG="$EO_EVIDENCE/$EO_STAMP-$step.log"
    exec > >(tee -a "$EO_LOG") 2>&1
    echo "eo-l2 guest step: $step"
    echo "log: $EO_LOG"
    echo "time (UTC): $(date -u +%FT%TZ)  host: $(hostname)  kernel: $(uname -r)"
    echo "script sha256: $(sha256sum "$0" | cut -d' ' -f1)"
}

# Print the plan and require the operator to type the step name.
eo_confirm() {
    local step=$1; shift
    echo
    echo "=== Planned changes for guest step '$step' ==="
    local l; for l in "$@"; do echo "  - $l"; done
    echo "==="
    local answer
    read -r -p "Type '$step' to make these changes, anything else to stop: " answer </dev/tty
    [[ $answer == "$step" ]] || eo_die "not confirmed; '$step' stopped before any change"
}

# Interface name for a MAC address, or empty.
eo_if_for_mac() {
    local mac=$1 d
    for d in /sys/class/net/*; do
        [[ -f $d/address ]] || continue
        if [[ $(cat "$d/address") == "$mac" ]]; then basename "$d"; return 0; fi
    done
    return 0
}
