# M0 report — architecture and planning

## Acceptance criteria

| AC | Result | Evidence |
|---|---|---|
| M0-1 Seven documents exist and trace requirements 1–10, the security constraints and the demo deliverables | PASS | `docs/00`–`06`; traceability table in `03-dependency-map.md` §4 |
| M0-2 Third-party evaluations cite pinned commits and file:line evidence | PASS | `01-component-evaluation.md`; key claims re-checked by hand and by the independent reviewer (14 claims, 13 correct, 1 corrected below) |
| M0-3 Nothing installed, no host configuration changed | PASS | This PR changes only `README.md` and `docs/`. Third-party repos were cloned into a scratch directory and read; none of their scripts, builds or binaries were run |
| M0-4 User approves the PR | PENDING | PR review |

## Independent review

A separate read-only reviewer session (which did not write the documents) checked the drafts against the brief and the vendor source. Findings and how each was resolved:

| Severity | Finding | Resolution |
|---|---|---|
| Critical | Verification ran agent-written code with controller privilege, so code under test could rewrite state or forge results | Principle 8: workers and verification run as a separate sandbox principal; state root outside workspaces; HMAC-keyed journal and manifests; controller-owned reporter + inventory cross-check; residual risk stated (arch §1, §3, §6.3; threats T18) |
| Critical | Git worktrees share `.git`, so a worker could plant hooks or `core.fsmonitor` that run in the controller | Per-attempt independent clones from a bare mirror; fetch with hooks and fsmonitor disabled (arch §3; T19; M2-7) |
| Critical | Test command itself was not protected (`"test": "exit 0"`) | Controller-owned test command from policy; `package.json`, runner config, `tsconfig` protected (arch §6.3; T20; S3e; M3-9) |
| High | Go 1.24.7 claimed sufficient for beads; `go.mod` needs 1.26.5 / toolchain 1.26.7, and `GOTOOLCHAIN=auto` would download silently | Corrected; pin Go 1.26.7 with `GOTOOLCHAIN=local` (00, 01, 03; M1-9) |
| High | `--setting-sources` does not stop `CLAUDE.md` loading; `--restricted` and `--bare` not considered | Documented; M2-5 measures all three options with a CLAUDE.md canary |
| High | Invalid settings files are silently ignored, so the guard hook could vanish | Hook canary at the start of every worker run (arch §3; T21; M2-8) |
| High | Integration and infra-retry loops had no bound | Counters table and `blocked` transitions for every loop (arch §5; M3-8) |
| Medium | Approval of existing repos was text only | `approvedRepositories` in controller-side policy (arch §9; T22; M1-10) |
| Medium | No escalation channel for unattended runs | Status branch, optional issue (arch §9; M8-7) |
| Medium | Import errors could count as red evidence | Assertion-level red evidence + reviewer check of tests (arch §6.2; M4-5) |
| Medium | Traceability omitted security constraints, demo deliverables and token budgets | Rows added; governor tracks tokens as well as USD |
| Medium | Several criteria not third-party verifiable (M2-6, M4-2, M6-4, M7-3/4, M7-7, M7-9, M8-4, M8-6) | Rewritten as scripted checks with stored output, reference plan for scoring, `prompt-injection` finding definition |
| Low | Inconsistencies: document count, missing approval points for M4/M6, test-first optional vs mandatory, policy inside target repo | Fixed; test-first is the default with a reasoned opt-out; policy moved to the state root |

## Remaining limitations

- No container runtime was available in the planning environment, and nothing on the Windows PC or Proxmox was inspected beyond top-level folder names. Open questions are listed in `00-environment-inspection.md` §5.
- Code under test can still forge its own tests' results inside the test process (T18 residual).
- Whether beads builds on Windows is unknown until M1.

## Spend

No live agent workers were run for the orchestrator. Planning used this Claude session and three read-only helper sessions (two source reviews, one independent document review).
