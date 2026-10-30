# ADR-003 — Command Center gateway: separate account, authenticated channel, SSE, SQLite read model

| | |
|---|---|
| Status | **Accepted (design), 2026-10-30**, as part of CC0 final acceptance (owner, 2026-10-30 02:20Z). Not implemented |
| Source | `proposal.md` §5.1–§5.3, §6.4, §6.7, §8.1, §9.3–§9.4; owner decisions OD-1, OD-2, OD-8, OD-9 |

## Context

The Command Center needs a web API and a live event stream. The controller (`eo`) is the only writer of journals and the single policy enforcement point (invariant 3, I-14). A network-facing component must not be able to change state, policy or approvals by itself.

## Decision

1. **A separate gateway process under its own account, `eo-gateway`**, in the L2 guest. It has no access to state roots, the journal key or worker clones. It reads controller feeds and writes only its own read model and the workspace store (T1).
2. **Reachability: SSH tunnel only (OD-1).** The gateway listens on a Unix socket or 127.0.0.1 inside the guest. The owner reaches it with an explicit `ssh -L` forward over the existing `eo-l2` SSH path. No new inbound port on the guest or host.
3. **Authenticated gateway-to-controller channel (§6.7):** the supervisor checks the peer uid, runs a handshake keyed by the per-boot `K_boot`, and accepts only MAC'd frames with a strictly increasing counter and an unexpired `exp` (I-23). Keys rotate every 24 h and on `eo gateway rotate-keys`. An `intentId` takes effect at most once.
4. **The controller authorises everything.** The gateway's capability list is only a UI hint. Approval decisions and confirm-grade intents carry WebAuthn assertions the controller verifies itself against `authz.json`, so a compromised gateway cannot produce them. Every `run.start` and `plan.request` needs a fresh, single-use assertion bound to its `intentId` (OD-9).
5. **Console-only administration (OD-2, OD-8):** policy, repositories, anchor adoption, role bindings, credentials, backup creation and export, and adding or widening manager grants have no API route.
6. **Server-Sent Events with replay:** a gap-free merged stream with per-project high-water marks; an `epoch` that changes only when the read model is rebuilt; clients on an older epoch are told to resync.
7. **SQLite read model (`projection.sqlite`, T3)**, rebuildable from controller feeds with an identical projection hash (I-20), behind a `ProjectionStore` interface so the engine can be swapped if `node:sqlite` proves unstable.

## Consequences

- A gateway compromise is bounded to reading the projection, submitting non-confirm intents such as `run.stop`, and denial of service. Detection, quarantine and recovery follow the §6.7 runbook (CC2-9, CC2-10).
- One extra guest account and process; channel tests CC1-14 run in the guest.
- Remote access beyond the SSH tunnel, and web-based grant approval, each need a new owner decision and security review.

## Rejected

Gateway inside the controller process; gateway with state-root access; exposing the gateway on the internal switch, the LAN or a cloud relay; WebSockets as the first transport; a read model that is not rebuildable.
