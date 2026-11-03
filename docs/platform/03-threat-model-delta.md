# 03 — Threat-model delta for the K3s / Proxmox topology (Task C)

Base: `docs/04-threat-model.md` T1–T25 (on `claude/m2-phase-b`). New threats start at T26. "Blocking" means it must be closed before the named milestone; nothing here blocks Phase B or Phase C, which run on the Hyper-V L2 VM with Podman.

## New threats

| ID | Threat | Mitigation (where) | Blocks |
|---|---|---|---|
| T26 | **Worker-node escape to the API server.** A container escape on `eo-worker` gets the kubelet's node credential and uses the API on `eo-control` to read Secrets, create pods or reach the controller | NodeRestriction and Node authorizer; no Secrets beyond the running attempt's; no SA tokens in worker pods; API audit log off-VM; 4-VM option (ADR-008) | M8-K5 |
| T27 | **Anchor reachable from a compromised `eo-control` root** (K3s server is root on the same VM) | Decided (F-5): Option B, independent `eo-anchor` VM, for staging; Option C, external witness, before non-staging | M8-K4 (B), non-staging (C) |
| T28 | **GitOps path as a change channel.** A write to the infra repo, or a compromised Flux, changes policy, RBAC or images without human review | Human-merge-only infra repo with branch protection; signed commits; per-Kustomization impersonation; cluster-scoped objects promotion-gated; EO has no write access to the infra repo (ADR-006) | M8-K3 |
| T29 | **Headlamp / kubeconfig as a browser credential.** A token with write rights, or `exec`/`port-forward`, leaks through the browser | Read-only identity, SSH -L only, no Secrets, admin through console kubectl only (ADR-006) | M8-K4 |
| T30 | **Job success read as task success.** Controller trusts pod exit code or a worker-written result | Job status only means the attempt ran; verdicts come from the controller-side verifier (ADR-009, RunResult split) | Any real runner (M2) |
| T31 | **Stale or duplicate Job.** A retried create, a lost watch or a controller restart runs an attempt twice or adopts the wrong Job | Deterministic names, spec hash, attempt epoch, reconcile before retry, orphan deletion (ADR-009) | M8-K2 |
| T32 | **Per-attempt credential outlives the attempt** (Secret left in `eo-exec`, or readable by sibling pods) | Owner-referenced Secret, deleted on finish, reconciler sweep; or proxy-side injection (ADR-010 §4) | Real model calls in K8s |
| T33 | **Image substitution.** A tag or registry change runs an unreviewed image | Digest-only references; admission policy rejects non-digest; provenance/SBOM checks; external registry, builds in isolated CI, no push credential on EO VMs (ADR-007, F-6) | M8-K2 |
| T34 | **Anchor channel attack.** Spoofed anchor, replayed reply, stolen client key on `eo-control`, or a channel outage used to make the controller run unanchored | mTLS with pinned keys from an offline CA; MACed replies bound to request; CAS + idempotent `requestId`; fail closed on outage (ADR-010 §1a). A stolen client key can only advance the head, which the journal must then match | Implementation of the channel (M8-K2) |
| T35 | **Build environment compromise.** The CI that builds images injects code | Isolated CI; two-build reproducibility; provenance verified at admission (ADR-007) | M8-K1 |

## Gap analysis for the four-VM staging target (G-1..G-12, referenced by ADR-005 and ADR-008)

| ID | Gap | Blocking for | Closure |
|---|---|---|---|
| G-1 | K3s server (root) is colocated with the controller on `eo-control`; a server compromise is a controller compromise | Non-staging | Accepted for staging. Reassess separating K3s administration from the controller before non-staging (F-3) |
| G-2 | Kubelet node credential gives `eo-worker` an API path (T26) | M8-K5 | NodeRestriction + negative tests |
| G-3 | Flannel does not enforce NetworkPolicy; K3s embedded netpol controller must actually be enforcing | M8-K5 | Negative tests: pod-to-pod, pod-to-control, pod-to-internet all denied except proxy |
| G-4 | CoreDNS could be an external DNS channel | M8-K5 | `dnsPolicy: None` for worker pods; CoreDNS forwards cluster names only; DNS exfil negative test |
| G-5 | IPv6 left on in any guest or on the bridge bypasses IPv4 rules | M8-K4 | IPv6 off in guests and Proxmox firewall; test |
| G-6 | Overlay traffic unencrypted between VMs | M8-K4 | Encrypted overlay (WireGuard backend) or accept on an isolated bridge |
| G-7 | CONNECT/SNI allowlist gives host-level control only; no path, repo or content control | Accepted limit | Documented; ref restrictions enforced by GitHub (M8-6) |
| G-8 | hostNetwork, hostPath, NodePort, LoadBalancer could bypass policy | M8-K2 | Admission policy denies them in `eo-exec` |
| G-9 | API audit logs and proxy logs live inside the compromise boundary | M8-K4 | External, tamper-evident store (F-6, ADR-010 §3) |
| G-10 | `journal.key` in the state root travels with backups | Before staging runs with evidence | Move key (ADR-010 §2) |
| G-11 | Proxmox admin can roll back both `eo-control` and `eo-anchor` | Non-staging | External witness (F-5, ADR-010 Option C) |
| G-12 | Single server + single agent is non-HA; cluster loss stops execution | Accepted for staging | EO state is outside the cluster, so loss pauses, never corrupts; availability table in ADR-005 |

**Conclusion.** The four-VM target (F-3) is enough for staging if G-2..G-6 and G-8..G-10 are closed and G-1, G-7, G-11, G-12 are recorded as accepted staging risks. It is not enough for production: that needs the external witness (G-11) and a reassessment of K3s administration separation (G-1), and four VMs are not assumed sufficient even then.

## Remaining security blockers by stage

| Stage | Blockers |
|---|---|
| 01c execution (now) | None open in code; residual run risks are fail-safe (host churn, settle timeout) |
| Phase C (first live call, Podman) | Verdict separation merged (T5, T30); M2-1, M2-4, M2-5, M2-8, M2-9, M2-10 |
| M8-K4 (create VMs) | Anchor channel design reviewed (T34); external evidence store chosen (G-9); registry and CI build environment chosen (T33, T35); `journal.key` moved (G-10) |
| M8-K6 (first staging run) | G-2..G-6, G-8 negative tests passing (M8-K5); per-attempt credential decision (T32) |
| Non-staging | External witness (G-11); K3s administration separation reassessed (G-1) |

## Existing threats whose mitigation changes

| Threat | Change |
|---|---|
| T6, T23, T24 | WSL2 and Docker Desktop are out of the picture on Proxmox; the boundary is the VM plus pod security |
| T7 | Adds K8s Secrets and SA tokens as exposure surfaces (T32) |
| T8 | Egress moves to `eo-edge`; adds DNS and IPv6 paths (G-4, G-5) |
| T10 | Anchor placement per ADR-010; backup restore always goes through the anchor |
| T5 | Restated as T30 for Job status |
