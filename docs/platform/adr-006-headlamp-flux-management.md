# ADR-006: Headlamp and Flux CD: cluster operations and GitOps, never a path around EO approvals

| | |
|---|---|
| Status | **Accepted in direction, conditionally (owner, 2026-11-03 19:13Z, F-2). Not final: pending independent review and reconciliation sign-off.** No cluster, VM, package, registry or credential is authorized by this ADR |
| Milestone | Proposed M8-K0 (decision), M8-K3 (manifests, not applied), M8-K4 (installation, separately approved) |
| Relates to | ADR-003 (gateway: SSH tunnel only, console-only administration OD-2/OD-8, WebAuthn per `run.start` OD-9); threat model T13 (unauthorised ref update or deploy); ADR-005, ADR-008, ADR-009 |

## Context

The owner selected Headlamp as the cluster interface and Flux CD for declarative reconciliation. Both carry Kubernetes credentials. Flux applies whatever is in its source, and Headlamp acts with whatever identity it is given. Without limits, either one would be a second control plane that sits beside EO's approval contract. Today that contract is the controller-verified WebAuthn confirmation, console-only administration, and an AI that can push only `eo/**` to a staging repository.

## Decision (proposed)

### Separation of roles

| Interface | Shows and does | Never does |
|---|---|---|
| **Headlamp** | Infrastructure operations: nodes, namespaces, pods, Jobs, events, logs, resource use | Approvals, budgets, task state, verification. It is not a source of EO truth |
| **EO Command Center** | Projects, plans, managers, assignments, evidence, budgets, approvals, verification, recovery | Holding Kubernetes credentials. The gateway has none. Execution facts reach it only through the controller's verified state |

The Command Center never treats a completed pod as a completed task. It shows the controller's verdict.

### Headlamp access

1. **Reachability:** the same rule as ADR-003. Headlamp listens on a cluster-internal address. The owner reaches it with an SSH `-L` forward to `eo-control`. There is no Ingress, NodePort, LoadBalancer or LAN exposure.
2. **Identity: no shared admin token in the browser.**
   - The default Headlamp identity is a read-only role: `get`, `list` and `watch` on workloads, events and logs in the EO namespaces. It has no access to `secrets` and no `exec`, `attach` or `portforward` (`pods/exec`, `pods/attach`, `pods/portforward`).
   - Administrative actions use `kubectl` at the `eo-control` console under a separate admin kubeconfig. They are recorded by the API server audit log (ADR-010).
   - If web admin is wanted later, it needs per-user OIDC or a short-lived impersonation flow. That is a separate owner decision and security review, consistent with ADR-003's "web-based administration needs a new owner decision".
3. **Authentication in front of Headlamp:** besides the SSH tunnel, Headlamp's own token or OIDC login. M8-K0 confirms what the pinned Headlamp version supports.
4. **Headlamp and Flux run on the trusted VM, so they are contained.** Headlamp renders untrusted pod logs and Flux source-controller fetches from the network. Headlamp plugins are disabled; a NetworkPolicy denies all traffic from `eo-exec` to the platform namespace; Headlamp is unreachable from pods and from the LAN.

### Flux

1. **Source scope.** Flux on staging reconciles from **one dedicated infrastructure repository**, a fixed branch and a fixed path per environment. It never reconciles from this repository's working branches, and never from the staging repository that EO's controller can push to (T13).
2. **Who can change the source.** The infrastructure repository is human-merge only:
   - branch protection with required review by the owner;
   - no AI or controller credentials have write access;
   - no deploy-key bypass;
   - branch protection applies to administrators too, and CODEOWNERS names the owner for every path;
   - no AI GitHub identity has write, admin or bypass rights on the infrastructure repository;
   - every commit Flux reconciles must carry a verified signature from an owner key; the `GitRepository` verification is configured to fail closed, so an unsigned commit is never applied (M8-K0 confirms the pinned Flux version supports this; if not, Flux is not adopted until it does).
   
   An AI agent may open a PR proposing a manifest change. Committing YAML never grants deployment authority.
3. **Least-privilege reconciliation.** Flux runs with `--default-service-account` (no Kustomization runs as Flux itself), `--no-cross-namespace-refs` and `--no-remote-bases`. No image-automation controllers and no notification receivers (webhooks) are installed. Each `Kustomization` impersonates a dedicated service account scoped to its own namespace:
   - **platform:** Headlamp and monitoring;
   - **eo-exec:** quotas and LimitRanges only. There are no worker Job templates in the cluster: the controller renders Job specs only from its own policy (ADR-009 principle 4).
   
   **Promotion-gated:** cluster-scoped objects (CRDs, ClusterRoles, admission policy, namespaces) **and** every NetworkPolicy, Role and RoleBinding go in a separate `Kustomization` that reconciles only a pinned tag. Moving that tag is the owner's recorded approval: a signed tag by the owner key, which the `GitRepository` verifies. A merge alone therefore deploys nothing that changes isolation or permissions.
4. **Changes that always need explicit owner approval**, as a reviewed PR to the infrastructure repository plus a recorded approval (the owner-signed promotion tag above):
   - new infrastructure resources;
   - RBAC expansion;
   - secret access changes;
   - NetworkPolicy relaxation;
   - new egress destinations (which also need an `eo-edge` allowlist change, ADR-008);
   - privileged or host-namespace workloads;
   - admission-policy changes;
   - image promotion to an environment;
   - anything that widens model spending or agent privileges.
5. **A backstop admission policy, independent of Flux.** It rejects privileged pods, host namespaces, hostPath, added capabilities and unpinned images in the EO namespaces, so that a bad reconciliation fails closed. The mechanism is chosen in M8-K0: Kubernetes ValidatingAdmissionPolicy or Pod Security Admission `restricted`, plus image-digest checks.
6. **Secrets.** Flux manifests carry only references. Worker API keys never pass through Flux or Git (ADR-010).

## Proposed infrastructure repository layout (M8-K3, not created yet)

```
clusters/staging/            # Flux entry point for staging (Kustomizations, sources)
infrastructure/              # cluster-scoped: namespaces, CRDs, admission policies (promotion-gated)
policies/                    # NetworkPolicies, RBAC per namespace (promotion-gated)
platform/                    # Headlamp, monitoring (version-pinned HelmRelease or manifests)
eo/                          # quotas, LimitRanges for eo-exec (no Job templates: the controller renders specs from its own policy)
overlays/dev | staging       # environment overlays; production/ only when a production milestone exists
secrets/                     # references only (names, key ids); never values
versions.yaml                # every pinned image digest and chart version, one place to review
runbooks/                    # promotion, rollback, break-glass, restore
```

## Consequences

- One more repository and review path. Deployment authority stays with a human merge plus an explicit promotion, matching T13's "AI pushes only `eo/**` to staging".
- Headlamp is useful for troubleshooting without becoming an approval surface. Admin actions are console-only, consistent with OD-2.
- No AI agent holds root console access on `eo-control` or `eo-anchor`, or the owner's signing key.
- Rollback is a revert of the infrastructure repository followed by reconciliation. Cluster-scoped changes roll back through the same promotion step.

## Rejected

Headlamp with a cluster-admin service-account token; exposing Headlamp or Flux webhooks outside the SSH tunnel; Flux watching an AI-writable branch; the Command Center gateway holding Kubernetes credentials; image automation that promotes new tags without a human step.
