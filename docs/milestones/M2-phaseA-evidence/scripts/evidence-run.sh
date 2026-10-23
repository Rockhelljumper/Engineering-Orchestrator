#!/bin/bash
# M2 Phase A final evidence: every long suite under the durable runner at one commit.
#   evidence-run.sh <checkout> <evidence dir> <group: fake|beads|drills>
R=$1; E=$2; G=$3; mkdir -p "$E"; cd "$R" || exit 2
D="node tests/support/durable/cli.ts"
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$E/evidence-$G.log"; }
run() { # name, args...
  local name=$1; shift
  if [ -d "$E/$name" ]; then log "resume $name"; $D resume "$E/$name" > "$E/$name.final.json" 2> "$E/$name.stderr"; else log "start $name: $*"; $D start "$E/$name" "$@" > "$E/$name.final.json" 2> "$E/$name.stderr"; fi
  local rc=$?; log "$name exit $rc status $(python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); print(a["status"], a["passed"], "/", a["declared"])' "$E/$name.final.json" 2>/dev/null || echo unreadable)"
}
log "commit $(git rev-parse HEAD) group $G"
case $G in
  fake)
    run crash-sample-journal --suite crash-sample --param phase=journal &
    run crash-sample-anchor --suite crash-sample --param phase=anchor &
    wait
    run crash-escalation-journal --suite crash-escalation --param phase=journal &
    run crash-escalation-anchor --suite crash-escalation --param phase=anchor &
    wait
    run random-kills --suite random-kills --param seeds=8
    run claim-race-fake --suite claim-race --param store=fake --param rounds=100 --param workers=20
    ;;
  beads)
    export EO_TEST_STORE=beads EO_BD_BIN=/opt/beads-9c6f6e1/bd EO_REQUIRE_BD=1
    run beads-crash-sample-journal --suite crash-sample --param phase=journal
    run beads-crash-sample-anchor --suite crash-sample --param phase=anchor
    run beads-crash-escalation-journal --suite crash-escalation --param phase=journal
    run beads-crash-escalation-anchor --suite crash-escalation --param phase=anchor
    run beads-random-kills --suite random-kills --param seeds=8
    run beads-claim-race --suite claim-race --param store=beads --param rounds=20 --param workers=10
    log "beads unit+integration"
    node --test --test-concurrency=1 tests/unit/*.test.ts tests/integration/*.test.ts > "$E/beads-unit-integration.tap" 2>&1; log "beads unit+integration exit $?"
    ;;
  drills)
    log "drill crash-escalation"
    node tests/support/durable/drill.ts "$E/drill-crash-escalation" --suite crash-escalation --param phase=anchor --kills 3 --stall-window 5 --seed 11 > "$E/drill-crash-escalation.log" 2>&1; log "drill crash-escalation exit $?"
    log "drill claim-race"
    node tests/support/durable/drill.ts "$E/drill-claim-race" --suite claim-race --param store=fake --param rounds=30 --param workers=10 --kills 3 --stall-window 5 --seed 12 > "$E/drill-claim-race.log" 2>&1; log "drill claim-race exit $?"
    ;;
esac
log "group $G done"
