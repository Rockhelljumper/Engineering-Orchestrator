# Kubernetes-ready architecture package (proposed)

Prepared 2026-11-03 for the Engineering Orchestrator continuation directive. The owner's decisions F-1 to F-6 (2026-11-03 19:13Z) are recorded below. The ADRs are **accepted in direction, conditionally**, and are not final until the independent review is resolved. Nothing here installs, provisions or runs anything.

## Index

| File | Deliverable |
|---|---|
| `01-current-state.md` | Task A: verified repo, PR, CI, host and milestone state |
| `02-k8s-compatibility-and-placement.md` | Task B: every component in one of six classes, with attributes; OCI requirements |
| `03-threat-model-delta.md` | Task C: T26–T35, gaps G-1..G-12, remaining blockers by stage |
| `04-milestone-integration.md` | Task E: PX-K0..K6 → M8-K0..K6, dependency graph, ordered next steps, Phase C criteria |
| `05-test-matrix.md` | Task F: 33 tests, each typed |
| `adr-005-k3s-execution-architecture.md` | K3s for worker Jobs only; controller, anchor, store and gateway stay systemd |
| `adr-006-headlamp-flux-management.md` | Headlamp read-only over SSH -L; Flux on a human-merge-only infra repo |
| `adr-007-oci-image-standard.md` | Image standard shared by Podman and K3s |
| `adr-008-proxmox-staging-topology.md` | Four VMs: eo-control / eo-worker / eo-edge / eo-anchor; firewall, storage, backup |
| `adr-009-k8s-execution-adapter-contract.md` | `k8s-job` Runner contract, idempotency, reconciliation, RBAC, negative tests |
| `adr-010-security-boundary-and-anchor-placement.md` | Anchor on its own VM, anchor channel design and failure semantics, journal key, external evidence, credentials, admin access |

ADR numbers continue from ADR-004 (PR #5). Threat IDs continue from T25.

## Owner decisions (2026-11-03 19:13Z)

| ID | Decision |
|---|---|
| F-1 | GO for 01c. Re-pin RH-DT-M3 to `72da82786081e4bf62202403a6c41f3b4acc2896`, verify, and hand the attended elevated run to the operator, who types `filter-guard` himself. Stop after execution for independent evidence review. Step 02 does not begin |
| F-2 | ADR-005 to ADR-010 accepted conditionally: direction accepted; reconcile with F-3 to F-6, then independent review; not final before review |
| F-3 | Four-VM staging target: eo-control, eo-worker, eo-edge, independent eo-anchor. Not automatically sufficient for production; reassess separating K3s administration from the controller for non-staging |
| F-4 | Branches: `claude/m8-k0-platform-design` (new draft PR), `claude/m2-verdict-separation` (separate draft PR), provisioning log as a docs-only commit in PR #4, PR #5 stays CC0. No merges without separate approval; clean ancestry, no cross-PR dependencies |
| F-5 | Anchor: Option B (independent VM) for staging; Option C (external witness outside the Proxmox administrative trust domain) before non-staging. Design the authenticated channel and its failure/recovery semantics before implementation |
| F-6 | Externally retained, tamper-evident audit evidence. External or separately administered OCI registry; immutable digest-pinned images. Isolated CI image builds, not routine builds on eo-control. No new credentials or infrastructure yet |

## Repository changes

| # | Files | Purpose | Tests | Rollback | Status |
|---|---|---|---|---|---|
| R-1 | `docs/platform/*` (this package) | Record the K8s platform design | Docs only | Revert the commit or close the PR | Approved (F-4): branch `claude/m8-k0-platform-design`, draft PR, from `main` |
| R-2 | Threat IDs T26–T35 and the M8-K0..K6 sub-track | Fold into `docs/04-threat-model.md` and `docs/05-implementation-plan.md` | Docs only | Revert | Deferred until the ADRs are final, to keep R-1 reviewable on its own |
| R-3 | `docs/milestones/M2-phaseB-provisioning-log.md` | Provisioning log in the repo | Docs only | Revert | Approved (F-4): docs-only commit in PR #4 |
| R-4 | Runner types, controller, fake verifier/reviewer, tests | Verdict separation | Unit, integration, behavioural | Revert PR | Approved (F-4): branch `claude/m2-verdict-separation`, draft PR, from `main` |

No changes to infra scripts, host state, other repositories, CI or security policy. Nothing merges without separate approval.
