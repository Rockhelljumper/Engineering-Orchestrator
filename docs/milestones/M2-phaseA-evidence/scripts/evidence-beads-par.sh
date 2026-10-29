#!/bin/bash
# Beads evidence group, three suites at a time (the sequential group was ~1.75 h per crash suite).
#   evidence-beads-par.sh <checkout> <evidence dir> <pid of the already-running crash-sample-journal runner>
R=$1; E=$2; P0=$3; cd "$R" || exit 2
export EO_TEST_STORE=beads EO_BD_BIN=/opt/beads-9c6f6e1/bd EO_REQUIRE_BD=1
D="node tests/support/durable/cli.ts"
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$E/evidence-beads.log"; }
st() { python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); print(a["status"], a["passed"], "/", a["declared"])' "$1" 2>/dev/null || echo unreadable; }
run() { local name=$1; shift
  if [ -d "$E/$name" ]; then log "resume $name"; $D resume "$E/$name" > "$E/$name.final.json" 2> "$E/$name.stderr"; else log "start $name: $*"; $D start "$E/$name" "$@" > "$E/$name.final.json" 2> "$E/$name.stderr"; fi
  local rc=$?; log "$name exit $rc status $(st "$E/$name.final.json")"; }
log "parallel continuation, commit $(git rev-parse HEAD); beads-crash-sample-journal still running as pid $P0"
run beads-crash-sample-anchor --suite crash-sample --param phase=anchor &
run beads-crash-escalation-journal --suite crash-escalation --param phase=journal &
wait
run beads-crash-escalation-anchor --suite crash-escalation --param phase=anchor &
run beads-random-kills --suite random-kills --param seeds=8 &
wait
while kill -0 "$P0" 2>/dev/null; do sleep 20; done
$D status "$E/beads-crash-sample-journal" > "$E/beads-crash-sample-journal.status.json"; log "beads-crash-sample-journal status exit $? status $(st "$E/beads-crash-sample-journal.status.json")"
run beads-claim-race --suite claim-race --param store=beads --param rounds=20 --param workers=10
log "beads unit+integration"
node --test --test-concurrency=1 tests/unit/*.test.ts tests/integration/*.test.ts > "$E/beads-unit-integration.tap" 2>&1; log "beads unit+integration exit $?"
log "group beads done"
