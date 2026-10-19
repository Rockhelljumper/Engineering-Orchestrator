# r3 run interrupted by a container restart

Commit under test: c892111 (source identical to d87fe63 plus docs).

- integration: finished, exit 0 (74/74) at 01:11:39Z.
- controller-unit: finished, exit 0 (25 tests, 23 pass, 2 skipped by design) at 01:28:11Z.
- m1-3-claims-race (beads): started 01:28:11Z, killed by the restart. Not a result.
  Barrier directory at the time: 59 rounds released, 58 rounds with all 20 results;
  in each of those every round had exactly one non-empty result (counted from res-* files after the restart; the test's own store-owner check did not get to report).
- behavioral (crash recovery, beads): started 00:50:06Z, killed by the restart. TAP output is written per finished test,
  so none was recorded. live-sampling.log shows it at boundary 19 of 70 of its first test at 01:23:29Z.
- Last file writes in the test sandboxes: 01:49:21Z. The container came back up at about 01:50Z (uptime 0 min at 01:50:24Z).
  The suites were active until the restart; the interruption was external, not a stall.

All of these are rerun as r4 on the final commit.
