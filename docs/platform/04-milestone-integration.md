# 04 — Milestone integration and dependency-aware plan (Task E)

Updated 2026-11-03 after owner decisions F-1 to F-6.

## PX-K0..K6 mapped onto M8

"PX" is an isolation tier in `docs/07`, not a milestone series, and M8 already owns "containers in a VM, then Proxmox". The K8s work is an M8 sub-track:

| Proposed | Becomes | Content | Type | Gate |
|---|---|---|---|---|
| PX-K0 | **M8-K0** | ADR-005..010 reviewed and final; versions pinned with sources (K3s, Headlamp, Flux, Podman) | Docs | Independent review + owner sign-off (F-2) |
| PX-K1 | **M8-K1** | OCI standard applied to the worker image; one role profile → Podman args and Pod spec, with an equivalence test; isolated CI build environment and registry specified (F-6) | Code + unit tests; spec | PR review. Creating CI, registry or credentials needs separate approval |
| PX-K2 | **M8-K2** | K8s execution adapter (ADR-009) against a fake API; RBAC and admission manifests; `journal.key` move; anchor channel implementation after its design review (F-5) | Code + unit/simulated tests | PR review |
| PX-K3 | **M8-K3** | Infra repo skeleton, Flux Kustomizations, Proxmox IaC for four VMs, rendered and linted only | Code + static tests | PR review; creating the infra repo needs approval |
| PX-K4 | **M8-K4** | Create `eo-control`, `eo-worker`, `eo-edge`, `eo-anchor`; install K3s, Headlamp, Flux | Infrastructure | Owner approval (existing M8 gate) |
| PX-K5 | **M8-K5** | Isolation negative tests (G-2..G-6, G-8), escape probes | Live, destructive in sandbox | Owner approval |
| PX-K6 | **M8-K6** | First staging run through K8s Jobs: the M8-5 scenario (which is the M7 scenario), M8-6 ref restrictions and M8-7 blocker reporting | Live, spends money | Owner budget approval (M8 cap $25); needs M4–M7 |

## Dependency graph

```
Track 1 (host, attended)       Track 2 (code, no live calls)           Track 3 (platform design)
01c run by operator             V  verdict separation (PR, approved)     K0  ADR review → final
  │ evidence review               │                                      │
  ▼                               ▼                                      ├─▶ K1  image/CI/registry spec
Phase B: 02 VM → 04a →          M2-1 arg builder, role profiles          │       (needs V for role profiles)
  guest 10, 11 → 20-seal →        M2-4 env scrub, M2-8 hook canary       ├─▶ K2  adapter on fake API
  04b → 05 SSH → B9 probe          M2-6 budget/kill, M2-7 workspaces      │       (needs V: no runner verdicts)
  → verify                         │                                      │       anchor channel (needs its
  │                                ▼                                      │       design review, F-5)
  └──────────────┬──────── M2-9, M2-10 probes on the L2 VM (needs Phase B) └─▶ K3  IaC rendered only
                 ▼                                                                │
           Phase C: first live Claude call in Podman (≤ $2, owner gate)           │
                 │                                                                ▼
                 ▼                                                    K4 VMs (gate) → K5 → K6
           M3 real verifier/reviewer behind the V interfaces                  (K4, K5: Phase C + M3;
                 │                                                             K6: also M4–M7)
                 ▼
           M4 → M5 → M6 → M7 (end-to-end demo)
```

## Ordered next steps

1. **01c** (Track 1): operator runs it; independent evidence review; then a separate approval for step 02.
2. **Verdict separation** (Track 2): draft PR, owner review, merge on separate approval. Unblocks M2-1 and K2.
3. **Independent review of ADR-005..010** (Track 3): findings applied; owner marks them final.
4. **Provisioning log** in PR #4 (docs only) so the repo carries the audit trail.
5. **Phase B steps 02..verify**, each with its own approval, interleaved with M2-1..M2-8 code work (no dependency between them until M2-9/M2-10).
6. **K1, K2, K3** in parallel with step 5, once V has merged (K2 and K1 depend on its interfaces).
7. **Phase C**, then **M3**, then **M4–M7** (planning, parallel execution, chat plugin, the end-to-end demo). **K4** and **K5** can follow Phase C and M3; **K6** also needs M7, because it runs the M7 scenario.

## Phase C entry criteria

- Phase B verify passed and accepted; B9 probe report stored.
- Verdict separation merged; verdicts come only from controller-side verifier and reviewer.
- M2-1, M2-4, M2-5, M2-6, M2-8, M2-9, M2-10 passing against the Podman pilot with the fake worker.
- Live budget approved by the owner.

## Cross-PR rules (F-4)

- Each PR branches from `main` and carries only its own commits. No PR is based on another open PR.
- PR #4 gets a docs-only commit for the provisioning log; nothing else changes there.
- PR #5 stays CC0 only.
- Nothing merges without separate approval.
