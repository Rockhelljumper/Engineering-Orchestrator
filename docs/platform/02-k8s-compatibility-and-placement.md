# 02 — Kubernetes compatibility and placement matrix (Task B)

Six classes:
1. **Host systemd service** on `eo-control`, or on `eo-anchor` for the anchor (never a pod).
2. **K8s platform workload** (cluster-managed, long-running).
3. **K8s Job** (per-attempt, ephemeral).
4. **Podman rootless container** (pilot and standalone).
5. **Edge VM service** (`eo-edge`, outside the cluster).
6. **Operator-only / out of cluster** (console, workstation, Proxmox host).

| Component | Class | Why | Stateful | Privilege | Network in / out | Secrets it holds | Recovery |
|---|---|---|---|---|---|---|---|
| Controller (`eo` CLI / daemon) | 1 | PID-based lock, `assertPrivateDir`, fsync semantics, must recover without the cluster | Yes (state root) | Unprivileged `eo` uid | In: Unix sockets only. Out: K8s API (namespace SA), proxy | `journal.key` (moved per ADR-010), K8s SA token, staging deploy key | Restart; journal replay; anchor check |
| Rollback anchor | 1, on its own VM `eo-anchor` (F-5) | SO_PEERCRED locally, mutually authenticated channel to `eo-control` (ADR-010 §1a), must survive cluster loss and root on `eo-control` | Yes (high-water mark) | `eo-anchor` uid; no network | None | Admin socket root-only | Refuses rollback unless `--accept-rollback` |
| Beads store (`bd`, Dolt) | 1 (library of the controller) | Spawned by controller; same state root | Yes | `eo` uid | None | None | With state root |
| Evidence writer | 1 (part of controller) | HMAC with journal key | Yes | `eo` uid | Out: log shipper | Uses journal key | Append-only copy off-VM (ADR-010) |
| Budget governor | 1 (in-process) | Must reserve before dispatch | In journal | — | — | — | Journal replay |
| Command Center gateway | 1 | ADR-003: own account `eo-gateway`, SSH tunnel, WebAuthn; no K8s credentials | SQLite projection (rebuildable) | `eo-gateway` uid | In: SSH -L only | WebAuthn credential store | Rebuild projection from journal |
| Artifact receiver | 1 | Single-use tokens tied to controller state | Content-addressed blobs | `eo` uid | In: from `eo-exec` pods only, one port | Token verification key | Re-request artifacts from orphaned attempts = fail attempt |
| K3s server (API, scheduler, datastore) | 1 (K3s runs as a systemd unit) | Selected by owner; tainted, no workloads | Yes (datastore) | root | In: 6443 from worker node, 10250 out to worker | Cluster CA, admin kubeconfig | Datastore backup; rebuild cluster; EO state unaffected |
| K3s agent / kubelet / containerd | 1 on `eo-worker` | Node components | No | root on worker VM | Out: 6443 to control, overlay | Node credential (NodeRestriction) | Rebuild VM from template |
| Implementer worker | 3 (staging) / 4 (pilot) | Per-attempt, untrusted code execution | No (emptyDir workspace) | Non-root uid 10001, caps dropped, RO rootfs | Out: proxy only; In: none | Per-attempt credential (ADR-010 §4) | Job failed → controller decides retry |
| Verifier runner (tests in the target repo) | 3 / 4 | Runs untrusted repo code | No | As worker | Out: none by default | None | As worker |
| Reviewer worker | 3 / 4 | Read-only tools (M2-2) | No | As worker, no write mount | Out: proxy | Per-attempt credential | As worker |
| Headlamp | 2 | Owner-selected UI | No | Read-only SA | In: SSH -L only | Read-only token | Redeploy |
| Flux controllers | 2 | Owner-selected GitOps | Git cache | Impersonated per-Kustomization SAs | Out: infra repo only via proxy | Repo read key | Re-reconcile |
| Admission policy (VAP/PSA) | 2 | Backstop for ADR-007 | No | Cluster-scoped | — | — | Flux re-apply |
| Monitoring (metrics, node exporter) | 2 | Optional | Small | Read-only | In: scrape from control | None | Redeploy |
| Egress proxy (CONNECT allowlist) | 5 | Must be outside both guests' trust | Logs | Unprivileged | In: 3128 from control and worker. Out: allowlisted hosts | None (unless credential injection, ADR-010 §4) | Rebuild from config |
| Evidence / audit log store | 6, external (F-6) | Must survive compromise of every EO VM and of Proxmox admin | Yes, append-only, hash-chained | Ingest-only | In: log shipping | Ingest credentials (not provisioned) | Retention policy |
| OCI registry | 6, external or separately administered (F-6) | Image integrity must not depend on EO VMs | Yes, immutable digests | Pull-only from EO VMs | Out from VMs via proxy | Pull credential only (not provisioned) | Re-push from CI provenance |
| Image build (CI) | 6, isolated CI (F-6) | Builds run untrusted dependency code; not on `eo-control` | No | Isolated runner | Out: dependency mirrors | Registry push credential, CI only | Rebuild; reproducibility check |
| Proxmox host, IaC, cluster-admin use | 6 | Admin plane | — | Operator | Management VLAN | Proxmox token (operator only) | Runbooks |
| Hyper-V L2 VM (Phase B) | 6 → hosts class 1 and 4 | Existing pilot | — | — | — | — | Existing undo scripts |

## OCI requirements

Every class 3 and 4 image follows ADR-007. The same role profile generates both the Podman run arguments and the Pod spec, and a unit test asserts the two are equivalent (uid, caps, rootfs, mounts, env allowlist, resources, network). Class 2 images are pinned by digest and pass the same admission policy, but may need exceptions (Flux needs a writable cache), and each exception is listed in the infra repo.

## Not compatible as-is

- Controller as a pod: needs lock redesign (lease-based), a fsGroup-compatible privacy check, and proven fsync on the PV. Not recommended (ADR-005).
- Anchor as a pod: SO_PEERCRED across pods is not meaningful. Not recommended.
- Podman inside pods: rejected (needs privilege or nested user namespaces).
