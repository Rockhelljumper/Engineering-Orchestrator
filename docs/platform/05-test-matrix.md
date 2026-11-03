# 05 — Test matrix (Task F)

Types: **static** (lint, render, schema), **unit**, **simulated** (fake API / fake runner, no network), **integration** (real local components, no external network), **destructive** (deliberately breaks things in a sandbox), **live** (real cluster, real network or real model). Only static, unit and simulated tests are allowed without owner approval.

| # | Test | Type | Milestone | Proves |
|---|---|---|---|---|
| 1 | See test 33 (verdict separation) | — | — | — |
| 2 | Role profile → Podman args and Pod spec are equivalent (uid, caps, RO rootfs, mounts, env, resources, network) | unit (property) | M8-K1 | ADR-007 portability |
| 3 | Image references are digest-only in all manifests | static | M8-K1 | T33 |
| 4 | Two builds of the worker image give the same digest | integration | M8-K1 | Reproducibility (as M1-9) |
| 5 | Job name and spec hash are deterministic for (runId, taskId, attempt, epoch) | unit | M8-K2 | T31 |
| 6 | AlreadyExists with matching hash adopts; with a different hash escalates | simulated | M8-K2 | T31 |
| 7 | Create timeout → lookup before retry; no duplicate Job | simulated | M8-K2 | T31 |
| 8 | Stale attempt epoch is refused and its Job deleted | simulated | M8-K2 | T31 |
| 9 | Lost watch → periodic list reconciles to the same state | simulated | M8-K2 | ADR-009 |
| 10 | Controller deadline kills the Job; kill-unconfirmed keeps the lease | simulated | M8-K2 | T9 |
| 11 | Budget reserved before create; no create when the cap would be exceeded | simulated (property) | M8-K2 | T9, M2-6 |
| 12 | Job Succeeded with failing verifier → task not done | simulated | M8-K2 | T30 |
| 13 | Orphan Jobs and Secrets are deleted on restart | simulated | M8-K2 | T31, T32 |
| 14 | Controller RBAC: every verb outside the ADR-009 Role is denied | static (policy render) + live (`kubectl auth can-i`) | M8-K2 / M8-K5 | Least privilege |
| 15 | Admission denies non-digest image, hostNetwork, hostPath, privileged, NodePort, SA token automount in `eo-exec` | static (policy tests) + live | M8-K2 / M8-K5 | G-8, ADR-007 |
| 16 | `journal.key` migration: old state root opens, key moved, backup of the state root no longer contains it | unit + integration | M8-K2 | G-10 |
| 17 | Artifact receiver: token single-use, size cap, content hash checked | unit | M8-K2 | ADR-009 |
| 18 | Flux Kustomizations render; each uses an impersonated SA; no cluster-scoped object, NetworkPolicy or RBAC outside the promotion path; Flux flags `--default-service-account`, `--no-cross-namespace-refs`, `--no-remote-bases`; no image-automation or receiver controllers | static | M8-K3 | T28 |
| 19 | Headlamp identity cannot read Secrets, exec, attach or port-forward | live (`can-i`) | M8-K4 | T29 |
| 20 | Worker pod cannot reach: other pods, the API server, its own node's kubelet (10250), CoreDNS, `eo-anchor`, the platform namespace; can reach only the proxy and the artifact receiver | live, destructive | M8-K5 | G-3 |
| 21 | DNS exfiltration from a worker pod fails | live, destructive | M8-K5 | G-4 |
| 22 | IPv6 egress from both guests fails | live, destructive | M8-K5 | G-5 |
| 23 | Node credential from `eo-worker` cannot read Secrets of other nodes or create pods | live, destructive | M8-K5 | T26, G-2 |
| 24 | Escape probes (M2-10 list, adapted for pods) | live, destructive | M8-K5 | T6, T7 |
| 25 | Proxy denies non-allowlisted CONNECT and SNI mismatch | integration (local) then live | M8-K3 / M8-K5 | T8, G-7 |
| 26 | Restored `eo-control` state root is refused by the anchor without an accept-rollback grant made at the `eo-anchor` console | integration (fake transport) at M8-K2, then destructive at M8-K4 | M8-K2 / M8-K4 | T10, T27 |
| 27 | Cluster loss mid-attempt: controller marks attempt infra-failed, no spend lost, recovers when cluster returns | destructive | M8-K5 | G-12 |
| 28 | Full M8-5 scenario through K8s Jobs on staging | live, spends money | M8-K6 | M8-5, M8-6 |
| 29 | Anchor rules unchanged over the channel: skip, backwards, chain break and key change refused; repeat of the current head with the same MAC idempotent; different MAC refused | unit | M8-K2 | T10, T34 |
| 30 | Anchor channel over a fake transport: drop, delay, duplicate, reorder, crash at each step; two appends while down; timeout longer than `leaseMs/3` does not lose the lease; frozen-journal mode then one-ahead repair on reopen | simulated | M8-K2 | T34, F-5 |
| 31 | `eo-worker` and `eo-edge` cannot connect to `eo-anchor`; pin mismatch refused | live, destructive | M8-K5 | T34 |
| 32 | Admission rejects an image whose digest lacks CI provenance from the approved build environment | static (policy tests) + live | M8-K2 / M8-K5 | T33, T35 |
| 33 | Verdict separation: forged runner verdicts ignored; verdict replay across attempt or task refused; crash between run, verdict and transition recovers once; duplicate result applied once | unit + behavioural | Verdict separation PR | T5, T30 |
| 34 | Grant, clear or `set-head` attempted over the channel is refused | simulated | M8-K2 | T34 |
| 35 | `set-head` below the last externally recorded anchor seq is refused | unit | M8-K2 | T10, T34 |
| 36 | Clock skew on `eo-anchor` (grant expiry, certificate validity) fails closed | simulated | M8-K2 | T34 |
| 37 | After an accepted rollback, no dispatch until spend reconciliation is journaled | unit + behavioural | M8-K2 | T36, T9 |
| 38 | Controller restart with a live Job adopts it or confirms it gone before writing an end; Job from rolled-back history (other nonce) not adopted; old journals replay unchanged | simulated | M8-K2 | T11, T31 |
| 39 | Admission denies `nodeName`, control-plane tolerations, `hostPort`, ephemeral containers, non-emptyDir volumes; K3s traefik, servicelb, local-storage, metrics-server absent | static + live | M8-K2 / M8-K5 | G-8 |
| 40 | No plaintext Secret values in the K3s datastore, its backup, or the API audit log | live | M8-K5 | T32 |
| 41 | An AI GitHub identity cannot push, merge or bypass on the infra repo; an unsigned commit or unsigned promotion tag is not reconciled | live (GitHub API, read-only checks plus a rejected push from a test identity) | M8-K3 | T28 |
| 42 | Headlamp unreachable from pods and from the LAN; plugins disabled | live | M8-K5 | T29 |
| 43 | Evidence withholding (stopped shipper, sequence gap) raises an alert | integration | M8-K3 | G-9 |
