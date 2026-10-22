# r6 crash-recovery run at 72fe3f3: INTERRUPTED, not counted

- Commit: 72fe3f3944d1f151efc1a37f84c1098778933311 (worktree clean, dirty=0)
- Command: `EO_REQUIRE_BD=1 EO_TEST_STORE=beads EO_BD_BIN=/opt/beads-9c6f6e1/bd node --test --test-reporter=tap --test-concurrency=1 tests/behavioral/crash-recovery.test.ts`
- Started 2026-10-19T04:34:59Z. No exit line was ever written (see `DONE`).
- Last progress record: 2026-10-19T05:34:55Z, "M1-4 every boundary", boundary 35 of 70, 34 completed, activity "resume finished" (see `progress-m1-4.jsonl`).
- Cause: the container was restarted. At 15:03:30Z its uptime was 0 minutes and no node or bd processes existed. Files on disk survived; processes did not. Nothing in the progress record points to a stall or a test failure before the restart: the last recorded step came 6 s after the previous one, at the same pace as boundaries 1 to 34.
- Result: none. 34 of 70 boundaries passed their checks before the restart, but a partial run is not acceptance evidence. `behavioral.tap` holds only the TAP header.
- Replacement: r7, a complete run of the same command at the same commit, started 2026-10-19T15:05:49Z.
- Also note: this run overlapped the r6 claims race (04:30:34Z to 05:07:45Z), because its queue waited on r4 rather than on r6. r7 runs alone.
