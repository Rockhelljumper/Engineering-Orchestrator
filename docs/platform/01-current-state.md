# 01 — Current project state (Task A)

Established 2026-11-03 ~19:00Z from the GitHub REST API, a fresh `git fetch` in the cloud checkout, and a read-only audit on RH-DT-M3 (no elevation, no changes). 72da827 was checked, not assumed.

## Repository

| Item | State | Checked by |
|---|---|---|
| `main` | `79fef7a` (PRs #1–#3 merged: M0 architecture, M1 controller core, M2 Phase A) | `git log origin/main` |
| PR #4 `claude/m2-phase-b` | Draft, open, head `72da827`, all 6 CI checks green | GitHub REST `pulls/4`, check runs |
| PR #5 `claude/architecture-plan-pe9g5y` | Draft, open, head `5928229`, Command Center CC0 docs (ADR-003, ADR-004) | GitHub REST `pulls/5` |
| This K8s package | Draft PR on `claude/m8-k0-platform-design` (F-4) | — |

## Workstation (RH-DT-M3)

| Item | State |
|---|---|
| Checkout | Re-pinned 2026-11-03 ~19:15Z (F-1) from `2d146ed` to detached `72da82786081e4bf62202403a6c41f3b4acc2896`, clean tree, all six 01c-related script hashes match the reviewed values |
| Applied steps | 00 preflight, 03 ISO fetch, 01 switch, 01b host guard (verified PASS 2026-11-01 23:02:27Z, accepted) |
| Step 01c | **Authorized (F-1), handed to the operator; not run at the time of writing.** All four bindings on `eo-l2-int` (Npcap, VBoxNetLwf, ms_pppoe, ms_ndisuio) still enabled; NDIS Capture extension on the switch still enabled |
| VMs | None. Switches: Default Switch, WSL, `eo-l2-int` |
| Evidence folder | `C:\ProgramData\eo-l2` needs elevation to list; newest evidence seen is `20261101T230227Z-verify-host.transcript.txt` |
| Provisioning log | Was kept only in the project files and the host evidence folder; now copied into PR #4 as `docs/milestones/M2-phaseB-provisioning-log.md` (F-4) |

## Milestones

| Milestone | Status |
|---|---|
| M0 Architecture | Completed (merged) |
| M1 Controller core | Completed (merged): journal, Beads store, FileLock single writer, evidence, budget reservation, doctor |
| M2 Phase A (M2-0, M2-0b) | Completed (merged): rollback anchor, durable test runner |
| M2 Phase B (L2 VM provisioning) | **In progress.** 01c authorized and ready for the operator; step 02 not authorized |
| M2 main (M2-1..M2-10) | **Unstarted.** Only `FakeRunner` exists; CLI accepts only `--runner fake` (`src/cli.ts:128`); no real Claude adapter, no role profiles, no guard hook, no workspace manager |
| M3 Verification, gates, correction loop | Unstarted. Note: `RunResult` currently carries verification and review verdicts (`src/runner/types.ts:14-27`), which lets a worker grade itself (T5). Must be split before any real runner |
| M4–M7 | Unstarted |
| M8 Isolated unattended worker | Unstarted. The K8s work in this package is proposed as an M8 sub-track (M8-K0..K6) |
| Command Center (CC0..CC7) | CC0 docs in draft PR #5; CC1+ unstarted |

## Code facts that drive the K8s placement

| Fact | Where | Consequence for K8s |
|---|---|---|
| Lock liveness uses `process.kill(pid, 0)` | `src/util/fsx.ts:98-104`, `src/util/lock.ts:141-160` | Breaks across PID namespaces (pods): split brain or permanent refusal. Controller must not be a pod without a lock redesign |
| `assertPrivateDir` refuses group-writable or foreign-owned dirs | `src/util/fsx.ts:19-26` | A pod `fsGroup` would make the controller refuse its own state root |
| Atomic write = temp + fsync + rename + dir fsync | `src/util/fsx.ts:36-77` | Needs local POSIX semantics; network PVs are not proven to honour them |
| `journal.key` lives in the state root | `src/stateRoot.ts:44,74` | Anything that can read the state root (a PV snapshot, a backup) gets the forging key. ADR-010 moves it |
| Anchor checks SO_PEERCRED; socket-activated; PrivateNetwork, IPAddressDeny=any | `services/anchor/eo_anchor.py:86-89,369-375` | Only works on a local Unix socket. Anchor must be a host service |
| Node client shells out to `python3 -I eo_anchor_client.py` per call | `src/anchorService.ts` | Python must be on the controller host; fine for systemd, awkward in a distroless pod |
| Beads store runs pinned `bd` (embedded Dolt) and `git init` | `src/store/beads.ts:128,225,244` | `deps.lock.json` needs a linux pin for the eo-control VM |
| Budget is an in-process reservation governor | `src/budget.ts` | Must reserve before Job create (ADR-009) |
| Policy matches `approvedRepositories` by realpath | `src/policy.ts:8-10` | Workspace paths must be stable on the controller host |
| Guest bootstrap sets up podman, accounts `eo`/`eo-anchor`/`eo-worker`, subuid range, worker image uid 10001 | `infra/l2/guest/10-bootstrap.sh` | Reusable for the Podman pilot unchanged |
