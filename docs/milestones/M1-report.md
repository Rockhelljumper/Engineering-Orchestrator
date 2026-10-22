# M1 report — controller core and durable task store

Scope: the controller core, the `FakeStore` and `BeadsStore` task stores, the fake runner, and deterministic tests. It covers the work approved on 2026-10-18, plus the M1 amendments approved later that day:
- the `ready → blocked` transition;
- default task limits of $10 / 4M tokens and epic limits of $25 / 20M tokens (accounting limits only);
- installing Go 1.26.7 and building beads from its pinned revision;
- using that Go on disposable GitHub-hosted Windows runners to build and test beads (`GOTOOLCHAIN=local`; nothing installed on the owner's workstation).

No model was invoked, no API credit was spent, and nothing was merged or deployed. No VM or container was created, and no production system or Proxmox host was touched. Telemetry is off on every `bd` spawn.

## Status

**Final source commit: `e8fdaa45e31dad83325b0535cbafd19f0877af6f` (`e8fdaa4`).** Every counted run below tested this commit with a clean tree. Later commits on the PR change only `docs/` (this report and the evidence); `git diff e8fdaa4 HEAD -- src tests scripts deps.lock.json .github package.json tsconfig.json` is empty.

**Every mandatory M1 suite PASSED at `e8fdaa4`**, on Linux (FakeStore and the pinned Beads build) and in CI on Linux and Windows. All ten acceptance criteria are PASSED; criterion 5 of the owner's rollback requirements is met as a documented residual risk (M2-0b). No criterion is RUNNING, INTERRUPTED, BLOCKED or NOT VERIFIED.

Result states used here: **PASSED**, **FAILED**, **RUNNING**, **INTERRUPTED**, **BLOCKED**, **NOT VERIFIED**.

## How results are counted

A criterion counts only if it passed in a **complete, attributable run**: every suite finished, and the run records the commit (clean tree), the `bd` binary hash, the Node version, the platform, and start and end times (written by the runner into `DONE` before and after each suite; the strace version too, except in r10). The exact commands are in the runner scripts [run-final.sh](M1-evidence/final/run-final.sh) and [run-r10.sh](M1-evidence/final/run-r10.sh). Runs that were interrupted, failed, were cancelled, or tested an earlier commit are kept under [`M1-evidence/not-counted/`](M1-evidence/not-counted/) and never count; see [Runs that do not count](#runs-that-do-not-count).

| Item | Value |
|---|---|
| Platform (Linux runs) | Linux 6.18.44 x86_64, Node v22.22.0, strace 6.8, Go go1.26.7 linux/amd64, gcc 13.3.0, glibc 2.39 |
| beads source | `gastownhall/beads` @ `9c6f6e15cdfdc4478e634520e8320795914e68e5` (module `github.com/steveyegge/beads`, v1.3.0) |
| `bd` linux-amd64 SHA-256 | `2589f95d65136897a5228cb829b7b3bbf755468b26689b764b6816d4d07697ef` |
| `bd` windows-amd64 SHA-256 | `0b4d916b7076bb8ef7ab45882f6b7183399a90395ffbd867fb0b704ff12664f1` (gcc 14.2.0, x86_64-w64-mingw32, GitHub windows-2022 image) |
| Go toolchain zip (Windows CI) | `golang.org/toolchain@v0.0.1-go1.26.7.windows-amd64`, SHA-256 `ccada8b506d8a99124bd4654f15c74974c5d32f93b705b5c6081b76d629026b4` |

## Acceptance criteria

| AC | Result | Evidence (all at `e8fdaa4`) |
|---|---|---|
| M1-1 State machine rejects every illegal transition | **PASSED** | All 100 ordered state pairs checked against an independent table, itself checked edge for edge against `02-architecture.md` §5 (22 legal edges, including the approved `ready → blocked`): `tests/unit/states.test.ts` in [final/fake/unit.tap](M1-evidence/final/fake/unit.tap); Linux and Windows CI |
| M1-2 `BeadsStore` passes the `FakeStore` contract suite | **PASSED** | The same 17-case contract suite runs on FakeStore on disk and on BeadsStore (the in-memory FakeStore runs 16, without the durability case) against the pinned `bd`: Linux [final/beads/integration.tap](M1-evidence/final/beads/integration.tap) (83/83); Windows [beads-windows job](M1-evidence/final/ci-e8fdaa4/beads-windows-job-118212596185.log.summary.txt) (77 pass, 10 platform skips, 0 fail) |
| M1-3 20 concurrent claims on one ready task, exactly one winner, 100 runs | **PASSED** | 20 OS processes race in each of 100 rounds; exactly one winner per round, and the store's owner is that winner. FakeStore: [final/fake/integration.tap](M1-evidence/final/fake/integration.tap) (PASSED). BeadsStore Linux: [final/beads/m1-3-claims-race.tap](M1-evidence/final/beads/m1-3-claims-race.tap) (1/1, 100 rounds, 56 min, PASSED). BeadsStore Windows: beads-windows job (PASSED). Mutation: dropping the revision guard (Beads) or the store lock (FakeStore) fails it |
| M1-4 Killed at each of N ≥ 12 journal step boundaries; after `eo resume`, same final states; no task executed twice past its intent | **PASSED** | FakeStore: [final/fake/behavioral.tap](M1-evidence/final/fake/behavioral.tap) (3/3, PASSED; also on Linux and Windows CI). BeadsStore Linux (r10): [every boundary](M1-evidence/final/beads-r10/behavioral-every-boundary.tap) (70 boundaries, 23 with a second crash, 1h59m), [random kills](M1-evidence/final/beads-r10/behavioral-random-kills.tap) (32 SIGKILLs across 8 runs), [escalation](M1-evidence/final/beads-r10/behavioral-escalation.tap) (37 boundaries): 3/3 PASSED. Beads on Windows CI runs the FakeStore crash suite only (residual). Three tests: (1) all 70 boundaries of a 5-task run with a verification failure and a worker crash, 23 of them crashed again during recovery; (2) 32 random SIGKILLs of the controller's whole process group, `bd` included, across 8 runs; (3) all 37 boundaries of a run ending in an escalation. Each must end in the uninterrupted run's final states, with no (task, attempt) twice in the execution log, a journaled start for every execution, `eo doctor` clean and no open reservation |
| M1-5 Journal tamper detected by `eo doctor` | **PASSED** | `eo doctor` exits 1 on an edited journal record and on an altered evidence file; unit tests cover deleted, reordered, wrongly keyed and spliced records. **Rollback (the critical finding of the final review, see below):** restoring any older valid journal is refused on open, nothing changes, and a forensic record is written. On beads, tasks injected or edited with `bd` behind the controller are refused on open and reported by `doctor`. ([final/fake/](M1-evidence/final/fake/), [final/beads/integration.tap](M1-evidence/final/beads/integration.tap), [final/beads/controller-unit.tap](M1-evidence/final/beads/controller-unit.tap)). Residual: restoring journal **and** store together to an older consistent copy is not detected (M2-0b) |
| M1-6 No outbound network from controller or `bd` during the M1-4 scenario | **PASSED** | Two detectors, each with a positive control: a Node preload that refuses every network API, and `strace -f` of every `connect`/`sendto`/`sendmsg`/`execve` inside an empty network namespace, across crash, resume, run, doctor and status. Run with `EO_REQUIRE_TRACE=1`, so a missing tracer fails rather than skips. Beads trace: 261 `bd` processes, no IPv4/IPv6 network syscall ([final/beads/m1-6-strace-beads.log](M1-evidence/final/beads/m1-6-strace-beads.log.summary.txt)); controller trace [final/beads/m1-6-strace.log](M1-evidence/final/beads/m1-6-strace.log.summary.txt). The positive control shows `bd` with metrics left on does try to connect. Linux only; on Windows the preload detector runs |
| M1-7 `bd` built from pinned commit; SHA-256 in `deps.lock.json`; metrics env set on every spawn | **PASSED** | `deps.lock.json` records the revision and a SHA-256 per platform; `eo init --store beads` refuses any other binary before writing. Each store runs only its own private read-only copy (a regular file, single link, owned by the user), re-hashed when its identity changes. An observer on every `bd` spawn checks `BD_DISABLE_METRICS=1`, `DO_NOT_TRACK=1`, no secret-named variable, and the fixed allowlist ([final/beads/integration.tap](M1-evidence/final/beads/integration.tap)) |
| M1-8 Test suite passes on Windows; `bd` Windows build recorded | **PASSED** | CI at `e8fdaa4` ([run 39297175940](https://github.com/Rockhelljumper/Engineering-Orchestrator/actions/runs/39297175940)): `test (windows-2022)` unit 96 + 1 skip (symlinks need privileges), integration 48 + 21 skips (beads without `bd`, Linux tracing), behavioural 3/3; `beads-windows` checks the Go zip hash, builds `bd` twice (both `0b4d916b…64f1`, equal to the pin) and runs the beads tests including the 100-round claim race: 77 pass, 10 platform skips, 0 fail. Logs: [final/ci-e8fdaa4/](M1-evidence/final/ci-e8fdaa4/) |
| M1-9 Reproducible offline `bd` build | **PASSED** | `scripts/build-bd.sh` (unchanged since `0ef2f65`) refuses another revision or untracked files, forces `GOTOOLCHAIN=local`, `GOPROXY=off`, `-mod=readonly`, runs `go mod verify`, compiles in an empty network namespace and prints the SHA-256. Two builds with fresh build caches (a shared, verified module cache; offline) on 2026-10-19 both gave `2589f95d…97ef` ([final/m1-9-reproducible-build/](M1-evidence/final/m1-9-reproducible-build/)); earlier builds in [bd-build/](M1-evidence/bd-build/). Windows: two builds per CI run, equal to each other and to the pin |
| M1-10 Refuse `eo init`/`eo run` on an unapproved repository | **PASSED** | `eo run` and `eo plan import` refuse an unapproved repository by canonical path; nothing is journaled or launched. A repository that contains or lies inside the state root cannot be approved. `eo init` takes no repository ([final/fake/unit.tap](M1-evidence/final/fake/unit.tap), [final/fake/integration.tap](M1-evidence/final/fake/integration.tap)) |

## The rollback defect (critical) and how each requirement is shown

The final independent review of `72fe3f3` found that `eo resume` trusted the journal over the store in both directions: replacing the journal with an older valid copy (a truncation or a restored backup) made resume rewind finished tasks, re-run attempts and drop spend. It was treated as a critical state-integrity defect.

**Fix.** Every store task records `journalSeq`, the journal position of the last transition applied to it. On every controller open (before any command can write) the controller folds the journal into the expected state and counters of every task and compares all of them. It accepts only two cases: the store equals the journal, or exactly one task is one transition behind and that transition is the journal's last (a crash between the append and the store update), which open then finishes. Anything else is refused.

| Owner's requirement | Shown by (tests in `tests/unit/controller.test.ts` unless stated; all pass at `e8fdaa4` on FakeStore, and on Beads except the two noted as FakeStore-only) |
|---|---|
| 1. An older valid journal cannot silently rewind completed tasks, attempts or budget | "restoring any older valid journal never rewinds…": a finished 5-task run with a verification failure; **every** earlier prefix of its journal (every 3rd on Beads) is restored and opened. Each is refused; the store, evidence, escalations, execution log and spend are unchanged. FakeStore: 69 prefixes tried, 68 refused, 1 accepted (the cut after the last applied transition, which is indistinguishable from a crash and keeps all spend). Beads: 23 tried, 23 refused. "a journal cut back past a repeated block cannot undo the block". "counters changed in the store behind the controller are refused". Mutants: accepting a diverged store, or any behind task, or not recording `journalSeq`, are each caught |
| 2. Impossible store/journal combinations are refused without changing either | "no command can act on a state root that recovery refuses" (run, resume, unblock, import, policy all refuse on open); "two tasks behind the journal at once are refused"; "evidence or escalation files the journal never recorded make recovery refuse"; "a refused state root with a torn journal tail is left exactly as found" (journal bytes, store, evidence, escalations compared); "an open that fails its policy check finishes no interrupted transition"; "a journal position that is not a number is refused" (FakeStore only: it edits the FakeStore file); "a state root written before journal positions is refused" (also on Beads); Beads: "changes made with bd directly … are refused", "a beads store that lost its marker is refused once evidence exists" (no re-initialisation). Mutants: removing the open-time check (13 tests fail), accepting unrecorded evidence or escalations, are caught |
| 3. Valid interrupted writes and legitimate crashes stay recoverable | "a legitimate crash between the journal append and the store update is recovered"; "a legitimate crash followed by eo unblock of another task still recovers"; "a torn journal tail is preserved … before the repair drops it"; and the whole M1-4 crash suite (every boundary, random kills, crashes during recovery) |
| 4. Failures preserve forensic evidence and identify the inconsistency | Each refusal writes `forensics/<time>-<pid>-<random>-<kind>.json` (created exclusively, fsynced with its directory, never through a link): the problems, journal head and MAC, the raw journal bytes (base64 + SHA-256), the store as found, evidence and escalation lists. The error message lists the same problems and the record path. Tests: the sweep checks one record per refusal containing every problem; "a refusal is reported with its problems even when the forensic record cannot be written"; "other refusals to open also leave a forensic record"; "forensic records are never written through a link out of the state root" |
| 5. Whole-root rollback | **Documented residual risk M2-0b.** Restoring the journal and store together to an older internally consistent copy cannot be detected from inside the state root. `docs/04-threat-model.md` T10 records it; `docs/05-implementation-plan.md` row M2-0b gives the acceptance criterion (journal head anchored in a trusted checkpoint outside the state root; a restored complete older copy is refused, nothing runs again, no spend lost; a crash between append and checkpoint recovers). The test "known limit (M2-0b) …" pins today's behaviour (FakeStore only: it copies the FakeStore state root) |

**Regression evidence (tests fail on the old code, pass on the fix).** [final/review-fixes/](M1-evidence/final/review-fixes/):
- `rollback-tests-on-earlier-source.txt`: the rollback tests against the source of `72fe3f3` and `f26bee0`. `recovery-tests-on-earlier-source.txt`: the recovery tests against `72fe3f3`, `f26bee0` and `ac54edd`, with a one-line shim that only declares `RecoveryRefusedError` so the file loads. Every test fails except the known-limit test (which passes everywhere by design) and tests whose fix the old source already had.
- `third-review-tests-on-957fb59-source.txt`: the 4 new and 2 tightened tests of the third review, 0/6 on `957fb59`.
- `new-tests-on-72fe3f3-source.txt`: the earlier review-fix tests on `72fe3f3`.
- Mutation evidence at `e8fdaa4`: [final/fake/mutation-check.txt](M1-evidence/final/fake/mutation-check.txt).

## Evidence storage

The 18 evidence logs over 250 KB (strace traces, CI job logs and a module download log; 24.5 MB) were moved out of the tree on 2026-10-21 for the public-repository release check. Each is kept byte for byte at commit `605decf6128942da4706b0ece0a5d97a329ed50c`, its SHA-256 is listed in [MANIFEST.sha256](M1-evidence/MANIFEST.sha256) (all 141 evidence files at that commit), and a summary with its key lines (commits, TAP totals, build hashes, network-syscall counts) sits where it was. The list with stable links is [RAW-LOGS.md](M1-evidence/RAW-LOGS.md). No secret, credential or personal data was found in the PR's history (see the release check in PR #2).

## Counted runs (all at `e8fdaa4`, clean tree, 2026-10-19 UTC)

| Run | Started → finished | Command | Result |
|---|---|---|---|
| FakeStore unit | 17:47:47 → 17:48:04 | `node --test "tests/unit/**/*.test.ts"` | **PASSED** 97/97 |
| FakeStore integration | 17:48:04 → 17:48:51 | `node --test --test-concurrency=1 "tests/integration/**/*.test.ts"` | **PASSED** 51, 18 skipped (beads tests; run below) |
| FakeStore behavioural | 17:48:51 → 17:54:27 | `node --test --test-concurrency=1 "tests/behavioral/**/*.test.ts"` | **PASSED** 3/3 |
| Typecheck | → 17:54:37 | `/opt/node-tools/node_modules/.bin/tsc -p tsconfig.json --typeRoots /opt/node-tools/node_modules/@types` | **PASSED** exit 0 |
| FakeStore mutation check | 17:54:37 → 17:59:52 | `python3 -I mutate-final2.py <worktree>` | **PASSED** 18/18 mutants caught |
| Beads integration | 17:47:47 → 18:30:36 | `EO_TEST_STORE=beads EO_REQUIRE_BD=1 EO_REQUIRE_TRACE=1 EO_BD_BIN=… node --test --test-concurrency=1 tests/integration/{store-contract,beads,cli,no-network}.test.ts` | **PASSED** 83/83 |
| Beads controller suite | 18:30:36 → 19:06:00 | same env, `tests/unit/controller.test.ts` | **PASSED** 39, 5 skipped (they edit or copy the FakeStore file). Three have Beads equivalents in `beads.test.ts` (injected task, edited epic, root written before journal positions); the invalid-journal-position and known-limit tests run on FakeStore only |
| Beads claim race | 19:06:00 → 20:02:24 | same env, `--test-name-pattern 'M1-3 \(beads\)' tests/integration/concurrent-claims.test.ts` | **PASSED** 1/1 (100 rounds) |
| Beads crash recovery, first attempt (r9) | 20:02:24 → (none) | same env, `tests/behavioral/crash-recovery.test.ts` | **INTERRUPTED** by a container restart at boundary 67/70 of test 1 (no failure); not counted ([not-counted/beads-crash-recovery-e8fdaa4-interrupted/](M1-evidence/not-counted/beads-crash-recovery-e8fdaa4-interrupted/)) |
| Beads crash recovery (r10, 2026-10-20) | 02:26:39 → 04:25:50 | same env, the three tests of `tests/behavioral/crash-recovery.test.ts` as three processes at once (`--test-name-pattern` per test; each uses its own sandboxes), [run-r10.sh](M1-evidence/final/run-r10.sh) | **PASSED** 3/3: every boundary (70) until 04:25:50, random kills (32) until 02:48:40, escalation (37) until 03:06:32 |
| Beads mutation check (r10, 2026-10-20) | 02:26:40 → 02:39:12 | `python3 -I mutate-beads-final2.py <worktree>` | **PASSED** 14/14 mutants caught, 13/13 control selections pass |
| CI | 17:47:50 → 19:13:14 (check-run times) | `.github/workflows/ci.yml`, [run 39297175940](https://github.com/Rockhelljumper/Engineering-Orchestrator/actions/runs/39297175940) | **PASSED** all three jobs (numbers in M1-8). GitHub tested its merge of `e8fdaa4` into the base branch (`69ed2c5`) |

Evidence: [`final/fake/`](M1-evidence/final/fake/), [`final/beads/`](M1-evidence/final/beads/) (TAP, `DONE-r9` with commit/bd/node/strace per suite, `progress-r9.jsonl`, strace logs), [`final/beads-r10/`](M1-evidence/final/beads-r10/) (crash recovery and Beads mutation check; its `progress.jsonl` also holds three claim-race lines written by the CAS mutant's deliberately failing run), [`final/ci-e8fdaa4/`](M1-evidence/final/ci-e8fdaa4/), [`final/m1-9-reproducible-build/`](M1-evidence/final/m1-9-reproducible-build/), [`final/review-fixes/`](M1-evidence/final/review-fixes/), and the runner script [`final/run-final.sh`](M1-evidence/final/run-final.sh) with the mutation scripts.

Reproduce on Linux, with Go 1.26.7 and a beads checkout at the pinned revision:

```sh
git checkout e8fdaa4
GO=/opt/go1.26.7/bin/go scripts/build-bd.sh ../beads-src /opt/beads-9c6f6e1/bd   # last line: the SHA-256
export EO_TEST_STORE=beads EO_REQUIRE_BD=1 EO_REQUIRE_TRACE=1 EO_BD_BIN=/opt/beads-9c6f6e1/bd EO_PROGRESS_FILE=/tmp/progress.jsonl
node --test --test-concurrency=1 tests/integration/store-contract.test.ts tests/integration/beads.test.ts tests/integration/cli.test.ts tests/integration/no-network.test.ts
node --test --test-concurrency=1 tests/unit/controller.test.ts
node --test --test-name-pattern 'M1-3 \(beads\)' tests/integration/concurrent-claims.test.ts      # ~1 h under load
node --test --test-concurrency=1 tests/behavioral/crash-recovery.test.ts                        # hours on beads
node scripts/test-progress.ts /tmp/progress.jsonl                                               # live progress
```

## Independent reviews

| Round | Reviewed | Critical / major found | Resolution |
|---|---|---|---|
| Final review | `72fe3f3` | **Critical:** resume rewound the store to an older journal. Major: state-root and `bd` entry permission and link checks; `eo init` over an existing root; journaled ids re-importable; lease loss not ending the attempt | `08c4b57`, `0ef2f65`, then the rollback fix below |
| Review of the fixes | `0ef2f65` | Major: an existing hard-linked `bd` entry was chmodded, which changed the user's own `bd` | `f26bee0` (no chmod on POSIX; mode of the source binary restored to 755) |
| Rollback fix, review 1 | `ac54edd` | Major: the check ran in resume only, so `unblock`, `import` or `policy` could write first; counters the journal never set were not compared; two tasks behind accepted | `957fb59` (refuse on open; all counters; only the last transition) |
| Rollback fix, review 2 | `957fb59` | **Major:** a legitimate crash followed by `eo unblock` of another task wedged the root. Minor: torn-tail repair before the refusal; torn copy not byte-exact; Beads re-init keyed on the journal only; forensics followed a symlink; unclear message for old roots; architecture doc | `4978a1c` (finish the last transition on open; check before repair; base64 copy; evidence/escalations count; `assertPrivateDir`; docs) |
| Rollback fix, review 3 | `4978a1c` | None. Minor: forensic records could overwrite one another; Beads old-root message; test coverage of "left as found"; open finished a transition before the policy check | `4f031b0` |
| Delta review | `4f031b0` | None. Minor: forensic write not fsynced; no test pinning the open order; invalid journal positions misnamed | `e8fdaa4` (the ordering test was mutation-checked: moving the finish back fails it, [final/review-fixes/open-order-mutation-e8fdaa4.txt](M1-evidence/final/review-fixes/open-order-mutation-e8fdaa4.txt)) |
| Delta review | `e8fdaa4` | None. Minor (not fixed, harmless): a failed forensic write can leave a partial file (the failure is still reported and the repair refused); directory fsync errors are ignored (project convention); invalid-position test covers `null` only | Verdict: ready for the final runs |

Earlier rounds (first beads review, second independent review, first controller review) are in the git history of this file (`f3b858b` and before).

## Runs that do not count

| Run | Commit | What happened | Evidence |
|---|---|---|---|
| r3 beads | `c892111` | Claim race and crash recovery **killed by a cloud container restart** | [not-counted/r3-interrupted/](M1-evidence/not-counted/r3-interrupted/) |
| r4 beads | `81e51d2` | Complete and passing; superseded | [not-counted/r4-81e51d2/](M1-evidence/not-counted/r4-81e51d2/) |
| r5 beads | `c48ac38` | **Failed** (a defect introduced by a review fix) | [not-counted/r5-c48ac38-failed/](M1-evidence/not-counted/r5-c48ac38-failed/) |
| r6 beads | `72fe3f3` | Integration, controller and claim race passed; crash recovery **interrupted** by a container restart at boundary 34/70 | [not-counted/beads-linux-72fe3f3/](M1-evidence/not-counted/beads-linux-72fe3f3/), [not-counted/r6-behavioral-72fe3f3-interrupted/](M1-evidence/not-counted/r6-behavioral-72fe3f3-interrupted/) |
| r7 beads crash recovery | `72fe3f3` | **Cancelled** at 30/70 (16:29:11 UTC, SIGTERM to its process group) with the owner's permission: it tested the code with the rollback defect | [not-counted/r7-behavioral-72fe3f3-cancelled/](M1-evidence/not-counted/r7-behavioral-72fe3f3-cancelled/) |
| FakeStore, mutation, CI | `72fe3f3` | Passed; superseded by the rollback fix | [not-counted/fake-72fe3f3/](M1-evidence/not-counted/fake-72fe3f3/), [mutation-72fe3f3/](M1-evidence/not-counted/mutation-72fe3f3/), [windows-72fe3f3/](M1-evidence/not-counted/windows-72fe3f3/) |
| FakeStore and mutation | `f26bee0` | Passed (12/12 mutants); superseded | [not-counted/fake-f26bee0/](M1-evidence/not-counted/fake-f26bee0/) |
| r8 beads | `f26bee0` | **CANCELLED_SUPERSEDED** at 2026-10-19T21:54:05Z with the owner's authorisation (it tested code with the rollback defect). Integration, controller suite and claim race had passed; crash recovery test 1 passed (70/70), test 2 completed 8/8 seeds, test 3 was at escalation boundary 10 of 37 | [not-counted/r8-beads-f26bee0-cancelled/](M1-evidence/not-counted/r8-beads-f26bee0-cancelled/) (`CANCELLED_SUPERSEDED.md`) |
| Beads recovery tests | `4978a1c`, `4f031b0` | Passed (13 + 4 skips each; Beads tests 17/17 at 4978a1c, 18/18 at 4f031b0); superseded | [not-counted/beads-recovery-tests-4978a1c/](M1-evidence/not-counted/beads-recovery-tests-4978a1c/), [-4f031b0/](M1-evidence/not-counted/beads-recovery-tests-4f031b0/) |
| Earlier | `615d17b`, `81e51d2`, `b872421`, `d87fe63` | Windows pin creation and reproduction, pre-beads FakeStore evidence, an early beads mutation check | `not-counted/`; the `615d17b` build log is in [bd-build/](M1-evidence/bd-build/) |

## Test integrity

Mutation checks at `e8fdaa4` apply one deliberate bug at a time in a separate worktree and run its target tests.

- **FakeStore and controller (18/18 caught)**, [final/fake/mutation-check.txt](M1-evidence/final/fake/mutation-check.txt): illegal transition allowed; USD cap ignored; open reservations ignored; store lock removed; never-launched reservations left open; chain link dropped from the journal MAC; one extra correction attempt; evidence hashes not checked; **a diverged store accepted; any behind task accepted; unrecorded evidence accepted; unrecorded escalations accepted; recovery not checked on open; forensics written through a link; `journalSeq` not recorded**; state-root permissions not checked; init over an existing journal; journaled ids re-importable.
- **BeadsStore (14/14 caught)**, [final/beads-r10/mutation-check.txt](M1-evidence/final/beads-r10/mutation-check.txt): revision guard dropped; metrics opt-out removed; binary hash not checked; per-spawn identity check removed; no store-own git repository; half-initialised store not repaired; foreign beads accepted; store binding checked after creation; hard link instead of a private copy; closing not forced; a linked `bd` entry trusted; store directory permissions not checked; **re-initialisation allowed once evidence exists; re-initialisation allowed after plans were imported**. Every targeted selection except the claim race also passes on the unmutated tree (13 control runs); the unmutated claim race is the counted 100-round run. The runner's `mutation exit=0` line records the shell group, not the script: the result is the `ALL KILLED` line.

No test was skipped, disabled or weakened to obtain a pass. Expectations that changed, and why:
- the lease-loss test asserts `blocked` with two infra failures, because the budget correctly refuses a third attempt;
- error-message assertions follow the new refusal wording (the refusal itself is still asserted);
- the doctor wording for a crash-behind task.

## Budget governor: reservation semantics

Specified in `07-isolation-and-credentials.md` §5.1 and implemented in `src/budget.ts`. Each launch reserves R, the invocation cap plus the largest measured turn, or `max(10 × cap, cap + $1)` until M2-6b measures it; tokens follow the same rule. Per task and epic: **reject** when `spent + R > cap` (blocked with an escalation, nothing launches), **defer** when `spent + reserved + R > cap`, **admit** otherwise with the reservation journaled first. Settlement charges the reported cost (overshoot journaled), the full R when the cost is unknown, or zero only when the journal proves the attempt never started. Budget lives only in the journal, and every settlement is followed by a transition, so a rollback that drops spend also drops an applied transition and is refused.

## Residual risks and where they are closed

| Risk | Closed by |
|---|---|
| Whole-state-root rollback (journal and store restored together to an older consistent copy) is not detected | **M2-0b** (trusted checkpoint outside the state root; criterion in `05`) |
| A journal cut exactly after the store's last applied transition is accepted as a crash: the interrupted attempt is re-charged its full reservation (conservative) and an attempt result dropped with it is re-run; overshoot above R can be under-counted (T9) | M2-0b |
| `eo doctor` reads without the controller lock and can report a transition in flight as a store ahead of the journal | M2-0b (consistent doctor snapshot, in its criterion) |
| A Beads store whose journal is emptied **and** whose init marker is deleted, with no evidence yet, is re-initialised (two corruptions) | M2-0b |
| A refusal still writes the lock file, `bd`'s own lock/version files and possibly restores the store's private `bd` copy (task data, journal, evidence and escalations are untouched) | documented (T10) |
| Power loss: Dolt's own durability on power loss was not tested | M2 pilot |
| Stale-lock race: a contender paused > 10 s in the takeover can remove a fresh lock | **M5-0**, a blocker before any concurrent execution (T11) |
| Windows: state root protected only by NTFS ACLs; POSIX permission checks are no-ops there | M2 pilot |
| Check-then-exec gap on the store's private `bd` copy | accepted: the copy is in the state root, outside every workspace (T10) |
| Windows `bd` hash depends on the runner's MinGW, which nothing pins (fails closed, names the toolchain) | M2 |
| Typecheck is not in CI (it would need an npm install) | M2 |
| The Linux CI job does not run `bd`; the Beads crash sweep runs on Linux only, not Windows | M2 |
| Heartbeat: an expired lease is detected on the next renewal, not instantly | documented |
| Human gates (typed word at a TTY) are a speed bump, not a security boundary (T18) | documented |
| Long suites are lost on a container restart (r3, r6) | **M2-0** durable checkpointing |

## Merge recommendation

**Recommend approving M1 and merging PR #2, by the owner, after reviewing this report.** Every acceptance criterion passed in complete, attributable runs at the final source commit `e8fdaa4`. The critical rollback defect is fixed, and its regression tests fail on the earlier code and pass on the fix. The last two independent reviews found no critical or major issues. The residual risks above are tracked to M2-0, M2-0b, M5-0 and the M2 pilot; none affects M1's single-controller, no-live-worker scope. Do not treat this as permission to run concurrent controllers (M5-0) or to rely on rollback detection of a whole state root (M2-0b).

PR #2 stays in draft until the owner decides. Nothing has been merged, and M2 has not started.

## Next approval gate

M1 needs the owner's review of this report and PR #2, which stays in draft. M2 needs the owner's choice of local isolation tier and a go-ahead for live spend (proposed ≤ $2), per `05` §M2.
