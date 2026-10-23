# Engineering Orchestrator (eo)

A secure, multi-agent software-development orchestrator for Claude Code: it takes an engineering epic through architecture, planning, implementation, independent testing, security review, correction and final verification, with durable state and evidence-based quality gates.

**Status: M2 Phase A — durable test checkpointing (M2-0) and whole-state-root rollback detection (M2-0b), in review.** M1 (controller core and durable task store) was approved and merged on 2026-10-22; see the [M1 report](docs/milestones/M1-report.md). Phase A uses only the fake runner (no model spend) and installs nothing; see the [M2 Phase A report](docs/milestones/M2-phaseA-report.md). M2 Phases B and C (isolation and live workers) need their own approval.

## Try it (fake runner only)

Requires Node ≥ 22.18 (runs TypeScript directly; no npm dependencies).

```sh
export EO_STATE_ROOT=/tmp/eo-demo           # default: ~/.local/state/eo/default or %LOCALAPPDATA%\eo\default
node src/cli.ts init
node src/cli.ts policy approve-repo ~/src/sample          # interactive: type "approve"
node src/cli.ts plan import fixtures/plans/sample-epic.json --repo ~/src/sample   # interactive
node src/cli.ts run --repo ~/src/sample --runner fake --script fixtures/fake-scripts/mixed.json
node src/cli.ts status
node src/cli.ts doctor
```

The controller records its journal head in a rollback anchor outside the state root (`EO_ANCHOR_DIR`, default `~/.local/state/eo-anchor`). An older copy of the state root, or one the anchor has never seen, is refused; a person can adopt it with `node src/cli.ts anchor adopt` (add `--accept-rollback` to accept a restored backup).

Tests: `npm test` (unit), `npm run test:integration`, `npm run test:behavioral` (crash recovery and the durable runner, several minutes). Long suites can run under the durable runner, which checkpoints each scenario and resumes after an interruption: `npm run durable -- start <run dir> --suite crash-sample`, then `npm run durable -- status <run dir>`.

## Documents

| Doc | Contents |
|---|---|
| [00 Environment inspection](docs/00-environment-inspection.md) | What exists today and open questions |
| [01 Component evaluation](docs/01-component-evaluation.md) | Source review of Oh My ClaudeCode, beads, Task Master, Backlog.md; ADR-001 and ADR-002 |
| [02 Architecture](docs/02-architecture.md) | Components, roles, lifecycle, gates, resume, parallelism, execution tiers, chat workflow |
| [03 Dependency map](docs/03-dependency-map.md) | External deps and pins, component and milestone graphs, requirement traceability |
| [04 Threat model](docs/04-threat-model.md) | Assets, trust boundaries, threats, mitigations, security invariants |
| [05 Implementation plan](docs/05-implementation-plan.md) | Milestones M0–M8 with measurable acceptance criteria and approval gates |
| [06 Sample project and scenarios](docs/06-sample-project-and-scenarios.md) | Disposable test project with planted bugs, failures and injection attempts |
| [07 Isolation, credentials and spend limits](docs/07-isolation-and-credentials.md) | Windows user vs WSL2 vs containers vs VMs, GitHub ref restrictions, what budget flags guarantee |
| [M0 report](docs/milestones/M0-report.md) | M0 acceptance results and review findings |
| [M1 report](docs/milestones/M1-report.md) | M1 acceptance results, evidence and review findings |
| [M2 Phase A report](docs/milestones/M2-phaseA-report.md) | M2-0 and M2-0b acceptance results, evidence and review findings |

## Decisions approved with M0 revision 2

1. **ADR-001:** don't install Oh My ClaudeCode; adapt its agent prompts and guardrail ideas into our own plugin.
2. **ADR-002:** use beads (built from a pinned, reviewed commit, metrics disabled, controller-only writer) as the task store, with Backlog.md as fallback.
3. Controller in TypeScript on Node 22. `ajv` was the one planned runtime dependency; M1 uses a small built-in validator instead, because installing packages was not authorised (see the M1 report).
4. Agent-written code (workers and test runs) executes in a hardened container or a VM, with a local VM preferred. A separate low-privilege Windows user is only for a supervised pilot on the sample project. WSL2 alone is not counted as isolation.
5. Approval gates and proposed live-spend caps in the implementation plan.
