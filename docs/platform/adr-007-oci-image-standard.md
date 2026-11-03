# ADR-007: OCI image and packaging standard

| | |
|---|---|
| Status | **Accepted in direction, conditionally (owner, 2026-11-03 19:13Z, F-2). Not final: pending independent review and reconciliation sign-off.** No cluster, VM, package, registry or credential is authorized by this ADR |
| Milestone | Proposed M8-K1 (packaging design); extends M8-1 ("image builds from a pinned base; non-root; only the workspace mounted") |
| Relates to | Threat model T12 (supply chain), T24 (container hardening list), T6, T7; `docs/07-isolation-and-credentials.md` §3 L1/L2 controls; ADR-005, ADR-009 |

## Scope

This ADR covers only images that actually run:
- the worker images (implementer and reviewer roles, then research, testing and verification roles as they are defined);
- the verification image;
- the platform images (Headlamp, Flux and monitoring), which are pinned, not built.

EO's own controller, anchor and gateway are systemd services (ADR-005). They are packaged as pinned, hash-recorded artifacts, the same way `bd` is today (`deps.lock.json`), not as images. No Kubernetes object is created just to show containerisation.

## Standard

| Area | Requirement | How it is checked |
|---|---|---|
| Base | Minimal pinned base image, referenced by digest. Distroless or a slim distribution base where the tool chain allows | Build fails on a tag-only `FROM` |
| Identity | Every image reference in manifests, Job templates and Podman invocations is `name@sha256:…`. Tags are informational only | Admission check (ADR-006 §5); unit test on the Job builder (ADR-009) |
| Reproducibility | Pinned toolchain and dependency lockfiles, `SOURCE_DATE_EPOCH`, no network during the final build stage, and two independent builds compared | Two builds, digests compared, or the difference explained (the same rule M1-9 applies to `bd`) |
| Provenance | Provenance attestation and SBOM per image, stored with the evidence. Optional signature, verified at admission once a signing key is approved | SBOM present; attestation verified before promotion |
| Vulnerabilities | Scan at build and before promotion. Promotion is blocked on unwaived critical findings | Scan report in the evidence; waivers are owner-approved |
| User | Non-root numeric UID/GID. No setuid binaries | `runAsNonRoot: true`, `runAsUser` set; image inspection |
| Filesystem | Read-only root filesystem. Writable paths are explicit: `/workspace` (per-attempt emptyDir), `/tmp` (size-limited emptyDir) | Pod spec check; a write probe outside them fails (M8-K5) |
| Privileges | `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault` at minimum, AppArmor or SELinux profile per the guest OS, `automountServiceAccountToken: false`, no host namespaces, no hostPath | Admission policy; negative tests in `05-test-matrix.md` |
| Resources | CPU, memory, ephemeral-storage requests and limits on every container. Namespace `ResourceQuota` and `LimitRange`. PID limit through the kubelet `podPidsLimit` | Quota and LimitRange present; fork-bomb and fill-disk tests (M8-K5) |
| Termination | The process handles SIGTERM, and `terminationGracePeriodSeconds` is short (seconds). The controller's own deadline is authoritative (ADR-009) | Cancellation test |
| Dependencies | Version-pinned: OS packages by version, npm and pip by lockfile with hashes, `--ignore-scripts` where T12 already requires it. The Claude Code CLI is pinned with auto-update disabled (T12 note) | Lockfile review; no-network final stage |
| Secrets | Never baked into images or layers. The worker API key is injected per attempt (ADR-010) | Secret scan of image layers |

## Portability between K3s and rootless Podman

- The same image digest must run under containerd (K3s) and rootless Podman.
- Constraints that keep this true:
  - the image needs no Docker or Podman socket and no systemd inside;
  - all configuration comes through environment and mounted files;
  - the entrypoint is the same under both runtimes.
- The Podman invocation for the Phase B pilot and the Kubernetes Job template are generated from one role profile, so that the hardening flags stay equivalent. A unit test compares the two.

## Consequences

- **Registry (owner decision F-6):** an external or separately administered OCI registry. Images are immutable and pulled only by digest. No EO VM holds registry push credentials. Which registry is chosen, and its credentials, are not provisioned yet.
- **Builds (owner decision F-6):** images are built in an isolated CI environment, not routinely on `eo-control`. The build produces provenance, an SBOM and the two-build reproducibility check; the digest that passes is the only one promoted. `eo-control` and `eo-worker` only pull.
- The CI build environment, its trust boundary and its credentials are specified in M8-K1 before anything is created.
- Platform images (Headlamp, Flux) are pinned by digest and scanned, but not rebuilt.
