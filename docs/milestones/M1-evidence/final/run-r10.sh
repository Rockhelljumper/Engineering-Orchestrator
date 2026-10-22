#!/bin/bash
# r10: rerun of the Beads crash-recovery suite and the Beads mutation check at e8fdaa4, after a
# container restart interrupted them. The three crash tests are independent (own sandboxes), so
# they run as three processes at once to shorten the exposure to another restart.
S=/tmp/claude-0/-home-claude-Engineering-Orchestrator/1994d459-4dcf-5bd8-a13c-602ea0e44623/scratchpad
D=$S/final-e8fdaa4-beads; O=$S/final-e8fdaa4/beads-r10; mkdir -p $O; BD=/opt/beads-9c6f6e1/bd
export EO_REQUIRE_BD=1 EO_REQUIRE_TRACE=1 EO_TEST_STORE=beads EO_BD_BIN=$BD EO_EVIDENCE_DIR=$O EO_PROGRESS_FILE=$O/progress.jsonl
env_line() { echo "commit $(git -C $1 rev-parse HEAD) dirty=$(git -C $1 status --porcelain | wc -l) node=$(node --version) bd=$(sha256sum < $BD | cut -d' ' -f1) host=$(uname -srm)"; }
crash() { # name pattern
  echo "$1 start $(date -u +%FT%TZ) $(env_line $D)" >> $O/DONE
  (cd $D && node --test --test-reporter=tap --test-concurrency=1 --test-name-pattern="$2" tests/behavioral/crash-recovery.test.ts > $O/$1.tap 2>&1); echo "$1 exit=$? $(date -u +%FT%TZ)" >> $O/DONE
}
crash behavioral-every-boundary 'crash after every journal step boundary' &
crash behavioral-random-kills 'random SIGKILLs' &
crash behavioral-escalation 'ends in an escalation' &
( echo "mutation start $(date -u +%FT%TZ) $(env_line $S/final-e8fdaa4-mutb)" >> $O/DONE
  { echo "# beads mutation check at $(git -C $S/final-e8fdaa4-mutb rev-parse HEAD), started $(date -u +%FT%TZ)"; python3 -I $S/mutate-beads-final2.py $S/final-e8fdaa4-mutb; echo "# finished $(date -u +%FT%TZ)"; } > $O/mutation-check.txt 2>&1
  echo "mutation exit=$? $(date -u +%FT%TZ)" >> $O/DONE ) &
wait
echo "chain finished $(date -u +%FT%TZ)" >> $O/DONE
