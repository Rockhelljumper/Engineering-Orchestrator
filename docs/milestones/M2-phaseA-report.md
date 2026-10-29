# M2 Phase A report — durable test checkpointing (M2-0) and whole-root rollback detection (M2-0b)

Scope: the work the owner approved on 2026-10-23 12:55 UTC, limited to M2-0 (durable long-running test checkpointing and recovery), M2-0b (whole-state-root rollback detection with an independently protected checkpoint), and the FakeRunner tests, deterministic integration tests, documentation and evidence that support them. It uses the approved Node/TypeScript architecture, the existing `FakeStore`/`BeadsStore` interfaces and dependencies already present.

No model was invoked and no API credit was spent. Nothing was installed and no system configuration was changed. No VM or container was created, no Proxmox host or production system was touched, nothing ran unattended, and nothing was merged. Telemetry is off on every `bd` spawn. Phase B and C work is limited to the separate proposal document.

## Status

**Final source commit: `3c99dbf4d0bccc9b7947f4572df5a761643241c5` (`3c99dbf`)** on `claude/m2-phase-a` (draft PR #3). Every counted run below tested this commit with a clean tree. Later commits on the PR change only `docs/` (this report and the evidence); `git diff 3c99dbf HEAD -- src tests scripts deps.lock.json .github package.json tsconfig.json` is empty.

**All eight acceptance requirements are PASSED at `3c99dbf`.** The owner accepted Phase A at this implementation commit on 2026-10-27; merging waits for the final release check. One placement question is a documented residual for Phase B: the anchor's default directory is outside the state root but owned by the same OS account (see [Residuals](#residuals)).

Result states used here: **PASSED**, **FAILED**, **RUNNING**, **INTERRUPTED**, **INCOMPLETE**, **STALE**, **NOT VERIFIED**.

| Item | Value |
|---|---|
| Platform (Linux runs) | Linux 6.18.44 x86_64, Node v22.22.0 (`node` SHA-256 `1f3d442a…f592f933`) |
| `bd` | pinned M1 build `gastownhall/beads` @ `9c6f6e1`, linux-amd64 SHA-256 `2589f95d65136897a5228cb829b7b3bbf755468b26689b764b6816d4d07697ef` |
| Test-source hash recorded by every durable run | `4346e5b510630ebc5c74fe02110002ecff5305ca06ff0ba574e62fd5890f7bfd` |
| CI at `3c99dbf` | `test (ubuntu-24.04)` success, `test (windows-2022)` success, `beads-windows` success (81 pass, 10 platform skips, 0 fail); [run 39969750532](https://github.com/Rockhelljumper/Engineering-Orchestrator/actions/runs/39969750532) |

## What was built

**M2-0, durable test runner** (`tests/support/durable/`, test tooling, not part of the controller). A run directory holds a `manifest.json` that declares every scenario and seed up front, an append-only, fsynced, hash-chained `checkpoints.jsonl`, a `head.json` with the chain head, a heartbeat and a runner lock. Every record carries the run identity: commit, dirty flag (scoped to the source paths), test-source SHA-256, the SHA-256 of `node` and of `bd` when used, the suite parameters and the environment variables the suite reads, and the platform. Each scenario runs in a child process in a fresh directory. The aggregator reports RUNNING, PASSED, FAILED, INTERRUPTED, INCOMPLETE, STALE or NOT VERIFIED; PASSED needs exactly one passing record per declared scenario, under the current identity, with an intact chain and an unchanged manifest. Resume skips only scenarios that passed under the same identity and reruns an interrupted one from scratch. `replay` reruns one scenario with its recorded seed and records nothing. Commands: `npm run durable -- start|resume|status|replay`, and `node tests/support/durable/drill.ts` for the interruption drill.

**M2-0b, rollback anchor** (`src/anchor.ts`, wired into `Controller.open`, the journal's `onAppend` and `eo doctor`). After every journal append the controller advances a MAC'd head `{rootId, anchorId, keyId, root, journalSeq, journalMac}` in an anchor directory outside the state root (the `anchorDir` option, else `EO_ANCHOR_DIR`, else `~/.local/state/eo-anchor` or `%LOCALAPPDATA%\eo-anchor`). `rootId` is derived from the canonical state-root path and `keyId` from the journal key, so a copy at another path or a copy re-signed under a new key is not mistaken for the original. On open, the journal must equal the head or be exactly one record ahead (a crash between the append and the anchor update, which open repairs); anything else is refused before the store is opened, with a forensic record. A state root made before M2-0b, or moved, needs `eo anchor adopt` (an interactive confirmation); accepting a restored backup needs `eo anchor adopt --accept-rollback`, which keeps the replaced head in a forensic record. `eo status` and `eo evidence` refuse a state root the anchor refuses. `eo doctor` reads a consistent snapshot and reports a transition in flight (not damage) while a controller runs.

**Lock fix found by the evidence runs** (`src/util/lock.ts`): see [Runs that do not count](#runs-that-do-not-count).

## Acceptance requirements

| # | Requirement | Result | Evidence (all at `3c99dbf`) |
|---|---|---|---|
| 1 | Per-scenario checkpoints with commit, test-definition, binary, platform and configuration identities | **PASSED** | Every record in every counted run carries the identity above; e.g. [fake/crash-sample-anchor/checkpoints.jsonl](M2-phaseA-evidence/final/fake/crash-sample-anchor/checkpoints.jsonl) (142 records, chain head in [its final.json](M2-phaseA-evidence/final/fake/crash-sample-anchor.final.json)); Beads runs also carry the `bd` hash ([beads/](M2-phaseA-evidence/final/beads/)). Tests: "a source-file change makes a run STALE…", "duplicated, foreign, mixed-identity or undeclared records … never give PASSED", "a checkout git cannot list has no identity…". STALE demo: the `3c99dbf` crash-sample run read from `1624fa4` reports STALE (commit, testSourceSha256), exit 1, and its resume is refused, exit 3 ([negative/stale-demo.json](M2-phaseA-evidence/final/negative/stale-demo.json), [negative/stale-resume.err](M2-phaseA-evidence/final/negative/stale-resume.err)) |
| 2 | Safe recovery after simulated process, worker and container termination | **PASSED** | Interruption drills ([drills/](M2-phaseA-evidence/final/drills/)): `crash-escalation phase=anchor` (seed 11) and `claim-race store=fake rounds=30` (seed 12). In each, 3 SIGKILLs of the runner's whole process group landed mid-scenario in 3 different runners, a SIGKILL of only the scenario process landed while the runner lived, and a simulated container restart killed every process and resumed from the persisted directory alone. The run read RUNNING within the stall window, then INTERRUPTED, never PASSED; after resuming it PASSED with the same scenarios as an uninterrupted run, none counted twice, the interrupted scenario rerun from scratch, every resume logged. The underlying controller recovery is shown by the crash suites under the durable runner: FakeStore crash-sample 70/70 in both phases, crash-escalation 37/37 in both phases, random-kills 8/8, claim-race 100/100 ([fake/](M2-phaseA-evidence/final/fake/)); Beads (pinned `bd`): crash-sample 70/70 and crash-escalation 37/37 in both phases, random-kills 8/8, claim-race 20/20 ([beads/](M2-phaseA-evidence/final/beads/)). The `anchor` phase crashes between the journal append and the anchor update at every boundary |
| 3 | Reject incomplete, stale, duplicated, truncated or modified evidence without a false PASS | **PASSED** | Drill checks: a truncated log ("log truncated: 84 records, head says 86"), an edited record ("hash mismatch"), reordered records ("chain broken"), a missing manifest (NOT VERIFIED), another commit (STALE), another configuration (resume refused as STALE, exit 3). Behavioural tests: duplicated pass records, a lone `scenario.end`, foreign or mixed identities, undeclared scenarios, a torn last line, a manifest edited to drop a failed scenario. Negative demo: [negative/manifest-attack-3c99dbf.out](M2-phaseA-evidence/final/negative/manifest-attack-3c99dbf.out) (resume refused, exit 4, status NOT_VERIFIED) |
| 4 | Independently protected rollback anchor outside the state root being verified | **PASSED** (placement residual for Phase B) | `RollbackAnchor` refuses an anchor directory inside the state root and a state root inside the anchor directory ("an anchor inside the state root … is refused"). The head is MAC'd under the anchor's own key; `anchor.json` is created atomically. Residual: the default directory is owned by the same OS account as the state root, so it protects against restores of the state root (backups, copies, a worker with access only to the state root) but not against that account rewriting both; moving it beyond that account is Phase B decision 3 |
| 5 | Recover legitimate interrupted journal and anchor updates without accepting an older restored state | **PASSED** | "a crash between the journal append and the anchor update is recovered on open", "a crash right after journaling the binding … is recovered", and the `anchor` phase of crash-sample (70 boundaries) and crash-escalation (37) on FakeStore and Beads. Refused: "an older copy of the whole state root is refused at every point; nothing runs again, no spend is lost", "a journal more than one record ahead …", "a different journal history of the same or greater length", "an older copy re-signed with a new journal key … with or without its binding", "a copy at another path is not adopted without an operator", "the anchor never moves backwards" |
| 6 | Preserve forensic evidence on integrity failures | **PASSED** | Every anchor refusal writes a `rollback-refused` record with the reason, the raw head bytes (base64) and the raw journal bytes ("a tampered anchor head is refused, and the forensic record keeps its bytes and the journal"); accepting a rollback writes `rollback-accepted` with the replaced head. The durable runner copies a torn tail fragment to `forensics/<ts>-<inv>-torn-tail.bin` before truncating, and on an integrity reset moves the damaged log and copies the manifest into `forensics/` (drill check "resuming a damaged log keeps it in forensics/ and reruns every scenario") |
| 7 | Negative tests that fail on the vulnerable implementation and pass on the correction | **PASSED** | Black-box attacks ([negative/](M2-phaseA-evidence/final/negative/)): whole-root restore is VULNERABLE on `main` `9007d53` (finished tasks ran again, 2 → 4 executions) and DEFENDED at `3c99dbf`; restore re-signed with a new key is VULNERABLE on `main` and on the first anchor version `7286274`, DEFENDED at `3c99dbf`; the manifest attack is VULNERABLE (PASSED) at `7286274` and DEFENDED at `3c99dbf`. Mutation: 39/39 M2 mutants killed ([mutation/mut-m2-final.txt](M2-phaseA-evidence/final/mutation/mut-m2-final.txt)), 4/4 lock mutants killed ([mutation/mut-lock.txt](M2-phaseA-evidence/final/mutation/mut-lock.txt)); the M1 mutation checks still kill every mutant: FakeStore 18/18, Beads 14/14 with 13/13 unmutated controls passing ([mutation/](M2-phaseA-evidence/final/mutation/)) |
| 8 | New behaviour independently reviewable and reproducible | **PASSED** | Each change is a separate commit (table below). Every counted run is reproducible from the scripts in [scripts/](M2-phaseA-evidence/scripts/) and the commands in this report; any random-kill seed can be rerun with `replay`. Two independent reviews (security, correctness) ran on the branch; their findings and fixes are below |

## Commits

| Commit | Change |
|---|---|
| `7286274` | Rollback anchor and durable runner (first version) |
| `8f58e7b` | Tests: anchor repair on open, `doctor` beside a live controller |
| `51ff004` | M2-0b review fixes (path and key identity, adopt, atomic creation, status and evidence checks, forensic bytes) |
| `9841d94` | M2-0 review fixes (manifest change, end/start pairing, identity without git, torn tails, baselines, drill kills) |
| `0e6bcef` | Truncation test asserts its own message |
| `61a5d0d` | Docs (threat model T10, implementation plan, README) |
| `1624fa4` | Windows test fixes (POSIX-only drill, `process.abort()`) |
| `3c99dbf` | Lock: empty lock stale after 2 s, breaker takeover in one attempt, holder diagnostics |

## Counted runs (all at `3c99dbf`, clean tree, 2026-10-23 UTC)

| Run | Started → finished | Command | Result |
|---|---|---|---|
| FakeStore unit | 14:40:47 → 14:40:57 | `node --test "tests/unit/**/*.test.ts"` | **PASSED** 114/114 |
| FakeStore integration | 14:40:57 → 14:41:21 | `node --test --test-concurrency=1 "tests/integration/**/*.test.ts"` | **PASSED** 53, 20 skipped (Beads-only and tracing tests; Beads run below) |
| FakeStore behavioural | 14:41:21 → 14:48:30 | `node --test --test-concurrency=1 "tests/behavioral/**/*.test.ts"` | **PASSED** 14/14 |
| Typecheck | → 14:48:34 | `tsc --noEmit -p . --typeRoots /opt/node-tools/node_modules/@types` | **PASSED** exit 0 |
| Durable crash-sample, journal / anchor | 14:27:08 → 14:29:19 | `npm run durable -- start <dir> --suite crash-sample --param phase=journal\|anchor` | **PASSED** 70/70, 70/70 |
| Durable crash-escalation, journal / anchor | 14:29:19 → 14:30:23 | `… --suite crash-escalation --param phase=…` | **PASSED** 37/37, 37/37 |
| Durable random-kills | 14:30:23 → 14:30:57 | `… --suite random-kills --param seeds=8` | **PASSED** 8/8 |
| Durable claim-race (FakeStore) | 14:30:57 → 14:33:36 | `… --suite claim-race --param store=fake --param rounds=100 --param workers=20` | **PASSED** 100/100 |
| Drill crash-escalation | 14:27:09 → 14:30:30 | `node tests/support/durable/drill.ts <out> --suite crash-escalation --param phase=anchor --kills 3 --stall-window 5 --seed 11` | **PASSED** every check |
| Drill claim-race | 14:30:30 → 14:32:47 | `… --suite claim-race --param store=fake --param rounds=30 --param workers=10 --kills 3 --stall-window 5 --seed 12` | **PASSED** every check |
| Beads crash-sample, journal | 14:32:55 → 16:45:17 | `EO_TEST_STORE=beads EO_BD_BIN=/opt/beads-9c6f6e1/bd EO_REQUIRE_BD=1 npm run durable -- start <dir> --suite crash-sample --param phase=journal` | **PASSED** 70/70 |
| Beads crash-sample, anchor | 14:39:51 → 16:54:30 | same env, `phase=anchor` | **PASSED** 70/70 |
| Beads crash-escalation, journal / anchor | 14:39:51 → 15:28:12; 16:54:30 → 17:27:34 | same env, `--suite crash-escalation` | **PASSED** 37/37, 37/37 |
| Beads random-kills | 16:54:30 → 17:12:28 | same env, `--suite random-kills --param seeds=8` | **PASSED** 8/8 |
| Beads claim-race | 17:27:35 → 17:31:59 | same env, `--suite claim-race --param store=beads --param rounds=20 --param workers=10` | **PASSED** 20/20 |
| Beads unit + integration | 17:31:59 → 18:40:35 | same env, `node --test --test-concurrency=1 tests/unit/*.test.ts tests/integration/*.test.ts` | **PASSED** 194, 11 skipped (6 copy and 4 edit the FakeStore state root, Beads equivalents in `beads.test.ts` where they exist; 1 FakeStore-timing test) |
| Negative demos | 14:50 | `node rollback-attacks.ts <checkout>`, `manifest-attack.sh <checkout> <dir>` | DEFENDED at `3c99dbf`; VULNERABLE on `9007d53` and `7286274` as listed |
| M2 mutation check | 14:51 → 15:19 | `python3 -I mutate-m2b.py <worktree>` | **PASSED** 39/39 killed |
| Lock mutation check | → 14:34 | `python3 -I mutate-m2c.py <worktree>` | **PASSED** 4/4 killed |
| M1 mutation check, FakeStore | 14:34 → 14:36 | `python3 -I mutate-final2.py <worktree>` (from M1 evidence) | **PASSED** 18/18 killed |
| M1 mutation check, Beads | 15:28 → 15:38 | `python3 -I mutate-beads-final2.py <worktree>` (from M1 evidence; `EO_BD_BIN` set) | **PASSED** 14/14 killed, 13/13 controls pass |

The durable suites ran two at a time; the Beads suites three at a time. Every run directory's `status` re-derives the result from its own records; the report's numbers are those `status` outputs.

## Reviews and fixes

Two independent reviewers were each given the code, not the author's conclusions.

**Security review of M2-0b.** Critical: an older copy of the state root, re-signed with a new journal key and with its binding record stripped, was accepted as a fresh state root. Fixed in `51ff004`: a state root is identified by its canonical path, and the head records the journal key's fingerprint, so a re-keyed copy is refused ("the journal key differs…") and a copy at another path needs an operator's `eo anchor adopt`. Minor findings, all fixed: non-atomic `anchor.json` creation, a symlinked prefix of a path not yet created, `eo status` and `eo evidence` not consulting the anchor, forensic records without the head bytes, and the lock not re-reading its nonce after writing.

**Correctness review of M2-0.** Critical: editing `manifest.json` to drop a failed scenario and resuming turned FAILED into PASSED. Fixed in `9841d94`: records carry the manifest hash; a changed manifest gives NOT VERIFIED and is never resumed. Major, all fixed: the drill's kills could land between scenarios (now each kill is checked to land mid-scenario in a different runner, and the worker kill to land on a live scenario process); a torn last line was appended after (now cut back first, keeping the fragment); crash suites did not check their baselines (now `assertExpectedBaseline`); identity fell back to placeholders without git (now fails closed). Minor, fixed: end/start pairing, a scenario that signals itself counted as interrupted, crash-injection variables leaking into a run, lock removal by another invocation, `replay` of a STALE run.

**Mutation survivor.** "a truncated log accepted" first survived because a later check caught the same file; the test now asserts the truncation message itself (`0e6bcef`).

## Runs that do not count

Kept under [`M2-phaseA-evidence/not-counted/`](M2-phaseA-evidence/not-counted/).

- **Evidence at `1624fa4`: random-kills FAILED 7/8.** Seed 4's resume was refused with "another controller holds …" although no controller was running. Reproduced with a probe: a killed controller left both a dead lock and a takeover breaker; while the breaker was fresh every open refused, and after it expired the first open still failed because clearing the breaker did not retry the takeover. Fixed in `3c99dbf` (an expired breaker is cleared and the takeover retried once; an empty lock is stale after 2 s; the refusal says whether the holder is running), with a new integration test and 4 lock mutants. The superseded runs are kept whole; every other suite in that group passed.
- **60-seed random-kills diagnostic** (dirty tree on top of `1624fa4`, while the lock fix was being written): 57/60, no lock failure reproduced. Seeds 21, 24 and 59 failed with "no kill landed; the scenario did not exercise recovery": their random kill delays fell after the run had finished. This is the suite failing closed (a seed that tests nothing is a failure, not a pass), and none of them is among the counted seeds 1–8.

## Residuals

- **Anchor placement (Phase B decision 3).** The default anchor directory is outside the state root but writable by the same OS account. It stops a restored or copied state root; it does not stop that account (or code running as it) from rewriting the anchor too. The Phase B proposal recommends a separate `eo-anchor` account in the isolation guest.
- **Windows drill scope.** The interruption drill uses POSIX process groups and is skipped on Windows CI with that reason; the other durable-runner tests and all anchor tests run there. Phase B item B8 adds a Job Object kill path.
- **Lock window.** Between a killed holder and its takeover there is a window of up to 2 s (empty lock) or 10 s (breaker), during which a resume is refused with a message naming the holder as not running. Tests retry once after 10.5 s.
- **Consistent rewrite of a durable log.** The chain detects truncation, edits and reordering, but someone who can write the run directory can rewrite the whole log and head consistently. The durable runner is test tooling that runs where the controller runs; it is not a defence against that account.
- **macOS case folding.** `canonicalRoot` lower-cases paths on darwin and win32. A case-sensitive APFS volume would map two distinct roots to one id; not tested on macOS.
- **Random-kills seeds above 8** can fail closed with "no kill landed" (see above).
- **Beads-specific skips.** Anchor tests that copy a FakeStore state root are skipped on Beads; the Beads crash suites cover the anchor phase at every boundary instead.

## Evidence layout

[`M2-phaseA-evidence/`](M2-phaseA-evidence/), with SHA-256 of every file in [MANIFEST.sha256](M2-phaseA-evidence/MANIFEST.sha256):
- `final/fake/`, `final/beads/`: each run's `manifest.json`, `checkpoints.jsonl`, `head.json`, `<run>.final.json` and `<run>.stderr` (scenario work directories omitted).
- `final/drills/`: drill logs and `drill-report.json`, with each drill phase's run directory.
- `final/suites/`: TAP output and the typecheck log.
- `final/negative/`: attack scripts and outputs, the STALE demo.
- `final/mutation/`: mutation scripts and outputs.
- `scripts/`: the runners used for the counted runs.
- `not-counted/`: the superseded `1624fa4` group and the 60-seed diagnostic.
