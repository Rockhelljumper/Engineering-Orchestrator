# 01 — Component evaluation

All candidates were cloned into an isolated scratch directory and **read only**. No install script, build, `postinstall`, binary or hook was executed. Repository instruction files (`CLAUDE.md`, `AGENTS.md`, READMEs) were treated as untrusted data. Line references are to the commits below.

| Project | Commit reviewed | Version | License |
|---|---|---|---|
| Oh My ClaudeCode (`Yeachan-Heo/oh-my-claudecode`) | `6688a30e90d7285ff336af2dc5ab4b9709f1a8bc` (2026-10-18) | v5.7.5 | MIT |
| beads (`steveyegge/beads`, now `gastownhall/beads`) | `9c6f6e15cdfdc4478e634520e8320795914e68e5` (2026-10-18) | 1.3.0 | MIT |
| Task Master (`eyaltoledano/claude-task-master`) | `c0c98d367c55296bfe69e65680625b6db437af02` (2026-04-23) | 0.43.1 | MIT with "Commons Clause" condition (no selling) |
| Backlog.md (`MrLesk/Backlog.md`) | `75e9e972416bff53f54ea93f4b32d7252389c026` (2026-10-18) | v1.54.0 | MIT |

Key findings were spot-checked by hand after the first pass (marked ✔).

## 1. Oh My ClaudeCode (OMC)

### What it offers
- 19 agent definitions in `agents/` that map well to the required roles: `architect`, `planner` (+ `analyst`, `critic`), `executor`, `test-engineer`, `qa-tester`, `security-reviewer`, `code-reviewer`, `verifier`, `debugger`, `git-master`.
- Modes: `autopilot` (spec → plan → parallel execution → QA up to 5 cycles → validation), `ralph` (loop until all PRD stories pass with architect verification), `team` (multiple CLI workers in tmux panes).
- File-based state in `.omc/state/**.json`, saved on `PreCompact` and restored on `SessionStart`.
- Useful ideas: PRD/acceptance-criteria flow, `git-guardrails` hook (blocks push, `reset --hard`, `clean -f`, …), a narrow `PermissionRequest` auto-allow list that rejects shell metacharacters.

### Findings that block adopting it as-is
| # | Finding | Evidence |
|---|---|---|
| O1 | Team workers are always launched with `--dangerously-skip-permissions` (Claude), `--dangerously-bypass-approvals-and-sandbox` (Codex), `--approval-mode yolo` (Gemini). ✔ | `src/team/model-contract.ts:192` |
| O2 | Ralph's iteration cap silently extends itself: on reaching `max_iterations` it adds 10, so only cancellation or the hard cap stops it. Hard cap defaults to 500 (200 in strict mode). ✔ | `src/hooks/persistent-mode/index.ts:1506-1509`, `src/lib/security-config.ts:38-56` |
| O3 | Token budget is opt-in and only logs (“shadow”) unless `OMC_BUDGET_ENFORCE=active`. ✔ | `scripts/budget-guard.mjs:7-15` |
| O4 | ~25 hooks per session execute a **committed prebuilt `dist/`** (5,593 files, ~50 MB, despite `dist/` being in `.gitignore`) and ~11 MB of minified bundles in `bridge/`. The code that runs is not the `src/` that can be audited without a reproducible rebuild. ✔ | `git ls-files dist \| wc -l` = 5593 |
| O5 | “Read-only” agents only disallow `Write, Edit`; they keep `Bash`, so they can still modify files. | `agents/*.md` frontmatter |
| O6 | `SessionStart` contacts `registry.npmjs.org`; an auto-update path runs `npm install -g …@latest` (off by default via `silentAutoUpdate=false`, but `disableAutoUpdate` defaults to false). | `scripts/session-start.mjs:1253-1303`, `src/features/auto-update.ts:252-320` |
| O7 | HUD reads Claude OAuth credentials (`~/.claude/.credentials.json` / Keychain), calls the usage API and writes refreshed tokens back. | `src/hud/usage-api.ts` |
| O8 | Setup writes hooks/statusLine into `~/.claude/settings.json`; the `omc-setup` skill overwrites `~/.claude/CLAUDE.md` by default. Repo `CLAUDE.md:25` tells the model direct writes to `~/.claude/**` are OK. | `src/installer/index.ts:2787-2851`, `skills/omc-setup/SKILL.md:65` |
| O9 | A `UserPromptSubmit` keyword detector auto-activates autonomous modes on words like “ralph”, “autopilot”, “build me an app”. | `src/hooks/keyword-detector/index.ts:46-47` |
| O10 | Remote MCPs (Context7, Exa) enabled by default. | `src/config/loader.ts:80` |
| O11 | Worktree isolation for team mode defaults to **disabled**; no OS sandbox. ✔ | `src/team/git-worktree.ts:441-447` |
| O12 | Team mode depends on tmux, which is not native on the user's Windows PC. | `src/team/tmux-session.ts` |

No analytics/telemetry SDK (PostHog, Sentry) was found. No `curl | bash` installer exists; the npm `postinstall` only builds a native addon on macOS.

### Decision (ADR-001)
**Do not install OMC as a plugin. Adapt selected parts into our own small plugin, with attribution (MIT).**

Reuse: the agent role prompts (rewritten so reviewers are genuinely read-only), the PRD/acceptance-criteria structure, the git-guardrail command list, the narrow permission auto-allow pattern, and the PreCompact/SessionStart state-restore idea.

Do not reuse: team mode, `--madmax/--yolo`, persistent-mode stop loops, auto-update, the HUD, keyword auto-activation, remote MCP defaults, notification webhooks, global-config writes.

Rationale: requirements 6 and 8 (protected gates, bounded retries, enforced budgets) are exactly where OMC's defaults are weakest (O1–O3), and requirement “do not execute downloaded scripts without inspecting them” cannot be met for ~60 MB of prebuilt bundles that would run on every hook (O4). Revisit if OMC ships reproducible builds and a permission-respecting team mode.

## 2. Durable task tracking

### Requirements used for the comparison
Dependencies and a ready queue; atomic claim/lease so two workers never take the same task; recovery of tasks held by dead workers; notes/evidence; survives restarts; offline; no LLM key; usable as a CLI from Node on Windows and Linux.

| Capability | beads 1.3.0 | Backlog.md 1.54.0 | Task Master 0.43.1 |
|---|---|---|---|
| Storage | Dolt (embedded or `dolt sql-server`) | One markdown file per task (YAML frontmatter) | One `tasks.json` |
| Dependencies | blocks, parent-child, waits-for, conditional, related, discovered-from | `dependencies[]` with cycle checks | `dependencies[]` |
| Ready queue | `bd ready` (excludes in_progress/blocked) | `task list --ready` (includes In Progress; caller must filter) | `next` (treats in-progress as eligible) |
| Atomic claim | Yes: CAS claim; `bd ready --claim` inside the ready-query transaction | No (last write wins on `assignee`) | No |
| Lease / heartbeat / reclaim | Yes: 5-min lease ✔, `bd heartbeat`, `bd reclaim` | No | No |
| Concurrent writers | Embedded mode: single writer via exclusive flock; server mode for many | Per-task file lock, fails fast | Lock exists but lost-update race (`file-storage.ts:456` vs `:245-256`) |
| Network by default | **Usage metrics ON** to `gastownhall-eventsapi.com` ✔ (opt out `BD_DISABLE_METRICS=1` / `DO_NOT_TRACK=1`) | `git fetch --prune` when `remoteOperations: true` (default) | **Sentry ON with `sendDefaultPii` and prompt/output recording**; auto-`npm install -g` before commands |
| Global side effects | `bd init` writes AGENTS.md, agent hooks, git hooks unless `--stealth/--skip-agents/--skip-hooks`; writes user-global metrics config | `init` may write CLAUDE.md/AGENTS.md | Appends aliases to `~/.zshrc`/`~/.bashrc` |
| Needs LLM key | Only for optional AI compaction/dedupe | No | Yes for parse/expand/update-subtask |
| Install | `curl\|bash` script with SHA256 check and optional `sudo mv`; npm postinstall downloads a binary; or `go build` | npm optional deps with prebuilt binaries | npm |
| Activity | Very high (~50 commits in 5 days), large test suite, active storage migrations | Active, 278 test files | Last commit 2026-04-23; README points to a commercial product |

Task Master is rejected (no claim, write race, content-bearing telemetry on by default, global self-update, LLM dependency).

### Decision (ADR-002)
**Use beads as the task graph store, behind a `TaskStore` adapter, with these conditions:**

1. Build `bd` from source at a pinned commit with `go build` (no `curl | bash`, no npm postinstall download), using a pinned Go 1.26.7 toolchain with `GOTOOLCHAIN=local` (beads' `go.mod` requires `go 1.26.5`/`toolchain go1.26.7`; the default `auto` would silently download a toolchain), and with module downloads verified against `go.sum`. Record the binary SHA-256 in `deps.lock.json`.
2. Always run with `BD_DISABLE_METRICS=1` and `DO_NOT_TRACK=1`, set by the controller; a test asserts no outbound connection during a full scenario run (milestone M1).
3. Initialise with `bd init --stealth --skip-agents --skip-hooks`; the orchestrator owns all hooks.
4. **Only the controller process writes to beads.** Workers never receive `bd` access. This keeps embedded single-writer mode sufficient (no `dolt sql-server` needed for the MVP) and is a security property in its own right: an agent cannot mark its own task done.
5. Pin the adapter to a narrow command subset (`create`, `dep add`, `ready --claim`, `heartbeat`, `reclaim`, `update`, `note`, `close`, `show --json`, `list --json`) and run a contract test suite against it, so beads API churn is caught on upgrade.

**Fallback:** if beads fails to build on Windows (CGO/Dolt) or the contract tests are unstable, switch the adapter to Backlog.md with claim/lease implemented in the controller (safe because the controller is the only writer). The adapter interface is designed so this swap does not touch the rest of the system. This decision is re-confirmed with evidence at the end of M1.

## 3. Claude Code itself

Claude Code 2.1.302 already provides the primitives the worker runner needs, so no third-party agent runtime is required:
- `claude -p --output-format json` returns structured results including cost/usage.
- `--json-schema` forces structured agent output (used for plans, verdicts, reports).
- `--tools` / `--allowedTools` / `--disallowedTools` give real per-role tool sets (a reviewer can be given no `Bash`, `Write` or `Edit` at all).
- `--permission-mode dontAsk` + `--permission-prompts none` lets unattended workers fail closed instead of prompting or bypassing.
- `--setting-sources`, `--restricted` and `--strict-mcp-config` stop a target repository's own `.claude/` settings, hooks and MCP servers from loading into a worker. None of these stops the repository's `CLAUDE.md` being read; only `--bare` skips CLAUDE.md discovery, at the cost of also skipping settings hooks and requiring API-key auth. M2 measures each option and records the choice.
- `--restricted` also refuses code-running tools unless named, which suits the read-only reviewer roles.
- `--max-budget-usd` stops an invocation once its estimated cost passes the cap (it can overshoot; `07` §5).
- `--session-id` / `--resume` allow an interrupted attempt to be continued or audited.

These are confirmed present in `--help`; exact behaviour is verified by tests in M2 rather than assumed.
