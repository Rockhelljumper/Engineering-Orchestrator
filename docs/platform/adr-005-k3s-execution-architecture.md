# ADR-005: K3s as the execution substrate for Proxmox staging, with the EO controller outside the cluster

| | |
|---|---|
| Status | **Accepted in direction, conditionally (owner, 2026-11-03 19:13Z, F-2). Not final: pending independent review and reconciliation sign-off.** No cluster, VM, package, registry or credential is authorized by this ADR |
| Milestone | M8, proposed sub-track M8-K0 (architecture). See `04-milestone-integration.md` |
| Relates to | `docs/02-architecture.md` §3, §7, §9; `docs/07-isolation-and-credentials.md` §3 (PX tier); threat model T6, T7, T8, T10, T11, T18; ADR-003 (Command Center gateway, on draft PR #5); ADR-008, ADR-009, ADR-010 |
| Owner direction | 2026-11-03: K3s, Headlamp, Flux CD, containerd (K3s), rootless Podman for the Phase B pilot and standalone runs, Proxmox VE, dedicated Linux VMs. These are architecture selections, not installation approvals |

## Context

- **The controller is the authority.** `eo` (`src/controller.ts`) is the single writer of the journal (`src/journal.ts`: fsynced, HMAC-chained, append-only) and of the task store (`src/store/beads.ts`, which spawns a pinned `bd` binary over a local directory). Recovery accepts only the journaled state (T10).
- **The rollback anchor is outside the state root.** In Phase B it is a separate account (`eo-anchor`) on its own disk. The controller reaches it over a systemd-owned Unix socket, and the service checks the peer uid with `SO_PEERCRED` (`services/anchor/eo_anchor.py:86`, `services/anchor/systemd/eo-anchor.socket`).
- **The gateway follows the same pattern.** The Command Center gateway design (ADR-003) uses a separate account and a peer-uid-checked Unix socket to the supervisor.
- **Workers are untrusted.** Today the only runner is `src/runner/fake.ts`, behind the `Runner` interface in `src/runner/types.ts`. The real Claude Code runner (M2-1 to M2-10) is not implemented.

Kubernetes offers scheduling, resource limits, Jobs, declarative deployment and an operations UI. It also brings a cluster-wide administrative domain (the API server, node credentials, CNI and admission). Every workload in the cluster shares that domain.

## Decision (proposed)

1. **K3s is the execution substrate for Proxmox staging only.** It does not replace the EO state machine, policy engine, budget governor, journal or recovery protocol. Kubernetes reporting that a Job succeeded is a fact about scheduling. It is never evidence that the task succeeded (ADR-009).
2. **The EO controller, the task store and the Command Center gateway run as systemd services on `eo-control`; the rollback anchor runs as a systemd service on its own VM, `eo-anchor` (owner decision F-5, ADR-010). They are not Kubernetes workloads.** Each has its own account, as in Phase B. The reasons:
   - The anchor and gateway trust model rests on `SO_PEERCRED` across accounts on one kernel. Across pods it would need a shared hostPath socket and a uid mapping that Kubernetes does not guarantee, which weakens the check.
   - The journal and Beads rely on local `fsync`, `rename` and directory-fsync semantics (`src/util/fsx.ts:32-48`) on a single writer's filesystem. A PersistentVolume adds a storage layer whose crash semantics would have to be re-proved.
   - Controller recovery must not depend on the cluster being healthy. If K3s is down, the controller must still be able to open, recover, report and refuse.
   - The controller lock decides that a holder is gone with `process.kill(pid, 0)` (`src/util/fsx.ts:98-104`, `src/util/lock.ts:141-160`). That check only means something inside one PID namespace. Two controller pods would each see the other's pid as dead and take over the lock. A restarted pod could also see an unrelated process reusing the recorded pid and refuse forever.
   - `assertPrivateDir` refuses a state root that is group-writable or not owned by the effective uid (`src/util/fsx.ts:19-26`). A pod `fsGroup` makes the kubelet chown the volume and set g+rwx on it, so the controller would refuse its own state root.
   - The journal HMAC key is a file in the state root (`src/stateRoot.ts:44,74`). On a PersistentVolume, node root, the kubelet, cluster-admin, any pod mounting the volume, and backup tooling can all read it.
3. **Kubernetes runs only what benefits from it:**
   - worker and verification Jobs on `eo-worker`, through the execution adapter (ADR-009);
   - Headlamp and Flux (ADR-006);
   - approved monitoring, once it is chosen.
4. **One K3s server on `eo-control`, tainted so no EO worker workload can schedule there, and one K3s agent on `eo-worker`.** This is a **non-HA staging cluster**. See "Availability" below.
5. **Runtimes, with no overlap:**
   - K3s's containerd runs Kubernetes pods.
   - Rootless Podman remains the runtime for the Phase B L2 pilot and any approved standalone execution path outside Kubernetes.
   - Podman never runs inside a pod. Kubernetes never schedules onto a Podman host.
   - Images are OCI and digest-pinned, so the same worker image can run under either runtime (ADR-007).
6. **Versions are not chosen in this ADR.** M8-K0 pins exact versions of K3s, the embedded components, Flux and Headlamp from their official release and support pages. It records each support window, and checks compatibility with the chosen Kubernetes minor version and the guest OS.

## Availability (stated, not implied)

A single server plus a single agent is **not highly available**:

| Failure | Effect | Recovery |
|---|---|---|
| `eo-worker` down | No Jobs run. The controller records running attempts as lost after its lease and deadline, and retries per policy (ADR-009) | Restart or rebuild the VM from its template. No state is lost, because nothing durable lives on `eo-worker` |
| K3s server down, `eo-control` up | No new Jobs. Running pods keep running but cannot be observed or cancelled through the API. The controller enters `execution-unavailable` and holds attempts | Restart K3s. Restore the K3s datastore from backup if it is corrupt. EO state is unaffected because it does not live in the cluster |
| `eo-control` down | Everything stops. Workers lose their API server | Restore `eo-control` from its backup: state roots, K3s datastore, configuration. The anchor on `eo-anchor` is not restored with it, so a restored state root older than the anchor is refused unless the operator accepts the rollback (ADR-010) |
| `eo-anchor` down | The controller cannot record or check its high-water mark, so it refuses to open or to dispatch new attempts (fail closed). Running attempts are held, not completed | Restart `eo-anchor`. Never restore it from an older image; a lost anchor is re-initialised only by an attended operator procedure (ADR-010) |
| `eo-edge` down | All outbound traffic fails closed | Restart or rebuild. Its logs are shipped off the VM (ADR-010) |

Expected downtime is the time to restart or restore one VM. HA (three servers, or an external datastore, plus several agents) is out of scope until a production milestone is defined.

## Consequences

- Kubernetes manages only worker and platform workloads. EO's own durability guarantees (M1-4, M2-0b) stay exactly as tested. No new storage layer sits under the journal.
- The controller needs a Kubernetes identity to create Jobs. It is scoped to one namespace and a fixed set of verbs (ADR-009), and is held only by the `eo` account on `eo-control`.
- The K3s server runs as root on `eo-control`, beside the controller. A K3s server compromise is a compromise of `eo-control`. This is accepted for staging only (finding G-1). Owner decision F-3: separating K3s administration from the controller must be reassessed before any non-staging environment, and four VMs are not automatically sufficient for production.

## Alternatives considered

| Alternative | Why not (now) |
|---|---|
| Controller as a Kubernetes StatefulSet with a PVC | It weakens the peer-uid trust model and the storage crash semantics, and it makes recovery depend on the cluster. It could be revisited after a storage-semantics test suite proves the journal on the chosen volume type |
| No Kubernetes; rootless Podman on `eo-worker`, driven by the controller | Simpler and closest to Phase B, but it gives up the owner-selected management stack. It stays the fallback if M8-K5 isolation acceptance fails |
| Kubernetes on the Proxmox host or in LXC | Excluded by owner direction. It would also put the hypervisor in the cluster's blast radius |
| K3s server on its own VM (`eo-k8s`) | Removes the API server from the trusted EO VM. Not in the staging target (the fourth VM is `eo-anchor`, F-5). To be reassessed before non-staging (F-3) |
