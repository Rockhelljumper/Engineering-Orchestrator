# ADR-010: Security boundary, anchor placement and evidence retention for the K3s topology

| Field | Value |
|---|---|
| Status | **Accepted in direction, conditionally (owner, 2026-11-03 19:13Z, F-2, F-5, F-6). Not final: pending independent review.** The anchor channel below is a design; implementing it needs the design reviewed first (F-5) |
| Date | 2026-11-03 |
| Relates to | ADR-005, ADR-006, ADR-008, ADR-009; threat model T6, T7, T10, T13, T16, T19; invariants on the anchor and journal; `03-threat-model-delta.md` |

## Context

On the two-VM Phase B design, the rollback anchor (`services/anchor/eo_anchor.py`) runs on the same VM as the controller but under its own account (`eo-anchor`). It sits on its own LV (`/srv/eo-anchor`), which is never snapshotted (`infra/l2/guest/11-storage.sh`). The anchor detects rollback of a state root (T10) because it holds a monotonic high-water mark the controller cannot rewrite.

The K3s topology adds a root-level K3s server to `eo-control` (ADR-005). That changes what "separate account on the same VM" protects against:
- Any root compromise of `eo-control` gets root over the anchor too. This includes a K3s API-server or containerd escape on the server, which runs as root.
- A separate Proxmox disk with `backup=0` keeps the anchor out of backups. It does not stop someone with Proxmox admin rights from snapshotting, copying or rolling back that disk.
- The journal HMAC key is the file `journal.key` in the state root (`src/stateRoot.ts:44,74`). Whoever can read the state root can forge journal entries.

## Decision

### 1. Anchor placement (owner decision F-5)

| Option | What it is | Protects against | Does not protect against | Decision |
|---|---|---|---|---|
| A. As in Phase B | `eo-anchor` account and LV on the controller VM | Controller-uid compromise; restoring a state-root backup | Root on the controller VM (including a K3s server escape); Proxmox admin | Phase B (Hyper-V L2) only |
| B. Independent VM `eo-anchor` | Anchor on its own minimal VM, reached over the authenticated channel below | Root on `eo-control`, a K3s compromise, a worker escape | Proxmox admin rolling back both VMs together | **Staging** |
| C. External witness | The anchor's high-water mark is also countersigned by a witness outside the Proxmox administrative trust domain | Proxmox admin rollback of both VMs | Compromise of the witness itself | **Required before non-staging** |

The anchor stays a systemd service, never a pod. On `eo-anchor` the existing service keeps its local Unix socket and SO_PEERCRED check; a small channel daemon on the same VM is its only local client. The channel replaces SO_PEERCRED for the cross-VM hop.

### 1a. Anchor channel design (to be reviewed before implementation)

**Peers and identity.**
- Client: the controller on `eo-control`, as the `eo` uid, through the existing `src/anchorService.ts` seam with a new transport.
- Server: the channel daemon on `eo-anchor`, which forwards to the local anchor socket.
- Mutual TLS 1.3 over TCP 7443 on the dedicated link. Each side has a key generated on its own VM and never exported; certificates are pinned by SPKI hash, issued by an offline operator CA, and enrolled at the console. No shared secrets, no CA on any guest that can sign.
- The Proxmox firewall pins the link (ADR-008). TLS identity is still required; the firewall is not the authentication.

**Message protocol.**
- Requests: `head.get(stateRootId)`, `head.advance(stateRootId, seq, journalMac, prevSeq, requestId)`.
- `head.advance` is accepted only if `prevSeq` equals the stored seq and `seq > prevSeq` (compare-and-swap, monotonic). The stored record is `(stateRootId, seq, journalMac, anchorSeq, anchorMac)`, fsynced before the reply.
- `requestId` makes advances idempotent: a repeated advance with the same `requestId` and the same values returns the original reply; with different values it is refused and logged.
- Every reply is MACed by the anchor's key over the request and the stored record, so a reply cannot be replayed onto another request.

**Failure semantics (fail closed).**

| Situation | Controller behaviour | Recovery |
|---|---|---|
| Channel down or timeout on `head.advance` | The journal append is already durable; the controller stops dispatching new attempts and retries the advance with the same `requestId`. It does not report the transition as done to Command Center | Retry succeeds, or the operator investigates. Crash in this window recovers as the existing M2-0b "crash between journal append and checkpoint" case |
| Channel down on open | Controller refuses to open (as today when the anchor is unreachable) | Restore the channel |
| `head.advance` refused: stored seq ahead of the journal | Rollback detected (T10). Controller refuses with a forensic record | Attended `eo anchor --accept-rollback` only |
| `head.advance` refused: stored seq behind `prevSeq` | Anchor rollback suspected (G-11) | Stop; attended investigation; never auto-repair |
| Certificate or pin mismatch | Refuse; log to the external evidence store | Attended re-enrolment |
| `eo-anchor` disk lost | Controller refuses to open | Attended re-initialisation: operator verifies the journal head against the external evidence log (and the witness, once C exists), then sets the anchor to that head at the console. Never automatic |

**Tests before it is used:** unit tests of the CAS and idempotency rules; simulated tests with a fake transport (drop, delay, duplicate, reorder, crash at each step); a negative test that `eo-worker` and `eo-edge` cannot connect. Live tests wait for M8-K4.

**Option C** reuses the same record: each `anchorSeq` change is countersigned by the witness, and the controller requires a witness receipt no older than a configured lag. Its design is a separate item before non-staging.

### 2. Journal key placement

- `journal.key` stays out of any Kubernetes object, PV or Secret.
- On `eo-control` it moves from the state root to a root-owned key path readable only by the controller uid. A backup of the state root then does not contain the key that authenticates it. This is a code change in `stateRoot.ts`; it needs a migration test and is listed for M8-K2.
- A TPM- or vTPM-sealed key is the longer-term option. It is not required for staging.

### 3. Evidence and log retention outside the compromise boundary (owner decision F-6)

The evidence manifest is HMAC'd (`src/evidence.ts`), so tampering is detectable. A root attacker on `eo-control` could still delete the evidence or the key. For staging, these are shipped append-only to a store outside both `eo-worker` and `eo-control`:
- K8s API-server audit log (policy: metadata for all, request bodies for Jobs, Secrets and RBAC objects);
- `eo-edge` proxy access logs (CONNECT host, SNI, bytes, decision);
- anchor high-water-mark changes;
- controller journal checkpoints (hash chain head plus seq).

The store is **external and tamper-evident** (F-6): outside every EO VM and outside the Proxmox administrative domain, append-only from the shippers' side, with each batch hash-chained and the chain head recorded with the controller's evidence. `eo-edge` may buffer logs, but is not the retained copy. The store, its credentials and its retention policy are not provisioned yet.

### 4. Per-attempt worker credentials

- Model API credentials are never in images, never in a long-lived Secret readable from `eo-exec`, and never in a node-wide location.
- The controller issues per-attempt credentials. A Secret is created in `eo-exec` with the attempt's deterministic name and an owner reference to the Job. It is deleted when the attempt finishes, and the controller's reconciler deletes any left over (ADR-009).
- Where the provider supports it, the credential is scoped and short-lived. Where it does not (a long-lived API key), the proxy on `eo-edge` injects it into the request instead, and the worker never holds it. This needs TLS interception on the proxy for that one host, which is a separate decision. Until it is decided, real model calls stay out of K8s (they are already out of scope until Phase C).

### 5. Proxmox management isolation

- The Proxmox web UI and API listen only on a management VLAN that no EO guest can route to (ADR-008 firewall rules).
- No EO component holds a Proxmox API token. IaC (M8-K3) runs from an operator workstation, with the token entered by the operator and held only there.
- Proxmox admin is in the trusted computing base for staging. Option C is the only mitigation against it, which is why Option C is the gate for non-staging use.

### 6. Kubernetes admin access

- The cluster-admin kubeconfig exists only on `eo-control`, root-owned, used at the console (ADR-006).
- The controller uses a namespace-scoped service account bound only to the `eo-exec` Role in ADR-009. It is not cluster-admin.
- Headlamp gets a read-only identity with no Secrets, exec, attach or port-forward (ADR-006). No browser ever holds a token with write rights.
- Command Center keeps ADR-003 unchanged: its own account `eo-gateway`, SSH tunnel only, WebAuthn on `run.start` and `plan.request`. It holds no Kubernetes credentials. It asks the controller, and the controller acts.

## Consequences

- Option B adds a VM and the anchor channel, which needs its own threat review (T34 in `03-threat-model-delta.md`).
- Moving `journal.key` is a code change with a migration; it must land before any staging run whose evidence matters.
- Real model calls inside K8s wait for the credential-injection decision. This does not delay the critical path, because Phase C (first real runner) runs in the Podman pilot, not in K8s.

## Rollback

All of this is documentation. If the anchor channel design fails review, staging waits; Option A is not a fallback for staging because it does not survive root on `eo-control`.
