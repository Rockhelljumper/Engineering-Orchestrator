#!/bin/bash
# Final M1 verification at one exact commit: every mandatory suite, each in its own worktree.
#   run-final.sh <commit>
S=/tmp/claude-0/-home-claude-Engineering-Orchestrator/1994d459-4dcf-5bd8-a13c-602ea0e44623/scratchpad
C=$1; SH=${C:0:7}
E=$S/final-$SH; mkdir -p $E
BD=/opt/beads-9c6f6e1/bd
for t in fake beads mut mutb; do git -C $S/m1-dev2 worktree add -q --detach $S/final-$SH-$t $C; done
env_line() { echo "commit $(git -C $1 rev-parse HEAD) dirty=$(git -C $1 status --porcelain | wc -l) node=$(node --version) bd=$(sha256sum < $BD | cut -d' ' -f1) strace=$(strace -V 2>&1 | head -1) host=$(uname -srm)"; }
suite() { # dir out name args...
  local d=$1 o=$2 n=$3; shift 3
  echo "$n start $(date -u +%FT%TZ) $(env_line $d)" >> $o/DONE
  (cd $d && node --test --test-reporter=tap --test-concurrency=1 "$@" > $o/$n.tap 2>&1); echo "$n exit=$? $(date -u +%FT%TZ)" >> $o/DONE
}
# Chain 1: FakeStore suites, typecheck, FakeStore mutation check.
(
  O=$E/fake; mkdir -p $O; D=$S/final-$SH-fake
  export EO_EVIDENCE_DIR=$O EO_PROGRESS_FILE=$O/progress.jsonl EO_REQUIRE_TRACE=1
  suite $D $O unit "tests/unit/**/*.test.ts"
  suite $D $O integration "tests/integration/**/*.test.ts"
  suite $D $O behavioral "tests/behavioral/**/*.test.ts"
  (cd $D && /opt/node-tools/node_modules/.bin/tsc -p tsconfig.json --typeRoots /opt/node-tools/node_modules/@types > $O/typecheck.txt 2>&1); echo "typecheck exit=$? $(date -u +%FT%TZ)" >> $O/DONE
  { echo "# mutation check at $(git -C $S/final-$SH-mut rev-parse HEAD), started $(date -u +%FT%TZ)"; python3 -I $S/mutate-final2.py $S/final-$SH-mut; echo "# finished $(date -u +%FT%TZ)"; } > $O/mutation-check.txt 2>&1
  echo "chain finished $(date -u +%FT%TZ)" >> $O/DONE
) &
# Chain 2: every Beads-backed suite (EO_REQUIRE_BD=1, so a missing bd fails rather than skips), then the Beads mutation check.
(
  O=$E/beads; mkdir -p $O; D=$S/final-$SH-beads
  export EO_REQUIRE_BD=1 EO_REQUIRE_TRACE=1 EO_TEST_STORE=beads EO_BD_BIN=$BD EO_EVIDENCE_DIR=$O EO_PROGRESS_FILE=$O/progress.jsonl
  suite $D $O integration tests/integration/store-contract.test.ts tests/integration/beads.test.ts tests/integration/cli.test.ts tests/integration/no-network.test.ts
  suite $D $O controller-unit tests/unit/controller.test.ts
  suite $D $O m1-3-claims-race --test-name-pattern='M1-3 \(beads\)' tests/integration/concurrent-claims.test.ts
  suite $D $O behavioral tests/behavioral/crash-recovery.test.ts
  { echo "# beads mutation check at $(git -C $S/final-$SH-mutb rev-parse HEAD), started $(date -u +%FT%TZ)"; python3 -I $S/mutate-beads-final2.py $S/final-$SH-mutb; echo "# finished $(date -u +%FT%TZ)"; } > $O/mutation-check.txt 2>&1
  echo "chain finished $(date -u +%FT%TZ)" >> $O/DONE
) &
wait
echo "all finished $(date -u +%FT%TZ)" >> $E/ALLDONE
