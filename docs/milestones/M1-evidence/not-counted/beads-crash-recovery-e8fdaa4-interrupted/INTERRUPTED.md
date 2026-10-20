# Beads crash recovery at e8fdaa4 — INTERRUPTED (does not count)

- **Commit:** e8fdaa45e31dad83325b0535cbafd19f0877af6f (worktree `final-e8fdaa4-beads`, clean), bd 2589f95d…97ef.
- **Started:** 2026-10-19T20:02:24Z (DONE). No exit status was written.
- **Cause:** a cloud container restart. The machine was found at 2026-10-20T02:25Z with uptime 0 minutes and no test process running; the session's own turn had also been cut off at about 22:48Z.
- **Last completed scenario:** {"ts":"2026-10-19T22:52:44.229Z","test":"M1-4 every boundary","scenario":"boundary 67","completed":67,"total":70,"activity":"completed","elapsedS":10063}
- **Last progress line:** {"ts":"2026-10-19T22:52:44.229Z","test":"M1-4 every boundary","scenario":"boundary 68","completed":67,"total":70,"activity":"begin","elapsedS":10063}
- **State:** test 1 (every boundary) had completed 67 of 70 boundaries with no failure (an assertion failure ends the test, so it would not have continued); tests 2 and 3 had not started. The TAP file holds only its header, because node writes a test's result when the test ends.
- **Follow-up:** the crash-recovery suite and the Beads mutation check are rerun at the same commit (run r10). Every other e8fdaa4 suite had already finished and is counted.
