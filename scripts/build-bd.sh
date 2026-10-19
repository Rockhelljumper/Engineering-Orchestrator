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
#
# Runs on Linux and, under Git Bash, on Windows (where the output should end in .exe).
set -euo pipefail

src=${1:?usage: build-bd.sh <beads-checkout> <output-binary>}
out=${2:?usage: build-bd.sh <beads-checkout> <output-binary>}
here=$(cd "$(dirname "$0")/.." && pwd)
GO=${GO:-go}

lock() { node -e 'const l=require(process.argv[1]); const v=process.argv[2].split(".").reduce((o,k)=>o?.[k],l); console.log(v ?? "")' "$here/deps.lock.json" "$1"; }
case "$(uname -s)" in
  Linux) plat=linux ;;
  MINGW*|MSYS*|CYGWIN*) plat=windows ;;
  *) plat=$(uname -s | tr '[:upper:]' '[:lower:]') ;;
esac
case "$(uname -m)" in x86_64|amd64) plat=$plat-amd64 ;; *) plat=$plat-$(uname -m) ;; esac
pin=$(lock beads.revision)
want_go=$(lock go.version)

rev=$(git -C "$src" rev-parse HEAD)
[ "$rev" = "$pin" ] || { echo "build-bd: checkout is at $rev, pinned revision is $pin" >&2; exit 1; }
[ -z "$(git -C "$src" status --porcelain --ignored)" ] || { echo "build-bd: checkout has local changes or untracked files" >&2; exit 1; }

export GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=readonly GOSUMDB=sum.golang.org GOWORK=off
export CGO_ENABLED=1 CC=gcc GOENV=off BD_DISABLE_METRICS=1 DO_NOT_TRACK=1
# CGO links against the host C library and compiles go-sqlite3 with the host gcc, so the
# hash reproduces only with the same C toolchain; no ambient C flags may leak in.
unset CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS CGO_FFLAGS
have_go=$("$GO" env GOVERSION)
[ "$have_go" = "$want_go" ] || { echo "build-bd: $GO is $have_go, need $want_go" >&2; exit 1; }

# The C toolchain and C library the pinned hash for this platform was built with, if any.
want_cc=$(lock "beads.binaries.$plat.cc")
want_libc=$(lock "beads.binaries.$plat.libc")
have_cc="gcc $(gcc -dumpfullversion)"
if [ "${plat%%-*}" = linux ]; then
  have_libc="glibc $(getconf GNU_LIBC_VERSION | cut -d' ' -f2)"
else
  have_libc=$(gcc -dumpmachine)
fi
echo "build-bd: $plat, revision $rev, $have_go, $have_cc, $have_libc, GOTOOLCHAIN=$GOTOOLCHAIN GOPROXY=$GOPROXY" >&2
if [ -z "$want_cc" ]; then
  echo "build-bd: note: deps.lock.json has no pinned bd build for $plat yet" >&2
elif [ "$have_cc" != "$want_cc" ] || [ "$have_libc" != "$want_libc" ]; then
  echo "build-bd: warning: the pinned hash was produced with $want_cc and $want_libc; expect a different SHA-256" >&2
fi
(cd "$src" && "$GO" mod verify) >&2

# Flags follow beads' own Makefile `build` target (tags gms_pure_go, main.Build), plus
# -trimpath so the binary does not embed the checkout or module-cache paths.
mkdir -p "$(dirname "$out")"
build=(env -C "$src" "$GO" build -v -trimpath -tags gms_pure_go
  -ldflags "-X main.Build=${rev:0:7}" -o "$(realpath -m "$out")" ./cmd/bd)
if unshare -n true 2>/dev/null; then
  echo "build-bd: compiling inside an empty network namespace" >&2
  unshare -n "${build[@]}" >&2
else
  echo "build-bd: unshare -n unavailable; relying on GOPROXY=off" >&2
  "${build[@]}" >&2
fi
# Hash from stdin: given a Windows path, sha256sum escapes the name and prefixes the hash with \.
sha256sum < "$out" | cut -d' ' -f1
