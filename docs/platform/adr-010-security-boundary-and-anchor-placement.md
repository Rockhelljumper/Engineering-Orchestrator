# ADR-010: Security boundary, anchor placement and evidence retention for the K3s topology

| Field | Value |
|---|---|
| Status | **Accepted in direction, conditionally (owner, 2026-11-03 19:13Z, F-2, F-5, F-6). Not final: pending independent review.** The anchor channel below is a design; implementing it needs the design reviewed first (F-5) |
| Date | 2026-11-03 |
| Relates to | ADR-005, ADR-006, ADR-008, ADR-009; threat model T6, T7, T10, T13, T16, T19; invariants on the anchor and journal; `03-threat-model-delta.md` |

## Context

In Phase B (one Hyper-V L2 VM), the rollback anchor (`services/anchor/eo_anchor.py`) runs on the same VM as the controller but under its own account (`eo-anchor`). It sits on its own LV (`/srv/eo-anchor`), which is never snapshotted (`infra/l2/guest/11-storage.sh`). The anchor detects rollback of a state root (T10) because it holds a monotonic high-water mark the controller cannot rewrite.

The K3s topology adds a root-level K3s server to `eo-control` (ADR-005). That changes what "separate account on the same VM" protects against:
- Any root compromise of `eo-control` gets root over the anchor too. This includes a K3s API-server or containerd escape on the server, which runs as root.
- A separate Proxmox disk with `backup=0` keeps the anchor out of backups. It does not stop someone with Proxmox admin rights from snapshotting, copying or rolling back that disk.
- The journal HMAC key is the file `journal.key` in the state root (`src/stateRoot.ts:44,74`). Whoever can read the state root can forge journal entries.

## Decision

### 1. Anchor placement (owner decision F-5)

| Option | What it is | Protects against | Does not protect against | Decision |
|---|---|---|---|---|
| A. As in Phase B | `eo-anchor` account and LV on the controller VM | Controller-uid compromise; restoring a state-root backup | Root on the controller VM (including a K3s server escape); Proxmox admin | Phase B (Hyper-V L2) only |
| B. Independent VM `eo-anchor` | Anchor on its own minimal VM, reached over the authenticated channel below | Rolling back history that is already anchored, by anyone short of Proxmox admin or the `eo-anchor` console | Root on `eo-control` holds the journal key and the channel client key, so it can forge and anchor *new* history going forward; Proxmox admin rolling back both VMs together | **Staging** |
| C. External witness | The anchor's high-water mark is also countersigned by a witness outside the Proxmox administrative trust domain | Proxmox admin rollback of both VMs | Compromise of the witness itself | **Required before non-staging** |

The anchor stays a systemd service, never a pod. On `eo-anchor` the existing service (`services/anchor/eo_anchor.py`) keeps its local Unix socket and SO_PEERCRED check, and its exact semantics. A channel daemon on the same VM, running as its own uid and sandboxed, is the only local client the service trusts as the controller (`--controller-user` names the daemon's uid). The channel replaces SO_PEERCRED for the cross-VM hop and nothing else.

### 1a. Anchor channel design (to be reviewed again before implementation)

**Semantics are unchanged; only the transport changes.** The anchor keeps its current rules (`eo_anchor.py:258-282`): an advance is accepted only for the same `keyId`, `seq == head + 1` and `prevJournalMac == head MAC`; a repeat of the current head with the same MAC is idempotent; skips, backwards moves, chain breaks and key changes are refused. The controller keeps `checkAnchor`, which refuses a journal more than one record ahead of the anchor (`src/anchor.ts:343-344`). A stolen client key therefore cannot jump the head; it can only advance it by one record that matches the chain, which is the forward-forgery limit of Option B stated above.

**Peers and identity.**
- Client: the controller on `eo-control`, through the existing `src/anchorService.ts` seam with a new transport.
- Server: the channel daemon on `eo-anchor`.
- Mutual TLS 1.3 over TCP 7443 on the dedicated link. Each side's key is generated on its own VM and never exported; certificates are pinned by SPKI hash and issued by an offline operator CA, enrolled at the console. The Proxmox firewall pins the link (ADR-008), but the firewall is not the authentication.
- Replies are signed with the anchor's **Ed25519** key; the client verifies them against the pinned public key. (Today's reply `mac` is symmetric and the client cannot check it, `src/anchorService.ts:78-85`.) The same signatures make the anchor's shipped log verifiable by an external reviewer.

**Operations the channel forwards.** Only `hello`, `read`, `advance`, and `forget` (which the service already allows only under an existing accept-rollback grant). The channel never forwards admin operations. **Grants, clears and re-initialisation happen only at the `eo-anchor` console** (`eo_anchor.py:298-323` admin socket, root only). `eo anchor --accept-rollback` on `eo-control` becomes a request that tells the operator what to run on `eo-anchor`; it cannot grant anything itself.

**Timeouts and the event loop.** The client must not block the controller longer than `leaseMs / 3`, so the lease heartbeat (`src/controller.ts:652-661`) keeps running. Today `call()` is `execFileSync` with a 30 s timeout (`src/anchorService.ts:91-96`); the channel client is either asynchronous or bounded below that limit. This is a code change in M8-K2.

**Failure semantics (fail closed).** The journal already stops after a failed anchor update: `append` records the failure and refuses every later append (`src/journal.ts:122,131-135`). The design keeps that and makes it explicit:

| Situation | Controller behaviour | Recovery |
|---|---|---|
| Channel down or timeout on an advance | **Frozen-journal mode:** no further appends; no new dispatch; running Jobs are held (or killed by deadline) without journaling; Command Center shows `anchor-unavailable`; the process exits cleanly | Reopen once the channel is back. Open finds the journal one record ahead of the anchor and repairs it through the existing one-ahead path (M2-0b crash case) |
| Channel down on open | Controller refuses to open | Restore the channel |
| Advance refused: anchor ahead of the journal | Rollback detected (T10). Refuse with a forensic record | Attended accept-rollback at the `eo-anchor` console, then spend reconciliation (below) |
| Advance refused: skip, chain break or key change | Refuse; forensic record | Attended investigation |
| Reply signature or certificate pin mismatch | Refuse; log externally | Attended re-enrolment |
| `eo-anchor` disk lost | Controller refuses to open | **Attended re-initialisation:** the operator reads the last anchor-signed head from the external evidence store and sets it with a new admin operation `set-head(seq, mac, keyId)` at the console. `set-head` refuses any value below the last externally recorded anchor seq. A blank `adopt` grant is never used for re-init, because under a grant the next advance at any seq is accepted (`eo_anchor.py:273-278`) and a compromised `eo-control` would choose the head |

**Restore of `eo-control` always means accepting a rollback** (every backup is older than the anchor). After any accepted rollback, the controller refuses to dispatch until **spend reconciliation** is recorded: provider-side usage for the worker key, compared with the external evidence log, with the difference journaled as spent (T9).

**Clock.** Certificate validity and grant expiry need a trusted time source on `eo-anchor` (grant expiry is compared as ISO strings, `eo_anchor.py:208`). It gets NTP from one pinned source through a dedicated path (ADR-008).

**Tests before it is used:** unit tests of the unchanged rules over the new transport (skip, chain break, key change, idempotent repeat); simulated tests with a fake transport (drop, delay, duplicate, reorder, crash at each step, two appends while down, timeout longer than `leaseMs/3`); an admin operation attempted over the channel is refused; `set-head` below the shipped head is refused; clock skew on `eo-anchor`; and a negative test that `eo-worker` and `eo-edge` cannot connect.

**Option C** countersigns each anchored head with a witness outside the Proxmox administrative trust domain, and the controller requires a witness receipt no older than a configured lag. Its design is a separate item before non-staging.

### 2. Journal key placement

- `journal.key` stays out of any Kubernetes object, PV or Secret.
- The staging deploy key is also in the state root today (`docs/07` §4). It moves the same way, so state-root backups carry neither key. Its push path also needs specifying: the proxy allows only `CONNECT :443`, so either SSH over 443 to GitHub's 443 endpoint is allowlisted, or pushes use HTTPS with a scoped token. Decided in M8-K2.
- On `eo-control` it moves from the state root to a root-owned key path readable only by the controller uid. A backup of the state root then does not contain the key that authenticates it. This is a code change in `stateRoot.ts`; it needs a migration test and is listed for M8-K2.
- A TPM- or vTPM-sealed key is the longer-term option. It is not required for staging.

### 3. Evidence and log retention outside the compromise boundary (owner decision F-6)

The evidence manifest is HMAC'd (`src/evidence.ts`), so tampering is detectable. A root attacker on `eo-control` could still delete the evidence or the key. For staging, these are shipped append-only to a store outside both `eo-worker` and `eo-control`:
- K8s API-server audit log (policy: Metadata for everything, RequestResponse for Jobs and RBAC objects, and **Metadata only for `secrets`**, so no credential value is ever logged);
- `eo-edge` proxy access logs (CONNECT host, SNI, bytes, decision);
- anchor high-water-mark changes;
- controller journal checkpoints (hash chain head plus seq). These come from `eo-control` and an attacker there controls them, so re-initialisation trusts only the anchor-signed log (§1a).

The store is **external and tamper-evident** (F-6): outside every EO VM and outside the Proxmox administrative domain, append-only (WORM) from the shippers' side, with each batch hash-chained and signed. Each shipper sends a sequence-numbered heartbeat, and a missing heartbeat or a sequence gap raises an alert, so withheld logs are detected. Retention is at least the life of the staging environment plus 90 days, to be confirmed by the owner. `eo-edge` may buffer logs, but is not the retained copy. The store, its credentials and its retention policy are not provisioned yet.

**K3s datastore.** Secrets are encrypted at rest (`--secrets-encryption`). The datastore backup also holds the cluster CA and server token, so it is classified and stored as a cluster-admin credential.

### 4. Per-attempt worker credentials

- Model API credentials are never in images, never in a long-lived Secret readable from `eo-exec`, and never in a node-wide location.
- The controller issues per-attempt credentials. It creates the Job suspended, then a Secret in `eo-exec` named for the attempt with an owner reference to the Job's uid, then unsuspends the Job. The Secret is deleted when the attempt finishes, and the reconciler deletes any left over. This needs `secrets` create/delete (not get/list) and `jobs` patch in the controller's Role (ADR-009).
- Where the provider supports it, the credential is scoped and short-lived. Where it does not (a long-lived API key), one option is for the proxy on `eo-edge` to inject it, so the worker never holds it. That would put a model key and a TLS interception CA on `eo-edge`, contradicting ADR-008's "no EO code or keys", so it is a separate owner decision. Until it is decided, real model calls stay out of K8s (they are already out of scope until Phase C).

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

- Option B adds a VM and the anchor channel, which needs its own focused review before implementation (T34 in `03-threat-model-delta.md`, F-5).
- No AI agent holds root console access on `eo-control` or `eo-anchor`. The console is the human boundary for grants, accept-rollback and `set-head`.
- Moving `journal.key` is a code change with a migration; it must land before any staging run whose evidence matters.
- Real model calls inside K8s wait for the credential-injection decision. This does not delay the critical path, because Phase C (first real runner) runs in the Podman pilot, not in K8s.

## Rollback

All of this is documentation. If the anchor channel design fails review, staging waits; Option A is not a fallback for staging because it does not survive root on `eo-control`.
