# r7 crash-recovery run at 72fe3f3: CANCELLED, not counted

- Commit: 72fe3f3944d1f151efc1a37f84c1098778933311 (worktree clean)
- Command: `EO_REQUIRE_BD=1 EO_TEST_STORE=beads EO_BD_BIN=/opt/beads-9c6f6e1/bd node --test --test-reporter=tap --test-concurrency=1 tests/behavioral/crash-recovery.test.ts`
- Started 2026-10-19T15:05:49Z; cancelled 2026-10-19T16:29:11Z with SIGTERM to its process group, on the owner's instruction of 16:28 UTC.
- Progress at cancellation: "M1-4 every boundary", 30 of 70 boundaries completed, boundary 31 in progress (`progress-before-cancel.jsonl`, copied before the signal; `progress.jsonl` after it). No failure had been recorded.
- Why: the final review found that resume could rewind a store that is ahead of the journal (critical), so 72fe3f3 is not the final implementation and this run cannot qualify it.
