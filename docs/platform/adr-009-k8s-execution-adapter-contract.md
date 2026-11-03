# ADR-009: Kubernetes execution adapter: the contract between the EO controller and K3s Jobs

| | |
|---|---|
| Status | **Accepted in direction, conditionally (owner, 2026-11-03 19:13Z, F-2). Not final: pending independent review and reconciliation sign-off.** No cluster, VM, package, registry or credential is authorized by this ADR. Specification only. Implementation is allowed only against a fake Kubernetes API in unit tests until M8-K4 or later authorises a live cluster |
| Milestone | Proposed M8-K2 (contract, fake-API implementation, negative tests) |
| Relates to | `src/runner/types.ts` (`Runner`, `RunRequest`, `RunResult`); `src/controller.ts` (`run()` and `runAttempt`, budget reserve before launch); threat model T5, T9, T10, T11, T18; ADR-005, ADR-007, ADR-008, ADR-010 |

## Principles

1. The controller stays authoritative. The adapter is a `Runner` implementation (`kind: "k8s-job"`). It translates one controller-authorised attempt into one Kubernetes Job and reports observed facts back. It never decides task state.
2. **Job success is not task success.** The adapter returns completion and exit facts, artifacts and the reported cost. Verification and review verdicts come only from the controller's own verifier and reviewer (M3), run as separate attempts.
3. **Precondition change, needed before any real runner (Podman or Kubernetes).** Today `RunResult` carries `verification` and `review` verdicts that the fake runner scripts (`src/runner/types.ts:14-27`). A real runner must not be able to supply them (T5). The interface is split: `RunResult` keeps only completion facts, and verdicts move to a controller-side `Verifier` and `Reviewer`. This is the first code change in `05` §E.

## Request (controller → adapter)

`RunRequest` is extended. The extension is fixed in M8-K2. Its fields:

| Field | Purpose |
|---|---|
| `runId`, `taskId`, `attempt`, `attemptEpoch` | Identity. `attemptEpoch` is the journal sequence of the `attempt.dispatch` record that authorised this attempt |
| `role`, `imageDigest` | The image digest must be in the policy's approved-image list for that role |
| `resources` | CPU, memory and ephemeral-storage requests and limits, a deadline in seconds, and a PID limit. These are checked against policy ceilings |
| `credentialRef` | A reference to the attempt's scoped worker credential (ADR-010). Never the value |
| `artifactUploadToken` | A single-use token for the artifact receiver, bound to this attempt (see Artifacts) |
| `signal` | An AbortSignal, as today |

The adapter refuses before any API call when the image digest is not approved for the role, a limit exceeds the policy ceiling, the deadline is missing, or the request carries an epoch older than the newest one the adapter has seen for that attempt.

## Job object

- **Name.** `eo-<hash(runId, taskId, attempt, attemptEpoch)>`, deterministic. The labels carry the same identity in clear text, plus `eo/spec-hash`, a hash of the full rendered spec.
- **Namespace.** `eo-exec` only.
- **Job settings:**
  - `backoffLimit: 0`, so retries are a controller decision, never Kubernetes';
  - `activeDeadlineSeconds` set from the request;
  - no `ttlSecondsAfterFinished` (the adapter deletes the Job after the evidence is collected);
  - `podFailurePolicy` so that infrastructure disruption is reported as `infra`, not as a task failure.
- **Pod spec:**
  - the hardening from ADR-007;
  - `automountServiceAccountToken: false`;
  - `enableServiceLinks: false`;
  - `dnsPolicy: None` (ADR-008);
  - node selector `eo-worker`, with no toleration for the control-plane taint;
  - emptyDir `/workspace` and `/tmp` with size limits.

## Identity and idempotency

| Situation | Behaviour |
|---|---|
| `create` succeeds | The adapter journals `attempt.started` with the Job uid |
| `create` returns AlreadyExists | The adapter reads the existing Job. If its labels and `eo/spec-hash` match, it adopts it: the operation was an ambiguous retry, and the Job is not executed twice. If they differ, it refuses and escalates (`attempt-identity-conflict`). It never deletes and recreates |
| `create` times out, or the outcome is unknown | The adapter looks the Job up by name before any retry. It creates again only after a confirmed NotFound |
| Controller restart | Recovery lists Jobs by `eo/run` label and reconciles them against the journal (next table) |

### Reconciliation (journal vs. observed Kubernetes state)

| Journal says | Kubernetes shows | Action |
|---|---|---|
| dispatch, not started | No Job | Create, as above |
| dispatch, not started | Matching Job | Adopt, and journal `attempt.started` |
| started | Job running, within the deadline | Resume watching |
| started | Job gone, or pod lost / evicted / node lost | Attempt is `infra`-failed, recorded as `lost-worker`, then retry per `maxInfraRetries` |
| started | Job finished | Collect the result, then verify (controller-side) |
| attempt superseded (newer epoch) | Older Job still present | Delete it. Never accept its result (stale-result rule) |
| no record | Job carries `eo/` labels | Orphan: delete it and record forensic evidence. Never adopt |

**Stale results.** A result is accepted only if:
- its Job's `attemptEpoch` equals the journal's current epoch for that attempt;
- the attempt is still open in the journal.

Anything else is recorded and discarded.

## Watching, deadlines and cancellation

- **Watching:** a watch on Jobs and pods in `eo-exec` with the `eo/run` label, plus a periodic full list, because watches can drop events. Pod phases, container exit codes and termination reasons are journaled as observations.
- **Deadline:** the controller's own deadline governs. `activeDeadlineSeconds` is the backstop. When the controller's deadline passes, it deletes the Job with `propagationPolicy: Foreground` and confirms that the pod is gone.
- **Lease:** if the pod is still visible after `terminationGracePeriodSeconds` plus a margin, the attempt is marked `kill-unconfirmed` and the run blocks. The lease stays held until the pod is confirmed gone, so a second attempt never runs beside a zombie (T11).
- **AbortSignal:** maps to the same delete path.
- **Global kill switch:** deletes every `eo-exec` Job and stops new creation.

## Artifacts and diagnostics

- **Artifact receiver.** Workers push their output to an EO artifact receiver on `eo-control` over the pod network. Only `eo-exec` pods reach it, per the NetworkPolicy. The output is a git bundle of the attempt branch, plus declared files.
- **Upload rules.** Each upload must:
  - carry the single-use `artifactUploadToken`;
  - stay within a size cap;
  - be content-addressed.

  The receiver writes into the attempt's evidence area and never into the state root.
- **Logs.** Pod logs are read through the API with a log-read-only identity. They are treated as untrusted data (T2) and size-capped.
- **No `exec` or `cp` into pods.** The controller's identity has no `pods/exec` permission.

## Controller's Kubernetes identity (RBAC)

| Scope | Permissions |
|---|---|
| Namespace `eo-exec` | `jobs`: create, get, list, watch, delete. `pods`: get, list, watch. `pods/log`: get. `events`: list |
| Everything else | Nothing: no `secrets` read, no `exec`, no cluster scope |

Worker credentials are created per attempt by a separate path (ADR-010), not by this identity.

## Budget

The governor's reservation happens before `create`, as it does today (`controller.ts`, reserve before launch). The adapter adds no spending path. Kubernetes resource limits bound CPU and memory, not model spend, so the worker key's provider-side spend limit and the per-attempt cap remain the spend controls (T9).

## Negative tests (all against a fake API in M8-K2)

1. AlreadyExists with a matching spec means adopt, with no second create. With a different spec, the adapter escalates.
2. A create timeout followed by a lookup that finds the Job means no duplicate.
3. A controller kill at every adapter step boundary. After recovery, at most one Job per attempt and no lost attempt. This reuses the M1-4 crash-sweep harness.
4. A stale epoch result is rejected. An orphan Job is deleted, not adopted.
5. When the pod survives deletion, the attempt is `kill-unconfirmed` and no new attempt starts.
6. Lost node, eviction and pod deletion each count as an infra failure, retried within `maxInfraRetries`.
7. An unapproved image, a missing deadline, or limits above the ceiling are refused before any API call.
8. A worker-reported "success" with failing controller verification never ends `done`.
9. A watch gap (dropped events) is caught by the periodic list.
