# M1 report — controller core and durable task store

Scope: the controller core, the `FakeStore` and `BeadsStore` task stores, the fake runner, and deterministic tests. It covers the work approved on 2026-10-18, plus the M1 amendments approved later that day:
- the `ready → blocked` transition;
- default task limits of $10 / 4M tokens and epic limits of $25 / 20M tokens;
- installing Go 1.26.7 and building beads from its pinned revision;
- using that Go on disposable GitHub-hosted Windows runners to build and test beads.

No model was invoked, no API credit was spent, and nothing was merged or deployed. No VM was created, and no production system or Proxmox host was touched.

## How results are counted

An acceptance criterion counts only if it passed in a **complete, attributable run**: every suite finished, and the run records:
- the commit, with a clean tree;
- the `bd` binary hash;
- the platform;
- the command;
- start and end times.

Runs that were interrupted, that failed, or that tested an earlier commit are kept as evidence under [`M1-evidence/not-counted/`](M1-evidence/not-counted/) and are listed in [Runs that do not count](#runs-that-do-not-count). They never count towards a criterion.

**Final source commit: `72fe3f3`.** Every counted run below tested this commit. Later commits on the PR change only `docs/` (this report and the evidence); `git diff 72fe3f3 HEAD -- src tests scripts deps.lock.json .github package.json tsconfig.json` is empty.

| Item | Value |
|---|---|
| Platform (Linux runs) | Linux 6.18.44 x86_64, Node v22.22.0, Go go1.26.7 linux/amd64, gcc 13.3.0, glibc 2.39 |
| beads source | `gastownhall/beads` @ `9c6f6e15cdfdc4478e634520e8320795914e68e5` (module `github.com/steveyegge/beads`, v1.3.0) |
| `bd` linux-amd64 SHA-256 | `2589f95d65136897a5228cb829b7b3bbf755468b26689b764b6816d4d07697ef` |
| `bd` windows-amd64 SHA-256 | `0b4d916b7076bb8ef7ab45882f6b7183399a90395ffbd867fb0b704ff12664f1` (gcc 14.2.0, x86_64-w64-mingw32, GitHub windows-2022 image) |

## Acceptance criteria

| AC | Result | Evidence (all at `72fe3f3` unless stated) |
|---|---|---|
| M1-1 State machine rejects every illegal transition | **PASS** | All 100 ordered state pairs are checked against an independent table. That table is checked edge for edge against the diagram in `02-architecture.md` §5 (22 legal edges, including the approved `ready → blocked`) ([final/fake/unit.tap](M1-evidence/final/fake/unit.tap), `tests/unit/states.test.ts`) |
| M1-2 `BeadsStore` passes the `FakeStore` contract suite | **PASS** | The same 17-case contract suite (create, deps, ready, claim, heartbeat, reclaim, notes, close, title and note boundaries, unknown tasks, durability) runs on FakeStore in memory, FakeStore on disk and BeadsStore against the real pinned `bd`. Results: Linux [final/beads-linux/integration.tap](M1-evidence/final/beads-linux/integration.tap) (77/77); Windows [final/windows](M1-evidence/final/windows/) |
| M1-3 20 concurrent claims on one ready task, exactly one winner, 100 runs | **PASS** | 20 separate OS processes race for the ready task in each of 100 rounds. In every round there was exactly one winner, and the store's recorded owner was that winner. Results: FakeStore [final/fake/integration.tap](M1-evidence/final/fake/integration.tap); BeadsStore on Linux [final/beads-linux/m1-3-claims-race.tap](M1-evidence/final/beads-linux/m1-3-claims-race.tap) (33 min); BeadsStore on Windows [final/windows](M1-evidence/final/windows/). Mutation: dropping the revision guard from BeadsStore updates, or the lock from FakeStore, fails it |
| M1-4 Killed at each of N ≥ 12 journal step boundaries; after `eo resume`, same final states; no task executed twice past its intent | **R7_M14_RESULT** | FakeStore: passed ([final/fake/behavioral.tap](M1-evidence/final/fake/behavioral.tap)). BeadsStore: R7_M14_BEADS. It consists of three tests:<br>1. All 70 boundaries of a 5-task run with a verification failure and a worker crash. For 23 of them, recovery is crashed again at a second point.<br>2. 32 random SIGKILLs of the controller and its whole process group, `bd` included, across 8 runs.<br>3. All 37 boundaries of a run that ends in an escalation.<br>Every run ended in the uninterrupted run's final states, and no (task, attempt) appears twice in the execution log. Every execution has a journaled attempt start. `eo doctor` is clean and no reservation is left open. In test 3 the escalation records are also identical, with exactly one escalation file |
| M1-5 Journal tamper detected by `eo doctor` | **PASS** | `eo doctor` exits 1 on an edited journal record and on an altered evidence file, and the controller refuses to resume ([final/fake/integration.tap](M1-evidence/final/fake/integration.tap), [final/beads-linux/integration.tap](M1-evidence/final/beads-linux/integration.tap)). Unit tests cover deleted, reordered, wrongly keyed and spliced records. On beads, tasks injected or edited with `bd` behind the controller (an injected task, a bead without eo metadata, a removed dependency, a changed epic) are refused by `run` and reported by `doctor`. One limit is documented and tested: truncating the journal's final records leaves a valid shorter chain. `doctor` reports the resulting store/journal disagreement, but the file alone cannot show it |
| M1-6 No outbound network from controller or `bd` during the M1-4 scenario | **PASS** | There are two detectors, each with a positive control:<br>1. A Node preload that records and refuses every network API (controller).<br>2. `strace -f` of every `connect`/`sendto`/`sendmsg` and `execve`, inside an empty network namespace, across crash, resume, run, doctor and status.<br>On beads, the trace covered 243 `bd` processes and recorded no IPv4 or IPv6 network syscall ([final/beads-linux/m1-6-strace-beads.log](M1-evidence/final/beads-linux/m1-6-strace-beads.log)); the controller-only trace is [m1-6-strace.log](M1-evidence/final/beads-linux/m1-6-strace.log). The positive control shows `bd` init with metrics left on does attempt an IPv4 connection, and that the detector sees it. No metrics queue (`bd-home/.beads/eventsData`) is ever created. The strace detector is Linux-only; on Windows the preload detector runs |
| M1-7 `bd` built from pinned commit; SHA-256 in `deps.lock.json`; metrics env set on every spawn | **PASS** | `deps.lock.json` records the revision and a SHA-256 per platform. `eo init --store beads` refuses any other binary before writing anything. Each store runs only its own read-only copy, hashed against the pin. An observer on every `bd` spawn of a full run checks:<br>- `BD_DISABLE_METRICS=1` and `DO_NOT_TRACK=1` are set;<br>- no API key or other secret-named variable is present;<br>- the environment is the fixed allowlist.<br>A wrapper confirms the environment the process actually receives ([final/beads-linux/integration.tap](M1-evidence/final/beads-linux/integration.tap), tests 1–3) |
| M1-8 Test suite passes on Windows; `bd` Windows build recorded | **PASS** | Windows CI (`windows-2022`) runs the FakeStore unit, integration and behavioural suites. The `beads-windows` job:<br>- fetches the official Go 1.26.7 toolchain module and checks its SHA-256 against `deps.lock.json` (verified against sum.golang.org);<br>- builds `bd` twice with separate caches;<br>- requires both hashes to equal the pin;<br>- runs the beads integration tests, including the 100-round claim race.<br>The pin was set from the first build on one runner; every later run must reproduce it on a fresh runner. Results are in [final/windows](M1-evidence/final/windows/). Skipped on Windows, with the reason shown: the strace tests (Linux-only), the environment-recording wrapper (a POSIX shell script), the killed-init and private-entry permission tests (POSIX signals and permissions) |
| M1-9 Reproducible offline `bd` build | **PASS** | `scripts/build-bd.sh`:<br>- refuses a checkout at another revision or with any untracked or ignored file;<br>- forces `GOTOOLCHAIN=local`, `GOPROXY=off` and `-mod=readonly`;<br>- runs `go mod verify`;<br>- compiles inside an empty network namespace;<br>- prints the SHA-256.<br>Linux: builds 1 and 2 (separate checkouts, fresh caches), build 3 (hardened script) and the final-script builds all produced the pinned hash ([bd-build/](M1-evidence/bd-build/)). Windows: two builds per run, equal to each other and to the pin. No build log shows a toolchain download. The hash depends on the C toolchain (CGO); see [Limits](#limits-and-open-items) |
| M1-10 Refuse `eo init`/`eo run` on an unapproved repository | **PASS** | `eo run` and `eo plan import` refuse an unapproved repository. They compare canonical paths, and nothing is journaled or launched. Tasks run only against the repository their plan was approved for. `eo init` takes no repository, so it has nothing to refuse ([final/fake/unit.tap](M1-evidence/final/fake/unit.tap), [final/fake/integration.tap](M1-evidence/final/fake/integration.tap)) |

## Counted runs

Each run's start and end times and the commit it read are written by the runner into `DONE` before and after each suite. Long suites also write a [progress history](#progress-reporting).

| Run | Commit | Started → finished (UTC, 2026-10-19) | Command | Result |
|---|---|---|---|---|
| FakeStore unit | `72fe3f3` | see `started.txt` / `finished.txt` | `node --test "tests/unit/**/*.test.ts"` | 77/77 |
| FakeStore integration | `72fe3f3` | 〃 | `node --test --test-concurrency=1 "tests/integration/**/*.test.ts"` | 49 pass, 14 skipped (the beads tests, which need `EO_BD_BIN`) |
| FakeStore behavioural | `72fe3f3` | 〃 | `node --test --test-concurrency=1 "tests/behavioral/**/*.test.ts"` | 3/3 |
| Typecheck | `72fe3f3` | 〃 | `tsc -p tsconfig.json` | exit 0 |
| Beads integration (Linux) | `72fe3f3` | 03:55:59 → 04:16:24 | `EO_TEST_STORE=beads EO_REQUIRE_BD=1 EO_BD_BIN=… node --test --test-concurrency=1 tests/integration/{store-contract,beads,cli,no-network}.test.ts` | 77/77 |
| Beads controller suite (Linux) | `72fe3f3` | 04:16:24 → 04:30:34 | same env, `tests/unit/controller.test.ts` | 23 pass, 2 skipped (they edit the FakeStore file; beads equivalents are in `beads.test.ts`) |
| Beads claim race (Linux) | `72fe3f3` | 04:30:34 → 05:07:45 | same env, `--test-name-pattern 'M1-3 \(beads\)' tests/integration/concurrent-claims.test.ts` | 1/1 (100 rounds) |
| Beads crash recovery (Linux), r7 | `72fe3f3` | 15:05:49 → R7_END | same env, `tests/behavioral/crash-recovery.test.ts`, run alone | R7_RESULT |
| Mutation checks | `72fe3f3` | 05:12:14 → 05:20:34 | one mutant at a time in a separate worktree, then its target tests (listed per line in the files) | 8/8 controller and 10/10 BeadsStore mutants caught; 9/9 control runs pass |
| CI, Linux and Windows | `72fe3f3` | 03:55:30 → 05:24:17 | `.github/workflows/ci.yml`, [run 39196962656](https://github.com/Rockhelljumper/Engineering-Orchestrator/actions/runs/39196962656) | `test (ubuntu-24.04)` and `test (windows-2022)`: unit 77/77, integration 47 pass + 16 skipped (beads tests without `bd`, Linux tracing), behavioural 3/3. `beads-windows`: Go zip SHA-256 OK, two builds both `0b4d916b…64f1` equal to the pin, beads tests 74 pass, 7 platform skips, 0 fail (claim race 100 rounds, contract suite on BeadsStore) |

Evidence: [`final/fake/`](M1-evidence/final/fake/), [`final/beads-linux/`](M1-evidence/final/beads-linux/) (TAP, `DONE`, `environment.txt`, `progress.jsonl`, strace logs), [`final/mutation/`](M1-evidence/final/mutation/), [`final/windows/`](M1-evidence/final/windows/), [`bd-build/`](M1-evidence/bd-build/).

Reproduce on Linux, with Go 1.26.7 and a beads checkout at the pinned revision:

```sh
GO=/opt/go1.26.7/bin/go scripts/build-bd.sh ../beads-src /opt/beads-9c6f6e1/bd   # last line: the SHA-256
node src/cli.ts init --store beads --bd-bin /opt/beads-9c6f6e1/bd                # refuses an unpinned binary
export EO_TEST_STORE=beads EO_REQUIRE_BD=1 EO_BD_BIN=/opt/beads-9c6f6e1/bd EO_PROGRESS_FILE=/tmp/progress.jsonl
node --test --test-concurrency=1 tests/integration/store-contract.test.ts tests/integration/beads.test.ts tests/integration/cli.test.ts tests/integration/no-network.test.ts
node --test --test-concurrency=1 tests/unit/controller.test.ts
node --test --test-name-pattern 'M1-3 \(beads\)' tests/integration/concurrent-claims.test.ts      # ~35 min
node --test --test-concurrency=1 tests/behavioral/crash-recovery.test.ts                        # ~3 h on beads
node scripts/test-progress.ts /tmp/progress.jsonl                                               # live progress
```

## Runs that do not count

| Run | Commit | What happened | Evidence |
|---|---|---|---|
| r3 beads | `c892111` | Integration (74/74) and controller suites (23 pass, 2 skipped) finished. The claim race (58 of 100 rounds finished) and crash recovery (around boundary 35 of 70) were **killed by a cloud container restart** at about 01:50 UTC. The suites were active until then, with sandbox writes at 01:49:21, so they had not stalled | [not-counted/r3-interrupted/](M1-evidence/not-counted/r3-interrupted/) (including `INTERRUPTED.md` and the boundary sampler log) |
| r6 beads crash recovery | `72fe3f3` | **Interrupted** by a second cloud container restart after boundary 34 of 70 of the first test (last progress 05:34:55 UTC; started 04:34:59). No exit status was written, and the TAP file holds only its header. The other r6 suites (integration, controller, claim race) had finished and are counted above. Replaced by r7 | [not-counted/r6-behavioral-72fe3f3-interrupted/](M1-evidence/not-counted/r6-behavioral-72fe3f3-interrupted/) |
| r4 beads | `81e51d2` | **Complete and passing:** integration 74/74, controller 23 + 2 skipped, claim race 1/1, crash recovery 3/3 (70 + 32 kills + 37). Superseded because the second review's fixes changed `BeadsStore` afterwards | [not-counted/r4-81e51d2/](M1-evidence/not-counted/r4-81e51d2/) |
| r5 beads | `c48ac38` | **Failed:** integration 9 failures, controller 6, claim race timed out. The fix for review finding 1 introduced the cause (see [Second independent review](#second-independent-review)). Crash recovery was not started | [not-counted/r5-c48ac38-failed/](M1-evidence/not-counted/r5-c48ac38-failed/) |
| Windows CI | `615d17b` | The first `beads-windows` run built `bd` twice with identical hashes and failed by design, because no Windows pin existed yet. Its hash became the pin | job [117846194463](https://github.com/Rockhelljumper/Engineering-Orchestrator/actions/runs/39185244973/job/117846194463) |
| Windows CI | `81e51d2` | A fresh runner reproduced the pin; 71 pass, 7 platform skips | [not-counted/windows-81e51d2/](M1-evidence/not-counted/windows-81e51d2/) |
| FakeStore suites | `b872421` | The pre-beads M1 evidence of the first review round | [not-counted/fake-b872421/](M1-evidence/not-counted/fake-b872421/) |
| Beads mutation check | `d87fe63` | 8/8 mutants caught, before the second review's changes | [not-counted/mutation-d87fe63/](M1-evidence/not-counted/mutation-d87fe63/) |

## Progress reporting

The crash-recovery and claim-race tests append one JSON line per step to `EO_PROGRESS_FILE`. Each line records the test, the current scenario (boundary, seed or round), the completed and total scenarios, the last meaningful activity, its time and the elapsed time. `node scripts/test-progress.ts <file>` summarises the file and marks a test whose last activity is more than 10 minutes old as possibly stalled. Reporting never affects a result.

This is not checkpointing: a restart still loses the scenarios of an unfinished test. Durable, resumable per-scenario checkpoints are now a requirement for future work (plan §1 and **M2-0**).

## BeadsStore design

- **Tasks and state.** Each task is the bead `eo-<id>`. Eo's state, counters and claim live in the bead's metadata (`eo`). The bead's own status mirrors them: done → closed, blocked → blocked, claimed → in_progress, anything else → open.
- **Writes.** Every read-modify-write is `bd update --if-revision <token>`, a compare-and-swap on a random per-write row token; a loser gets exit 13 and retries. Closing passes `--force`, because the journal decides dependency order and resume may repair tasks in any order. The independent review confirmed `--force` does not bypass the revision guard.
- **Leases.** Leases use the controller's clock, as in FakeStore, so both stores pass the same contract suite unchanged.
- **Running `bd`.** `bd` runs with a fixed environment allowlist:
  - `BD_DISABLE_METRICS=1`, `DO_NOT_TRACK=1` and `BD_DISABLE_EVENT_FLUSH=1`;
  - a private `HOME` inside the store;
  - nothing else inherited, so no API keys.
- **Telemetry finding.** beads 1.3.0 sends usage metrics by default, to `gastownhall-eventsapi.com`. The positive control shows this.
- **Git.** bd strips `GIT_CEILING_DIRECTORIES` and would commit into any enclosing git repository, so each store gets its own repository first.
- **Initialisation.** It is marked complete only after `bd init` succeeds. A half-initialised store is redone by the controller and refused by read-only commands.
- **Binary pinning.** Each store executes only its own read-only copy of `bd`, hashed against the pin when the store is opened. Its file identity (device, inode, size, mtime, ctime) is taken before hashing and confirmed after. Before every spawn the store re-hashes the copy if its identity has changed, and refuses to run it if the hash is wrong.
- **Store binding.** The store kind is journaled (`store.bound`), and every command refuses a `store.json` that disagrees with it, before anything is created in the store.

## Second independent review

A fresh reviewer read the `81e51d2` diff adversarially and ran targeted experiments against the real `bd`. It found nothing critical or major. It found 5 minor findings, plus a documentation status gap, all verified, and all fixed with tests in `c48ac38`:

| Severity | Finding | Resolution |
|---|---|---|
| Minor | The store hashed its `bd` entry before recording its identity, so a write landing during the hash could be recorded as verified | Identity is taken before hashing and confirmed after, both in the constructor and before each spawn |
| Minor | On Windows, re-installing the entry could not rename over the read-only copy, so the store would not open, and a 200 MB temp file was left behind | The old entry is made writable first; the temp file is always removed; failures are `StoreError`s. A new all-platform test replaces a stale, read-only entry |
| Minor | The controller created or repaired the store before checking the journaled store binding. On a fake-bound root with `store.json` switched to beads, `bd init` ran in the FakeStore directory before the refusal | The controller passes the journal to `openStore`, so the binding is checked first. The new test fails on the old code (it lists the beads files created) |
| Minor | `BeadsStore.atDir` created stores by default | The default is now no; callers that create say so (tests updated to state it explicitly) |
| Minor | Windows pin mismatches would not say whether the runner's MinGW changed; `build-bd.sh` named arm64 differently from `platformKey()` | A mismatch names the pinned and the runner's C toolchain; both use `arm64` |
| Minor | `doctor`'s comment said it never modifies anything | Comment corrected: it never changes the journal, policy, evidence or tasks |
| Docs | Report and evidence predated beads | This report |

**A defect introduced by the first fix, caught by the suites.** At the time, each store's `bd` entry was a hard link to the shared pinned binary. Any other store linking or unlinking that file changes its ctime. The stricter before-and-after check therefore failed whenever another store was created or removed during a hash, which happens constantly in the parallel test runs. Run r5 failed 16 tests with "bd binary was replaced".

`72fe3f3` makes each store keep its own read-only copy (a reflink where the file system supports it). That was the reviewer's other suggested remedy, and it also means a writer of the source file can no longer change what a store runs. A new test churns links on the source while a store runs. It fails on `c48ac38` and passes on `72fe3f3`. Copies cost about 200 MB of disk per store; test sandboxes are deleted after each scenario.

FINAL_REVIEW_SECTION

### First independent review of the beads integration (for the record)

It found 3 major and 6 minor findings, all fixed in `69af29a`:
- **Major:** `bd init` committed into an enclosing git repository.
- **Major:** a killed `bd init` left a store that was never repaired.
- **Major:** titles the plan accepted were refused by `bd`, which wedged the state root.
- **Minor:**
  - a binary-pin TOCTOU;
  - host-dependent build reproducibility;
  - `claimReady` re-reading after winning;
  - `store.bound` enforced only in the controller;
  - a positive control that could not fail;
  - contract-suite gaps.

## Test integrity

Mutation checks at `72fe3f3` ([final/mutation/](M1-evidence/final/mutation/)) apply one deliberate bug at a time.

**Controller and FakeStore mutants:**
- an illegal transition allowed;
- the USD cap ignored;
- open reservations ignored;
- the store lock removed;
- never-launched reservations left open;
- the chain link dropped from the journal MAC;
- one extra correction attempt;
- evidence hashes not checked.

**BeadsStore mutants:**
- the revision guard dropped;
- the metrics opt-out removed;
- the binary hash not checked;
- the per-spawn identity check removed;
- no store-own git repository;
- half-initialised stores not repaired;
- foreign beads accepted;
- the binding checked only after creating the store;
- a hard link instead of a private copy;
- closing not forced.

Every targeted test selection also passes on the unmutated tree (control runs).

No test was skipped, disabled or weakened to obtain a pass. These expectations changed:
- the hang test now bounds each attempt by its journal timestamps instead of the whole run (store latency is not the property under test);
- one expected error message changed, because the store binding is now checked earlier (the refusal itself is still asserted);
- test calls that create a beads store now pass `create: true` explicitly.

## Budget governor: reservation semantics

Specified in `07-isolation-and-credentials.md` §5.1 and implemented in `src/budget.ts`. Each launch reserves R, the invocation cap plus the largest measured turn, or `max(10 × cap, cap + $1)` until M2-6b measures it; tokens follow the same rule. There are three outcomes for each task and epic scope:
- **reject** when `spent + R > cap`: the task is blocked with an escalation and nothing launches;
- **defer** when `spent + reserved + R > cap`;
- **admit** otherwise, with the reservation journaled before the attempt starts.

Settlement charges one of three amounts:
- the reported cost, with any overshoot journaled;
- the full R when the cost is unknown;
- zero, only when the journal proves the attempt never started.

The approved defaults are $10 / 4M tokens per task and $25 / 20M tokens per epic. They are accounting limits, not permission to spend. `tests/unit/budget.test.ts` has 18 tests, including a property test over 200 random policies against an independent model, and `tests/unit/controller.test.ts` exercises the same rules end to end.

## Defects found by the tests and fixed (first M1 round)

| Found by | Defect | Fix |
|---|---|---|
| Crash test, boundary 4 | A retry after a crash between reservation and attempt start reused the reservation id ("duplicate reservation") | Unique ids; settlement finds the id from the attempt-start record |
| Journal unit test | A crash before a record's newline would make the next append join that line | Open terminates such a line first |
| CLI test | `eo doctor` crashed on a forged `done` task | Reported as a problem |
| Code reading | Same-process lock reuse and concurrent stale-lock clearing | Process-wide registry; breaker lock with re-check |
| State machine cross-check | The diagram lacked `ready → blocked` | Diagram amended (approved) |
| Windows CI | Lock creation over a delete-pending file failed with `EPERM` | Treated as busy; transient rename errors retried |

The first independent review of the controller core (3 major, 8 minor) and its resolutions are in the git history of this file (commit `6b7936a`).

## Limits and open items

- **Stale-lock race.** This is a blocker for production concurrent execution. A contender paused for more than 10 s inside the stale-lock takeover (`src/util/lock.ts`) can remove a fresh lock, so two holders could briefly coexist. M1 runs a single controller. This must be fixed and verified as **M5-0** before any concurrent execution. Recorded in `05` §M5 and threat model T11.
- **Windows `bd` hash depends on the runner's MinGW**, which nothing pins. An image update fails the job closed, and the error names the toolchain. Linux has the same dependency on gcc and glibc, and the build script warns when they differ.
- **`bd` crash recovery was not run on Windows.** Windows CI runs the beads contract, integration and claim-race tests, and the FakeStore crash suite. The 3-hour beads crash sweep ran on Linux only.
- **The check-then-exec gap.** Between the store's identity check and the spawn, a write to its private copy cannot be detected. The copy lives in the state root, which agents never reach (threat model T10).
- **Typecheck** uses the TypeScript and `@types/node` already in this environment. CI does not typecheck, because that would need an npm install.
- **Human gates** (typed word at a TTY) are a speed bump, not a security boundary (architecture §3, T18).

## Next approval gate

M1 needs the owner's review of this report and PR #2. M2 needs the owner's choice of local isolation tier and a go-ahead for live spend (proposed ≤ $2), per `05` §M2.
