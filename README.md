# Engineering Orchestrator (eo)

A secure, multi-agent software-development orchestrator for Claude Code: it takes an engineering epic through architecture, planning, implementation, independent testing, security review, correction and final verification, with durable state and evidence-based quality gates.

**Status: M0 — architecture and planning, awaiting review.** Nothing has been installed or built yet.

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
| [M0 report](docs/milestones/M0-report.md) | Acceptance results for this milestone and the independent review findings |

## Decisions needing approval

1. **ADR-001:** don't install Oh My ClaudeCode; adapt its agent prompts and guardrail ideas into our own plugin.
2. **ADR-002:** use beads (built from a pinned, reviewed commit, metrics disabled, controller-only writer) as the task store, with Backlog.md as fallback.
3. Controller in TypeScript on Node 22, with `ajv` as the only planned runtime npm dependency.
4. Agent-written code (workers and test runs) executes as a separate low-privilege principal: a dedicated local Windows user, WSL2 or a container. Without one, only the sample project may be used.
5. Approval gates and proposed live-spend caps in the implementation plan.
