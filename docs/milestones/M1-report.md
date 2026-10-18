# M1 report — controller core and durable task store

Scope: the controller core with `FakeStore` and `FakeRunner` and deterministic tests, as approved on 2026-10-18. Nothing was installed, no model was invoked, no host configuration changed, nothing was merged, and no production resource or Proxmox host was touched.

Evidence is stored in [`M1-evidence/`](M1-evidence/). It was produced on Linux x86_64 with Node v22.22.0 at the commit named in the PR, and the TAP files are the raw test output.

Reproduce:

```sh
node --test "tests/unit/**/*.test.ts"                               # 77 tests
node --test --test-concurrency=1 "tests/integration/**/*.test.ts"   # 41 tests
node --test --test-concurrency=1 "tests/behavioral/**/*.test.ts"    # 3 tests, about 3 minutes
tsc -p tsconfig.json                                                # needs typescript + @types/node (see "Tooling")
```

## Acceptance criteria

| AC | Result | Evidence |
|---|---|---|
| M1-1 State machine rejects every illegal transition | **PASS** | All 100 ordered state pairs are checked against an independent table, and that table is checked edge for edge against the diagram in `02-architecture.md` §5 (22 legal edges) ([unit.tap](M1-evidence/unit.tap), `tests/unit/states.test.ts`). The cross-check found `ready → blocked` missing from the diagram (a budget rejection before launch); the edge was added to §5, which is **an amendment for you to approve** |
| M1-2 `BeadsStore` passes the `FakeStore` contract suite | **BLOCKED** | The contract suite exists and passes on FakeStore in memory and on disk: 25 cases covering create, deps, ready, claim, heartbeat, reclaim, notes and close (`tests/integration/store-contract.test.ts`). Testing it against beads needs `bd`, and building `bd` needs Go 1.26.7; only Go 1.24.7 is present. Installing it is not authorised. The adapter will be written together with the approved build, so it is only ever tested against the real binary, never shipped untested |
| M1-3 20 concurrent claims on one ready task, exactly one winner, 100 runs | **PASS** | 20 separate OS processes race for the ready task in each of 100 rounds against one file-backed store. Every round had exactly one winner, and the store's recorded owner matched it ([integration.tap](M1-evidence/integration.tap) test 8). The test fails when the store lock is removed (mutation check) |
| M1-4 Killed at each of N ≥ 12 journal step boundaries; after `eo resume`, same final states; no task executed twice past its intent | **PASS** | The scripted 5-task run has 70 boundaries and includes one verification failure and one worker crash. For each boundary k, `eo run` is killed right after its k-th journal append, then `eo resume` and `eo run` finish the work. For 23 of the boundaries, recovery is itself crashed at a second point. Every run ended in the baseline's final states. No (task, attempt) appears twice in the execution log, and every execution has a journaled attempt start. `eo doctor` is clean and no reservations are left open. A second test delivered 32 random SIGKILLs during attempts across 8 runs, with the same checks. A third sweeps all 37 boundaries of a run that ends in an escalation (attempts exhausted, a dependent stalled), and also requires identical escalation records and exactly one escalation file ([behavioral.tap](M1-evidence/behavioral.tap)) |
| M1-5 Journal tamper detected by `eo doctor` | **PASS** | `eo doctor` exits 1 on an edited journal record and on an altered evidence file, and the controller refuses to resume ([integration.tap](M1-evidence/integration.tap) test 5). Unit tests also cover deleted, reordered, wrongly keyed and spliced records, evidence artefact and manifest changes, and a manifest copied from another attempt. One limit is documented and tested: truncating the journal's final records leaves a valid shorter chain. `eo doctor` reports the resulting store/journal disagreement, but the file alone cannot show it |
| M1-6 No outbound network during the M1-4 scenario | **PASS (controller only)** | Two independent detectors ran during crash, resume, run, doctor and status, each with a positive control proving it catches a connection. The first is a preload that records and refuses every Node network API. The second traces every `connect`/`sendto`/`sendmsg` syscall with `strace -f` inside an empty network namespace (`unshare -n`). Neither recorded anything ([strace log](M1-evidence/m1-6-strace.log)). The `bd` half is blocked with M1-2 |
| M1-7 `bd` built from pinned commit; SHA-256 in `deps.lock.json`; metrics env set on every spawn | **BLOCKED** | Needs the Go 1.26.7 toolchain (not authorised) |
| M1-9 Reproducible offline `bd` build | **BLOCKED** | Same |
| M1-10 Refuse `eo init`/`eo run` on an unapproved repository | **PASS** | `eo run` and `eo plan import` refuse an unapproved repository. The check compares canonical paths, so symlinks and `..` resolve, and subdirectories are not implicitly approved. Nothing is journaled or launched ([unit.tap](M1-evidence/unit.tap), [integration.tap](M1-evidence/integration.tap) test 3). After review, tasks also run only against the repository their plan was approved for, and swapping an approved directory for a symlink does not move the approval. `eo init` takes no repository (it creates only the state root), so there is nothing for it to refuse. Approving a repository, importing a plan and unblocking require a typed confirmation at an interactive terminal; piped input is refused (integration test 2) |
| M1-8 Test suite passes on Windows; `bd` Windows build recorded | **PASS (suite) / BLOCKED (`bd`)** | `.github/workflows/ci.yml` runs all three suites on `ubuntu-24.04` and `windows-2022`. Both passed on commit `b872421` ([Linux job](https://github.com/Rockhelljumper/Engineering-Orchestrator/actions/runs/39171481540/job/117805277748), [Windows job](https://github.com/Rockhelljumper/Engineering-Orchestrator/actions/runs/39171481540/job/117805277472)). On Windows the strace check is skipped, because it is Linux-only; the preload network check runs there. The first Windows run found a real lock bug, now fixed (see below). The `bd` Windows build is blocked with M1-2 |

## Budget governor: reservation semantics

Kyle asked for this to be pinned down. It is now specified in `07-isolation-and-credentials.md` §5.1 and implemented in `src/budget.ts`. Each launch reserves R, which is the invocation cap plus the largest measured turn, or `max(10 × cap, cap + $1)` until M2-6b measures it; tokens follow the same rule. For each task and epic scope there are three outcomes:
- **reject** when `spent + R > cap`. It can never fit, so the task is blocked with an escalation and nothing launches.
- **defer** when `spent + reserved + R > cap`. It may fit after running work settles.
- **admit** otherwise. The reservation is journaled before the attempt starts.

Settlement charges one of three amounts:
- the reported cost, with any overshoot journaled;
- the full R, when the cost is unknown;
- zero, only when the journal proves the attempt never started.

Tests confirming that affordable work starts while unaffordable work is rejected:
- `tests/unit/budget.test.ts` has 18 tests:
  - admit and reject, with no reservation journaled on reject;
  - the exact-cap boundary;
  - defer, then admit after settlement;
  - an epic cap rejecting a task whose own cap would allow it;
  - the token dimension alone;
  - the three settlement bases;
  - an overshoot counting against the next admission;
  - a rebuild from the journal;
  - a property test over 200 random policies × 40 steps against an independent model.
- `tests/unit/controller.test.ts`, end to end through the scheduler:
  - an affordable task launches while an unaffordable retry of another is rejected before launch, as the execution log shows;
  - unknown costs stop retries before the infra limit;
  - an epic cap stops the third task.

Two consequences you should know about:
1. **Default caps changed.** With the old default task cap ($5 and 1M tokens) a single unmeasured reservation ($5 and 2M tokens) could never fit, so every task would have been rejected. The defaults are now $10 / 4M tokens per task and $25 / 20M per epic, and a policy whose single reservation exceeds the task cap is refused at load.
2. Until M2-6b measures the overshoot, the reservation is deliberately pessimistic. A $10 task gets one $5 reservation at a time, and attempts with unknown cost (crash, timeout) are charged the full $5.

## Defects found by the tests and fixed

| Found by | Defect | Fix |
|---|---|---|
| Crash test, boundary 4 | When the controller died between journaling a reservation and journaling the attempt start, the retry reused the reservation id, so `eo run` failed with "duplicate reservation" | Reservation ids are unique per reservation, and settlement finds the id from the attempt-start record |
| Journal unit test | A crash after writing a record but before its newline would make the next append join that line, corrupting the journal | Open terminates such a line first |
| CLI test | `eo doctor` crashed on a task marked `done` that never had an attempt, which is exactly the forgery it should report | Reported as a problem |
| Code reading before the lock tests | A second lock instance in the same process treated its own pid's lock as stale and stole it. Two processes clearing the same stale lock could delete the fresh lock one of them had just taken | Process-wide registry of held locks; stale removal happens under a short breaker lock with a re-check. Covered by the 20-process race and the killed-holder test |
| State machine cross-check | The diagram lacked `ready → blocked` | Diagram amended (see M1-1) |
| Windows CI | Creating a lock file that another process had just deleted but still held open failed with `EPERM` instead of `EEXIST`, crashing claim workers | Treated as busy; transient Windows rename errors are retried |

## Test integrity

The tests' sensitivity was checked by mutation: 8 deliberate bugs, each applied alone ([mutation-check.txt](M1-evidence/mutation-check.txt)):
- an illegal transition allowed;
- the USD cap ignored;
- open reservations ignored;
- the store lock removed;
- never-launched reservations left open on resume;
- the chain link dropped from the journal MAC;
- one extra correction attempt;
- evidence hashes not checked.

All 8 were caught. The chain-link mutant first survived, and a test splicing a record in from a diverged copy of the journal was added to catch it. No test was weakened or skipped. Two expectations were corrected where the test, not the code, was wrong:
- the validator's message format;
- the legal-edge count, which is now derived from the architecture diagram instead of a hard-coded number.

## Tooling and deviations

- **No npm dependencies.** `ajv` was planned (`03-dependency-map.md`), but installing it was not authorised, so a 100-line schema validator covering the needed subset is used (`src/schema.ts`, with tests). Whether to switch to `ajv` later can be decided when installs are approved.
- **Typecheck** used the TypeScript 6.0.2 and `@types/node` already present in this environment (`/opt/node-tools`). Nothing was installed. CI does not typecheck, because that would need an npm install.
- **CI** uses `actions/checkout` and `actions/setup-node`, pinned by full commit SHA, on GitHub's ephemeral runners. It has read-only permissions and no secrets. If you consider the runner's Node download an installation, delete `.github/workflows/ci.yml`, and M1-8 becomes BLOCKED.
- Execution is sequential in M1 (one worker at a time). The `defer` path is exercised in unit tests; through the scheduler it matters only once M5 adds concurrency.
- Human gates are a typed word at a TTY. That is a speed bump, not a security boundary: a pseudo-terminal can satisfy it. The boundary is that agents never get access to the state root (architecture §3, T18).

## Independent review

A separate reviewer read the code adversarially and ran the suites plus its own crash sweep. It found no blockers, 3 major and 8 minor findings, all verified. Each repair below has a new test; the suites and the mutation check were rerun afterwards.

| Severity | Finding | Resolution |
|---|---|---|
| Major | Forged store records were trusted. A task injected into `tasks.json` ran to `done`; editing a task's epic moved its spend to another epic's budget; clearing deps allowed early promotion | `resume` (and so every `run`) refuses a store whose tasks, epics or dependencies differ from the journaled plans, and `doctor` reports them. Budget and promotion take epic and deps from the journal, not the store |
| Major | `eo policy accept` was named in an error but did not exist. Approving a repository wrote the policy file before journaling, so a crash between the two wedged the state root | `eo policy accept` added (interactive). Policy changes are now intent, file, commit; a crash at either point is ignored or completed on the next open (tested both ways) |
| Major | `run --repo B` executed tasks imported for repository A | Tasks run only under the repository journaled with their plan; others are skipped and recorded |
| Minor | A corrupt evidence manifest crashed `doctor` and the controller | Reported as "manifest unreadable" / "malformed" |
| Minor | Tampered evidence was re-sealed during verification, and the journaled seal was never checked | Evidence that was sealed and no longer verifies is escalated. At integration the manifest must match the journaled MAC. A crash between seal and journal is recovered |
| Minor | A malformed reported cost became durable and then made every resume throw | Validated before journaling; an invalid cost is charged as unknown (full reservation) and recorded |
| Minor | Lock edge cases: `release` could delete a replacement lock; the breaker lacked the Windows EPERM handling | Release removes only its own lock (per-acquisition nonce); breaker handles EPERM. Not fixed: a contender paused for more than 10 s inside the stale-lock takeover could still remove a fresh lock. This needs a long process stall at a narrow point and is accepted for M1 (single controller); recorded for M5 |
| Minor | Crash tests never exercised escalation paths; `EO_CRASH_AT` lands only after journal appends | Escalation-scenario sweep added (37 boundaries). Points between non-journal writes are reached only by the random-SIGKILL test; this remains a stated limit |
| Minor | Torn-tail repair messages said `eo resume` but every controller open repairs | Messages corrected (the repair is reported in the resume record) |
| Minor | Approval followed a later symlink swap | Approval compares against the path canonicalised at approval time |
| Nit | Evidence MAC compared with `!==`; journal and evidence share a key without domain separation | Timing-safe compare. The shared key is not exploitable today (the MACed structures differ) and is left for M3, which reworks evidence |

The review confirmed as sound:
- the state machine against §5;
- the budget rules in §5.1 (order of checks, cap boundary, both dimensions, settlement bases, no leaked or unjournaled reservation);
- that nothing executes twice;
- escalation reuse after a crash;
- the counters;
- journal tamper detection;
- the M1-3 race test.

## Next approval gate

M2 (Claude Code worker runner) needs your choice of local isolation tier and a go-ahead for live spend (proposed ≤ $2), per `05` §M2. Unblocking M1-2, M1-7 and M1-9 needs approval to install Go 1.26.7 and build `bd` from the pinned commit.
