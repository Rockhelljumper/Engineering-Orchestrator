#!/bin/bash
# Counted FakeStore suites at one commit: unit, integration, behavioural, typecheck.  suites-run.sh <checkout> <out dir>
R=$1; O=$2; cd "$R" || exit 2
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$O/suites.log"; }
log "commit $(git rev-parse HEAD) dirty=$(git status --porcelain | wc -l) node $(node --version) bd-env=${EO_BD_BIN:-none}"
log "unit"; node --test "tests/unit/**/*.test.ts" > "$O/unit.tap" 2>&1; log "unit exit $? $(grep -E '^# (pass|fail|skipped)' "$O/unit.tap" | tr '\n' ' ')"
log "integration"; node --test --test-concurrency=1 "tests/integration/**/*.test.ts" > "$O/integration.tap" 2>&1; log "integration exit $? $(grep -E '^# (pass|fail|skipped)' "$O/integration.tap" | tr '\n' ' ')"
log "behavioral"; node --test --test-concurrency=1 "tests/behavioral/**/*.test.ts" > "$O/behavioral.tap" 2>&1; log "behavioral exit $? $(grep -E '^# (pass|fail|skipped)' "$O/behavioral.tap" | tr '\n' ' ')"
log "typecheck"; /opt/node-tools/node_modules/.bin/tsc --noEmit -p . --typeRoots /opt/node-tools/node_modules/@types > "$O/typecheck.txt" 2>&1; log "typecheck exit $?"
log "suites done"
