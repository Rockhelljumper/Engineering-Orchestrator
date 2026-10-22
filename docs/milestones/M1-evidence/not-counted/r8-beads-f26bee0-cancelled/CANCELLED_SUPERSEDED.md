# r8 — CANCELLED_SUPERSEDED

- **Status:** CANCELLED_SUPERSEDED. Does not count towards any acceptance criterion.
- **Commit:** f26bee0c5b4d6a591d2b3c246bba961ae5b117b1 (worktree `scratchpad/r8-tree`, clean tree), bd 2589f95d65136897a5228cb829b7b3bbf755468b26689b764b6816d4d07697ef.
- **Cancelled:** 2026-10-19T21:54:05.459Z, SIGTERM to process group 12308 (session 12308: runner script 12308, `node --test` 26452/26461 and, at that instant, one `bd init` 30507 for a new scenario sandbox; see process-tree-before-cancel.txt). Its launching shell 12306 (session 12218, only child 12308) exited with it. No r8 process remained 25 s later.
- **Authorised by:** the owner, 2026-10-19T21:53:28Z ("Cancel superseded crash-recovery run").
- **Reason:** f26bee0 predates the rollback fix (ac54edd..e8fdaa4), so its result cannot qualify the final commit e8fdaa4. Cancelling it frees CPU for the counted e8fdaa4 run.
- **Independence check before cancelling:** the r8 tree (session/process group 12308, cwd r8-tree, its own /tmp/eo-test-* sandboxes) and the e8fdaa4 run (session/process group 27305, cwd final-e8fdaa4-beads, its own sandboxes) shared no process, worktree, sandbox, progress file or evidence directory; the only shared input is the read-only source binary /opt/beads-9c6f6e1/bd, which each store copies.
- **Progress at cancellation** (from progress-before-cancel.jsonl):
  - integration: exit 0; controller-unit: exit 0; M1-3 claim race: exit 0 (100/100);
  - crash recovery test 1, every boundary: 70/70, `ok 1` in behavioral.tap;
  - crash recovery test 2, random SIGKILLs: 8/8 seeds completed per progress (21:39:58Z); its TAP line had not been written;
  - crash recovery test 3, escalation boundaries: last completed boundary 10 of 37 (21:53:57.809Z); boundary 11 had just begun.
- **After cancelling:** the e8fdaa4 run (process group 27305) was still active, at boundary 41/70 of test 1, last activity 16 s earlier.
- Files: the runner's DONE, TAP files, strace logs and progress.jsonl as they were at cancellation, plus process-tree-before-cancel.txt.
