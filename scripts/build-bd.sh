#!/usr/bin/env bash
# Build beads (`bd`) from the pinned, reviewed source revision, offline.
#
#   GO=/opt/go1.26.7/bin/go scripts/build-bd.sh <beads-checkout> <output-binary>
#
# Preconditions (done once, online, and recorded in the M1 evidence):
#   - <beads-checkout> is a git checkout of the revision pinned in deps.lock.json;
#   - its modules are in GOMODCACHE, downloaded with `go mod download` and checked by
#     go.sum and sum.golang.org (`go mod verify`).
#
# This script downloads nothing. It refuses a checkout at any other revision or with local
# changes, refuses a Go that is not the pinned version, forbids toolchain switching
# (GOTOOLCHAIN=local) and module fetches (GOPROXY=off, GOFLAGS=-mod=readonly), and runs the
# compile inside an empty network namespace when `unshare -n` is available. The build log
# goes to stderr; the last line on stdout is the binary's SHA-256.
set -euo pipefail

src=${1:?usage: build-bd.sh <beads-checkout> <output-binary>}
out=${2:?usage: build-bd.sh <beads-checkout> <output-binary>}
here=$(cd "$(dirname "$0")/.." && pwd)
GO=${GO:-go}

lock() { node -e 'const l=require(process.argv[1]); console.log(process.argv[2].split(".").reduce((o,k)=>o[k],l))' "$here/deps.lock.json" "$1"; }
pin=$(lock beads.revision)
want_go=$(lock go.version)

rev=$(git -C "$src" rev-parse HEAD)
[ "$rev" = "$pin" ] || { echo "build-bd: checkout is at $rev, pinned revision is $pin" >&2; exit 1; }
[ -z "$(git -C "$src" status --porcelain)" ] || { echo "build-bd: checkout has local changes" >&2; exit 1; }

export GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=readonly GOSUMDB=sum.golang.org GOWORK=off
export CGO_ENABLED=1 BD_DISABLE_METRICS=1 DO_NOT_TRACK=1
have_go=$("$GO" env GOVERSION)
[ "$have_go" = "$want_go" ] || { echo "build-bd: $GO is $have_go, need $want_go" >&2; exit 1; }

echo "build-bd: revision $rev, $have_go, GOTOOLCHAIN=$GOTOOLCHAIN GOPROXY=$GOPROXY" >&2
(cd "$src" && "$GO" mod verify) >&2

# Flags follow beads' own Makefile `build` target (tags gms_pure_go, main.Build), plus
# -trimpath so the binary does not embed the checkout or module-cache paths.
build=(env -C "$src" "$GO" build -v -trimpath -tags gms_pure_go
  -ldflags "-X main.Build=${rev:0:7}" -o "$(realpath -m "$out")" ./cmd/bd)
if unshare -n true 2>/dev/null; then
  echo "build-bd: compiling inside an empty network namespace" >&2
  unshare -n "${build[@]}" >&2
else
  echo "build-bd: unshare -n unavailable; relying on GOPROXY=off" >&2
  "${build[@]}" >&2
fi
sha256sum "$out" | cut -d' ' -f1
