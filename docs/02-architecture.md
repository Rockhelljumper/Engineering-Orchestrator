# 02 — Architecture

Working name: **eo** (Engineering Orchestrator).

## 1. Design principles

1. **Deterministic code decides; agents propose.** Every state transition, gate decision and "done" verdict is made by the controller, a normal program with tests. No agent output, summary or self-report can mark a task complete.
2. **Evidence is re-produced, not reported.** The controller re-runs verification in a fresh workspace at the submitted commit and stores hashed logs. An agent saying "tests pass" counts for nothing.
3. **Least privilege per role.** Each role gets its own tool set. Reviewers have no `Write`, `Edit` or code-running tools at all.
4. **Single writer for state.** Only the controller writes the task store, journal and evidence. They live in a **state root outside every workspace**, which agent-run code cannot write.
5. **Everything an agent reads is data.** Repository instructions, tool output, docs, failing logs and other agents' output are passed in delimited data blocks and never widen permissions.
6. **Fail closed and escalate.** On ambiguity, exhausted budget, repeated failure or policy violation, work stops and a human gets one clear escalation record.
7. **Nothing leaves the sandbox without a human.** No merges to protected branches, no deploys, no pushes outside `eo/*` branches.
8. **Agent-written code never runs as the controller.** Workers *and* verification (which executes agent-written code through the test suite) run inside an isolation boundary with no write access to the state root, the controller's git directory or the policy. The boundary is a hardened container or a VM; a separate low-privilege Windows user is allowed only for a supervised pilot, and WSL2 by itself does not count (see `07-isolation-and-credentials.md` §2). Without that separation, code under test could rewrite state or forge results, so principles 1, 2 and 4 would rest on the agent's goodwill.

## 2. System context

```mermaid
flowchart LR
  user([User in VS Code / Claude Code chat])
  subgraph host[Developer host or isolated worker]
    plugin[eo Claude Code plugin\nslash commands]
    ctl[eo controller CLI\nNode/TypeScript\noutside the boundary]
    subgraph sroot[State root, controller-only]
      store[(beads task graph)]
      journal[(journal.jsonl HMAC chain\n+ evidence/)]
      policy[(eo.policy.json)]
      mirror[(bare mirror of target repo)]
    end
    subgraph sandbox[Isolation boundary: hardened container or VM]
      ws[per-attempt clone]
      w1[[claude -p worker\nrole profile]]
      vr[[verification run\ncontroller-owned test command]]
    end
  end
  repo[(Target git repo\nbranches eo/*)]
  api[(Anthropic API)]
  user --> plugin --> ctl
  ctl <--> sroot
  ctl -- clone from mirror --> ws
  ctl -- spawn, scrubbed env --> w1
  ctl -- spawn --> vr
  w1 -- edits only its clone --> ws
  vr -- reads clone, streams results over a pipe --> ctl
  w1 --> api
  ctl -- fetch commit, hooks disabled --> mirror
  ctl -. user-run eo publish, eo/* only; M8: staging repo .-> repo
  user -. reviews, opens PR, merges .-> repo
```

Trust boundaries are drawn in the threat model (`04-threat-model.md`).

## 3. Components

| Component | Responsibility | Notes |
|---|---|---|
| **Controller CLI (`eo`)** | Owns the state machine, scheduler, gates, budgets, journal, evidence. All commands are idempotent and resumable. | TypeScript on Node 22 (already required by Claude Code, available on Windows and Linux). Minimal runtime deps (see dependency map). |
| **State root** | Holds task store, journal, evidence, policy, HMAC key and the bare mirror of the target repo. | Outside any workspace: `%LOCALAPPDATA%\eo\<project>\` on Windows, `~/.local/state/eo/<project>/` on Linux. Writable only by the controller's OS account. |
| **TaskStore adapter** | Task graph, dependencies, ready queue, atomic claim, lease, heartbeat, reclaim, notes. | Beads (`bd`) by default (ADR-002), in-memory fake for unit tests, Backlog.md as fallback. Contract-tested. |
| **Journal** | Append-only `journal.jsonl` of write-ahead intent and outcome records, fsynced per record. Used for crash recovery and audit. | Each record carries an HMAC over (previous HMAC + record) using a key stored in the state root, so it cannot be rebuilt by anyone without the key. |
| **Evidence ledger** | `evidence/<task>/<attempt>/` with a `manifest.json` listing every artifact and its SHA-256; the manifest is HMAC-signed. | Logs, diffs, verdict JSON, cost records. |
| **Workspace manager** | Creates **one independent clone per attempt** (not a git worktree, because worktrees share the controller's `.git`, hooks and config) from the bare mirror, delivered into the isolation boundary (a container volume or a directory only the pilot user can write). | The controller brings results back with `git fetch` from the clone into the mirror, always with `-c core.hooksPath=<empty dir> -c core.fsmonitor=false`, and never reads the clone's `.git/config` or hooks. Branch naming `eo/<epic>/<task>/a<n>`. |
| **Worker runner** | Launches `claude -p` for a role, inside the isolation boundary, with a generated settings file, tool set, budget, timeout and scrubbed environment; parses structured JSON output; records cost and tokens. | Also has a **scripted fake runner** for deterministic tests and failure simulation. |
| **Guard hook** | `eo hook guard` used as a `PreToolUse` hook inside workers: denies edits to protected paths and Bash commands outside the role allowlist. | Early warning only; the real gate is the post-hoc diff check (§6.3). Because invalid settings files are silently ignored, every worker run starts with a **hook canary** (a scripted denied action) and the attempt is aborted if the hook did not fire. |
| **Verifier** | Runs verification in a fresh clone at the submitted commit, inside the isolation boundary, with no agent involved. | Uses the **controller-owned** test command and runner config from policy, not the repository's `package.json` scripts. Results are cross-checked with the test-integrity controls in §6.4. |
| **Gate engine** | Evaluates Definition of Done from policy + evidence. Pure function, heavily unit-tested. | §6 |
| **Budget governor** | Tracks estimated USD, input/output tokens and wall-clock per attempt, task and epic; refuses to start work unless `spent + reserved` fits. | `--max-budget-usd` and the reported `total_cost_usd` are client-side estimates that can overshoot, not billing limits. Each launch therefore reserves `cap + maxTurnCost` (initially `max(10 × cap, cap + $1)`), a wall-clock timeout bounds every run, and unattended tiers require a provider-side Console spend limit as the backstop (`07` §5). |
| **Integration queue** | Serially merges accepted task branches into `eo/<epic>/integration` in the mirror, re-verifies after each merge, routes conflicts. | Never touches `main`. |
| **Escalation manager** | Creates escalation records, sets tasks `blocked`, surfaces them in status and through the configured notification channel. | One record per blocker, with reason, evidence and the question for the human. Unattended channel in §9. |
| **Claude Code plugin** | Slash commands, role agent definitions and the status view used from chat. | Installed per project from this repo (local `--plugin-dir` or local marketplace), not from a remote marketplace. |
| **Policy file** | `eo.policy.json`: approved repositories, protected paths, role tool profiles, Bash allowlists, test command, budgets, retry limits, concurrency, risk paths. | Stored in the state root, **not in the target repo**, so no agent commit can change it. Changed only by `eo policy edit`, which requires an interactive confirmation and records the new hash in the journal. |

## 4. Roles

Agents are short-lived `claude -p` invocations, one per step, each with a fresh context. A role is a prompt + tool profile + output schema.

| Role | Purpose | Tools | Output (`--json-schema`) |
|---|---|---|---|
| Architect | Turn an epic into a design note: components, interfaces, risks | Read, Grep, Glob | `design.json` |
| Planner | Decompose into tasks with dependencies, acceptance criteria, risk tags, open questions | Read, Grep, Glob | `plan.json` |
| Test author | Write acceptance tests for a task from its criteria, before implementation | Read, Grep, Glob, Edit, Write limited to the task's test paths; Bash limited to the controller's test command | `report.json` |
| Implementer | Make the change in its clone | Read, Grep, Glob, Edit, Write (not protected paths); Bash limited to build/test allowlist; no web tools | `report.json` |
| Reviewer | Independent code review of diff (including new tests) against criteria | Read, Grep, Glob only | `verdict.json` |
| Security reviewer | Security review of diff against a checklist, including test-harness tampering | Read, Grep, Glob only | `verdict.json` |
| Integration reviewer | Review the integrated epic diff, cross-task consistency | Read, Grep, Glob only | `verdict.json` |
| Conflict resolver | Resolve a merge conflict as a normal implementation task | Implementer profile | `report.json` |

The verifier is deliberately **not** an agent. Read-only roles are candidates for `--restricted` mode (evaluated in M2).

Independence rules enforced by the controller:
- The reviewer for an attempt is a separate invocation that never sees the implementer's transcript, only the task spec, the diff and controller-produced verification results. The implementer's self-report is shown labelled as an unverified claim.
- **Test-first is the default for every feature or bug-fix task**: the planner pairs it with a test-author task that lands first and whose test files are then protected from the implementer. The planner may mark a task `tests: existing` (e.g. pure refactor covered by existing tests) only with a reason, which the plan gate shows the human.
- Optional model diversity (e.g. reviewer on a different model than implementer) is a policy setting.

Role prompts are adapted from Oh My ClaudeCode's agent definitions (MIT, attributed), rewritten for these tool profiles and schemas.

## 5. Task lifecycle

```mermaid
stateDiagram-v2
  [*] --> planned: plan approved by human
  planned --> ready: deps done
  planned --> blocked: open question
  ready --> implementing: atomic claim (lease)
  ready --> blocked: budget can never fit / policy refusal before launch
  implementing --> verifying: worker exits with commit
  implementing --> ready: interrupted (infra retry left)
  implementing --> blocked: infra retries exhausted / budget / timeout / policy violation / invalid output twice
  verifying --> reviewing: all checks pass + protected files intact
  verifying --> ready: checks fail (attempt+1, failure evidence attached)
  verifying --> blocked: attempts exhausted or repeated identical failure
  reviewing --> security_review: approve and risk-tagged
  reviewing --> accepted: approve, no risk tag
  reviewing --> ready: changes requested (attempt+1, findings attached)
  reviewing --> blocked: attempts exhausted / invalid verdict twice
  security_review --> accepted: no blocking findings
  security_review --> ready: blocking findings (attempt+1)
  security_review --> blocked: attempts exhausted
  accepted --> integrating
  integrating --> done: merged + integration verification passes
  integrating --> ready: conflict or integration failure (integration attempt left)
  integrating --> blocked: integration attempts exhausted
  blocked --> ready: human resolves
  done --> [*]
```

Every loop in the diagram has a counter and a transition to `blocked`:

| Counter | Default | Counts |
|---|---|---|
| `maxAttempts` | 3 | Correction attempts (verification failure, review or security changes requested) |
| Repeated failure | 2 | Consecutive attempts with the same failure signature (normalised failing test IDs + error class) escalate early |
| `maxInfraRetries` | 2 | Worker crash, kill, hang/timeout, API error; separate from correction attempts |
| `maxInvalidOutput` | 1 re-run | Output that fails its JSON schema (plan, report, verdict) |
| `maxIntegrationAttempts` | 2 | Conflict or post-merge verification failure |
| Budget | policy | USD and tokens per attempt, task, epic |

`blocked` always carries an escalation record. Only a human command moves a task out of `blocked`.

beads statuses are coarse, so the fine-grained state lives in a controller-managed label/field on the beads issue plus the journal. Every task also records `journalSeq`, the position of the journal record of the last transition applied to it. The journal is authoritative only in one direction: a store **behind** the journal by exactly the journal's last transition is a crash between the append and the store update, and the next controller open finishes it. Any other disagreement (a task ahead of or diverged from the journal, two tasks behind, a task the journal never planned, evidence or escalation files the journal never recorded) is refused on open, before any command writes, with a forensic record under `<state root>/forensics/`; `eo doctor` reports the same problems. Restoring the journal and the store together to an older consistent snapshot is not detectable from inside the state root and is tracked as M2-0b (see the threat model, T10).

## 6. Quality gates and Definition of Done

### 6.1 Plan gate (before any implementation)
- `plan.json` validates against the schema; dependency graph is acyclic; every task has at least one acceptance criterion with a **machine check** (a test ID or command and expected outcome) or an explicit `review_only` flag with a reason.
- Open questions are listed; dependent tasks start `blocked: needs-clarification` instead of being guessed.
- A human approves the plan (`/eo:approve`), which records the plan hash. Unattended mode can only run already-approved plans whose hash matches.

### 6.2 Test-first gate
For each test-author task, before its tests are accepted:
- The new tests must be discovered by the controller's runner, and on the **base commit** they must fail **at assertion level** (an assertion error inside the new test IDs). Load errors, syntax errors, import failures or a crashed runner do not count as red evidence.
- Existing tests must still pass on base.
- The reviewer checks the tests against the acceptance criteria (each criterion maps to at least one test ID) before the tests are landed and protected.

### 6.3 Verification gate (controller-run, inside the isolation boundary)
In a fresh clone at the submitted commit:
1. **Diff check.** No changes to protected paths. Protected by default: test files owned by other tasks, **test support code** (helpers, fixtures, mocks, setup files, snapshots, and every non-production module that the base commit's tests import, found by the controller's import-graph analysis), test runner config, `package.json` (whole file, or at least `scripts`, `dependencies`, `devDependencies`), `tsconfig*.json`, lockfiles, `.github/`, CI config, `.claude/`, `CLAUDE.md`, `.mcp.json`, `.git*` files. A task may own specific protected paths only if the approved plan says so (e.g. a dependency-adding task owns the lockfile, and is then always security-reviewed). SHA-256 of every protected file must equal the base commit's.
2. **Controller-owned test command.** The verifier calls the test runner directly from policy (e.g. `node --test --test-reporter=<controller reporter> <discovered files>`), never `npm test` or repository scripts.
3. **Inventory cross-check.** The controller statically discovers test IDs; the reported results must include exactly that set (none missing, none extra), so an early `process.exit(0)` or a suppressed suite fails the gate. Test inventory on head ⊇ base; skip/only markers not increased; assertion counts per pre-existing test not reduced (for the sample project's stack; detectors are pluggable).
4. Every machine check in the acceptance criteria passes; full suite passes; lint/typecheck pass if configured.
5. Results are stored with hashes; the exact replay command is recorded.
6. The independent test-integrity controls in §6.4 all pass.

### 6.4 Test-integrity controls (independent of the implementer's tests)

The visible tests are written by an agent and executed alongside code another agent wrote, so passing them is necessary but not sufficient. The controller adds checks that neither agent controls:

| Control | What it does | What it catches |
|---|---|---|
| **Holdout acceptance tests** | A second, separate test-author invocation writes tests from the approved acceptance criteria only. They are stored in the state root, never placed in any worker's clone, and copied into the verification clone only at verification time. On failure the implementer receives **only the criterion ID and pass/fail**, never assertion messages, expected values, logs or source (assertion diffs would leak expected values across attempts) | Implementations tuned to the visible tests; weak visible tests |
| **Forgery canaries** | Each verification run adds controller-generated tests with a fresh random nonce: one that must fail, one that must pass and echo the nonce. A run where the failing canary is reported as passing, the nonce is missing or wrong, or the canary counts don't match is treated as **forged**: the task is blocked and a security finding is raised. Anything inside the boundary can read the nonce, so canaries catch **naive** forgery only | Blanket "all pass" output, `process.exit(0)` tricks, suppressed suites |
| **Out-of-process collection** | Tests run with per-file process isolation (`node --test` default); the reporter runs in the parent process and streams results to the controller over a pipe that leaves the boundary (no result file inside the boundary); exit code, streamed output and inventory must agree | In-process monkeypatching of the reporter; overwritten result files |
| **Mutation check on changed code** | A built-in mutator (using the TypeScript compiler API, already a dev dependency, so no new install) applies a fixed operator set (flip comparison, off-by-one, negate condition, replace return, drop statement) to functions changed by the task. The visible + holdout suite must kill at least the policy threshold (default 80%) of mutants; a mutant may be excluded as equivalent only if it is listed with a reason in the stored report, which the reviewer checks. The suite must also kill a controller-chosen sentinel mutant. Surviving mutants go to the reviewer and back to the test author | Tests that pass regardless of the code; forged "all pass" results (the sentinel mutant would also "pass") |
| **Base cross-run** | Head's new tests are run against the base production code (they must fail at assertion level), and base's tests against the head (they must pass) | Tests that test nothing; regressions hidden by edited helpers |
| **Protected support code** | Helpers, fixtures and anything tests import from outside production code are protected (§6.3 step 1) | Helper rewrites such as an `assertEqual` that always passes |
| **Tamper scan of the diff** | Static scan of changed production code for result-tampering patterns: `process.exit`, writes to stdout/stderr outside logging, access to `/proc`, child-process or signal APIs, reassignment of globals, imports of test-runner modules. Hits go to the security reviewer as mandatory review items | Deliberate forgery code, which has to appear in the diff |

These controls are themselves tested by scenarios S9 and S10 (`06`). Residual risk: code inside the boundary shares it with the test runner, so a deliberately written forgery (one that reads the nonce, recognises the sentinel mutant by hashing its own source, and rewrites the parent's output) cannot be excluded by runtime checks alone. Such code has to exist in the diff, which is why the tamper scan, the security reviewer and the human PR review are the final line. This is stated as a limitation, not hidden.

### 6.5 Review gate
- Reviewer verdict `approve` with zero `blocking` findings. Reviewer must reference each acceptance criterion by ID with a pass/fail judgement; missing criteria = invalid verdict = one re-run, then `blocked`.
- Findings use fixed categories, including `prompt-injection` (content in the repo or inputs that tries to instruct agents), which must cite the file and line.
- Security review for tasks tagged risky (touches risk paths, adds dependencies, owns a protected path, handles input parsing, auth, file system, subprocess) and always once on the integrated epic. `high`/`critical` findings block.

### 6.6 Done
A task is `done` only when the controller finds, for the merged commit: verification evidence (6.3) and test-integrity controls (6.4) passing, a valid review verdict (6.5), security verdict if required, integration verification passing after merge, and an HMAC-valid evidence manifest whose hashes match the files on disk. `eo verify --task <id> --replay` re-runs the checks and must reproduce the result.

## 7. Durability and resume

- beads holds the task graph, claims and leases. The journal holds the step-by-step intent/outcome log. Evidence is on disk in the state root. Chat context holds nothing that matters.
- Each step writes an *intent* record before acting and an *outcome* record after. On `eo resume` (also run automatically at the start of `eo run`, and in read-only form by the plugin's `SessionStart` hook):
  1. Replay the journal; verify its HMAC chain. Compare every task's state, counters and `journalSeq` with the state the journal implies, and refuse (changing nothing, writing a forensic record) unless the only difference is the journal's last transition left unapplied by a crash. A torn final journal line is copied byte for byte into a forensic record before it is dropped.
  2. For intents without outcomes: if the worker process is gone or its lease expired, mark the attempt `interrupted`, preserve its clone for audit, call `bd reclaim`, and return the task to `ready` (counts against infra retries; exhausted → `blocked`).
  3. Verification steps are simply re-run (they are deterministic and run in a fresh clone).
  4. Integration steps are checked against git state in the mirror (is the merge commit present?) and completed or rolled back.
- The controller renews leases while a child process is alive, so a dead controller also lets leases expire.

## 8. Parallel execution

- `maxConcurrency` (default 2, max set in policy) workers at once; the scheduler only starts tasks whose dependencies are done and whose budget reservation fits.
- Each attempt has its own clone; in L1, L2 and PX each attempt runs in its own container with only its clone mounted, so workers cannot read each other's clones. In the supervised pilot (P) one pilot user hosts all clones, so sibling access is possible; the pilot therefore runs with `maxConcurrency=1`.
- The planner's estimated file sets are used to avoid scheduling two tasks predicted to touch the same files concurrently (soft constraint).
- Merges are serialised through the integration queue. A conflict creates a conflict-resolution attempt (implementer profile), bounded by `maxIntegrationAttempts`.

## 9. Execution tiers

Full comparison of Windows users, WSL2, containers and VMs, and the hardening each tier requires, is in `07-isolation-and-credentials.md`. Summary:

| Tier | Layout | Allowed use |
|---|---|---|
| P supervised pilot | Controller as the Windows user; workers and verification as a separate standard local Windows user | Disposable sample project only, with a person watching; no unattended runs |
| L1 local container | Workers and verification in hardened Docker Desktop containers, no Windows bind mounts, egress proxy | Sample project and approved repositories, attended |
| L2 local VM (preferred local) | Hyper-V or VirtualBox Linux guest running the controller and L1-style containers; VS Code Remote-SSH from Windows | Approved repositories, attended or unattended |
| PX Proxmox worker | As L2 on a dedicated Proxmox node, isolated VLAN, snapshot per run | Unattended scheduled runs (M8) |

WSL2 on its own is not a tier: it runs as the Windows user, auto-mounts the Windows drives and can launch Windows programs, and an agent with root in the distro can re-enable anything turned off in `wsl.conf`.

The controller refuses to operate on a repository whose remote URL or path is not in the policy's `approvedRepositories` list, and it records the tier of every run in the journal and the run report.

Unattended mode (`eo run --unattended`) refuses to start unless: running in L2 or PX (detected marker + policy), plan already approved with matching hash, budget caps set, the user has confirmed a provider-side spend limit on the worker's API key, and permission mode is `dontAsk` with `--permission-prompts none` (fail closed). It never uses `bypassPermissions`.

**GitHub writes.** Before M8 the controller holds no GitHub credentials; the user publishes `eo/*` branches with `eo publish`. Unattended runs push only to a separate staging repository whose rulesets A1, A2 and B (`07` §4) allow only `eo/**` branch pushes, no tag changes, and no deletions or force pushes; the controller's staging deploy key exists only for that repository (deploy keys cannot be limited to branches, so the restriction comes from rulesets and is tested with real rejected pushes; `07` §4).

**Unattended escalation channel:** escalations are written to the state root and pushed as a status file on the `eo/<epic>/status` branch of the staging repository; optionally (policy, approved in M8) the controller opens a GitHub issue there using a token scoped to issues only. The user sees blockers without logging into the worker.

## 10. Chat workflow (requirement 9)

Inside Claude Code (terminal or VS Code extension):

| Command | Effect |
|---|---|
| `/eo:plan <epic description>` | Architect + planner run, plan is validated and shown with open questions and cost estimate |
| `/eo:answer <question-id> <text>` | Resolve an open question; affected tasks are re-planned |
| `/eo:approve` | Approve the shown plan (records approver and plan hash) |
| `/eo:run` | Run the scheduler in the foreground until done, blocked or budget stop |
| `/eo:status` | Task table, budgets used, escalations, links to evidence |
| `/eo:resume` | Recover after interruption and continue |
| `/eo:evidence <task>` | Show the evidence manifest and replay command |

The chat session is only a front end: each command shells out to `eo` and prints its output. The chat model does not decide outcomes.

## 11. Repository layout (target)

```
src/            controller (cli, store/, runner/, gates/, budget/, journal/, integrate/, hooks/, sandbox/)
schemas/        plan, design, report, verdict, policy JSON Schemas
policy/         default policy template (copied into the state root by `eo init`)
plugin/         Claude Code plugin: commands/, agents/, hooks/
fixtures/       disposable sample project template + scenario scripts
tests/          unit/, integration/, behavioral/
infra/          container/ and proxmox/ (M8, not built until approved)
docs/           these documents, milestone reports
```
