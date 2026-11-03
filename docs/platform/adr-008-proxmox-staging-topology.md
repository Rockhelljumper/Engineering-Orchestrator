# ADR-008: Proxmox staging topology: four VMs (eo-control, eo-worker, eo-edge, eo-anchor), amending the two-VM proposal

| | |
|---|---|
| Status | **Accepted in direction, conditionally (owner, 2026-11-03 19:13Z, F-2, F-3). Not final: pending independent review.** Amends the two-VM proposal (`roadmap/proxmox-staging-proposal.md`, eo-run plus eo-edge). No Proxmox resource is authorized |
| Milestone | M8-K0 (decision), M8-K3 (IaC, not applied), M8-K4 (provisioning, separately approved) |
| Relates to | ADR-005, ADR-006, ADR-009, ADR-010; threat model T6, T7, T8, T10, T13; `03-threat-model-delta.md` findings G-1 to G-12 |
| Owner decisions | F-3: the staging design target is four VMs, with an independent `eo-anchor`. Four VMs are not automatically sufficient for production; separating K3s administration from the controller is reassessed for non-staging. F-5: anchor on its own VM for staging; an external witness outside the Proxmox administrative trust domain before non-staging |

## Topology

```
                     Proxmox node (management on its own VLAN; Proxmox firewall on, default drop)
 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │                                                                                          │
 │ ┌─────────────────────┐ anchor channel ┌───────────────────────────┐ 6443  ┌────────────┐ │
 │ │ eo-anchor           │◀── 7443/tcp ───│ eo-control                │◀──────│ eo-worker  │ │
 │ │  eo-anchor service  │  (mutually     │  systemd: controller,     │ 10250 │ K3s agent  │ │
 │ │  only; no uplink,   │  authenticated,│   bd store, eo-gateway,   │──────▶│ worker and │ │
 │ │  no K8s, no EO code │  ADR-010)      │   artifact receiver       │overlay│ verifier   │ │
 │ │  anchor disk        │                │  K3s server (tainted),    │◀═════▶│ Jobs only  │ │
 │ └─────────────────────┘                │   Headlamp, Flux          │       └─────┬──────┘ │
 │                                        └──────────┬────────────────┘             │ 3128   │
 │                                                   │ 3128 (minimal allowlist)      ▼        │
 │                                       ┌───────────▼────────────────────────────────────┐   │
 │                                       │ eo-edge: allowlisting proxy, nftables default  │──▶ uplink
 │                                       │ drop, allowlist-only resolver, egress log      │   │
 │                                       │ shipped to external evidence store (F-6)       │   │
 │                                       └────────────────────────────────────────────────┘   │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

## VM roles

| VM | Runs | Trust | Holds |
|---|---|---|---|
| `eo-control` | EO controller, supervisor, journal, Beads store, `eo-gateway` and the frontend, artifact receiver (systemd, separate accounts). K3s server, tainted `NoSchedule` for EO workloads. Headlamp and Flux, pinned to this node | Trusted | State roots, journal key (moved out of the state root, ADR-010), the controller's anchor-channel client key, staging deploy key (M8), namespace-scoped Kubernetes identity, K3s datastore |
| `eo-anchor` | The anchor service only (`services/anchor/eo_anchor.py` behind the authenticated channel in ADR-010). No K8s, no EO controller code, no uplink | Trusted, minimal | The monotonic high-water mark and its own key. Its disk is never snapshotted or backed up with `eo-control` |
| `eo-worker` | K3s agent. EO worker and verification Jobs only | Untrusted | Nothing durable. Per-attempt emptyDirs, and the per-attempt worker credential while a Job runs (ADR-010) |
| `eo-edge` | Allowlisting forward proxy, allowlist-only resolver, nftables, egress audit logging | Security infrastructure | The allowlist; logs are shipped to the external evidence store (F-6). No EO code or keys |

## Network rules (Proxmox firewall, enforced outside every guest)

These rules hold even if a guest's root disables its own firewall.
- **eo-worker, outbound:**
  - `eo-edge:3128`;
  - `eo-control:6443` (API server);
  - the overlay port to `eo-control`.
  
  Nothing else: no default route to the uplink and no DNS except through the proxy.
- **eo-worker, inbound:** only `10250` (kubelet) from `eo-control`, and the overlay port.
- **eo-control, outbound:** `eo-edge:3128`, with its own minimal allowlist (GitHub staging, package mirror, time). It has no uplink route of its own.
- **eo-control, inbound:** SSH from the operator jump host; `6443` and the overlay port from `eo-worker`.
- **eo-control, outbound to eo-anchor:** `7443` only (the anchor channel).
- **eo-anchor:** inbound `7443` from `eo-control` only, and SSH from the management jump host. Outbound: only the log shipping path to the external evidence store. No uplink route, no DNS. `eo-worker` and `eo-edge` cannot reach it.
- **eo-edge:** accepts `3128` only from `eo-worker` and `eo-control`, and SSH from management. It routes and forwards nothing for either guest. NAT happens only on its own uplink interface.
- **All VMs:** IPv6 disabled at the VM NIC. `macfilter=1` and `ipfilter=1` on every NIC. The management VLAN cannot be reached from any EO VM.

### Kubernetes-side controls, so the cluster cannot route around eo-edge

- **NetworkPolicy:** default-deny ingress and egress in `eo-exec`. Worker pods may reach only the `eo-edge` proxy address (on the node network) and the artifact receiver on `eo-control` (ADR-009). They have no access to the API server, CoreDNS, the kubelet or other pods.
- **DNS:** worker pods get `dnsPolicy: None`, with no resolver. All names are resolved by the proxy. CoreDNS forwards only cluster names, so it is not an external DNS channel (finding G-4).
- **Overlay and services:** no NodePort, LoadBalancer or hostNetwork in `eo-exec`, and no ServiceLB for EO namespaces. The overlay between the two VMs is encrypted (for example WireGuard) or carried only on the dedicated VLAN pair; M8-K0 decides which.
- **Enforcement:** M8-K0 confirms that the pinned K3s version enforces NetworkPolicy. M8-K5 proves it with negative tests, never by configuration review alone.

### What the proxy does and does not do

The proxy allows `CONNECT host:443` by host name (SNI or CONNECT target). Through a TLS tunnel it **cannot** see URL paths, repositories, request bodies or responses:
- an allowed host such as GitHub or a package registry allows every path on it;
- data can leave through any allowed host.

This is not repository-level authorisation or content inspection. The controls that limit it:
- an allowlist kept as narrow as possible;
- worker credentials that are useless outside their scope;
- per-attempt egress logs;
- TLS interception only if the owner approves it later, which would put a CA inside the worker trust boundary.

## Is this topology enough for the accepted threat model?

**For staging, yes, under the conditions G-2 to G-6 and G-8 to G-10 in `03-threat-model-delta.md`.** The independent `eo-anchor` closes the gap where root on `eo-control` (including a K3s server escape) could rewrite the anchor (T27). What it does not close:
- G-1: the K3s server is still root on `eo-control`. A worker escape that reaches the API server is a path to the controller VM. NodeRestriction, no worker SA tokens, no Secrets beyond the current attempt's, and off-VM audit logs limit this; they do not remove it.
- G-11: a Proxmox administrator can roll back `eo-control` and `eo-anchor` together. Only the external witness (ADR-010 Option C) closes this.

**Not sufficient for production.** Before any non-staging environment: the external witness (F-5), and a reassessment of separating K3s administration from the controller, for example a dedicated `eo-k8s` server VM (F-3). Neither is designed here.

## Storage

| VM | Storage |
|---|---|
| `eo-control` | System disk. State-root disk, backed up with integrity checks |
| `eo-anchor` | System disk and anchor disk, `backup=0`, never in snapshots; never restored from an older image |
| `eo-worker` | System disk only, restorable from a template |
| `eo-edge` | System disk; logs shipped off |

## Backup and restore

| VM | What is backed up | Restore |
|---|---|---|
| `eo-control` | State roots, configuration and the K3s datastore, encrypted, kept off the Proxmox node | A restored state root older than the anchor's high-water mark is refused unless an operator runs `eo anchor` with `--accept-rollback` (T10) |
| `eo-anchor` | Nothing restorable. Its high-water-mark changes are logged to the external evidence store | Loss is handled by the attended re-initialisation in ADR-010, never by restore |
| `eo-worker` | Nothing (stateless) | Rebuild from template |
| `eo-edge` | Configuration, as code | Rebuild |

## Consequences

The first Proxmox milestone is M8-K4, gated on:
- verified hardware capacity;
- a network review of this ADR;
- reviewed IaC (M8-K3);
- a rollback runbook.
