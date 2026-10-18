# M0 report — architecture and planning

Revision 2. It incorporates the owner's changes-requested review of revision 1 and a second independent review.

## Acceptance criteria

| AC | Result | Evidence |
|---|---|---|
| M0-1 Eight documents (00–07) exist and trace requirements 1–10, the security constraints and the demo deliverables | PASS | `docs/00`–`07`; traceability table in `03-dependency-map.md` §4 |
| M0-2 Third-party evaluations cite pinned commits and file:line evidence | PASS | `01-component-evaluation.md`. Key claims were re-checked by hand and by two independent reviewers. In round 1, 13 of 14 claims checked out and one (the Go version) was corrected. In round 2, 9 further claims were checked and the corrections are listed below |
| M0-3 Nothing installed, no host configuration changed | PASS | This PR changes only `README.md` and `docs/`. Third-party repositories were cloned into a scratch directory and read; none of their scripts, builds or binaries were run. On the user's PC only folder names were listed (home, `Program Files`, `Program Files (x86)`, `%LOCALAPPDATA%`); no command ran there and no access was requested |
| M0-4 User approves the PR | PENDING | Revision 1 received "changes requested"; revision 2 awaits review |

## Round 1: independent review of revision 1

| Severity | Finding | Resolution |
|---|---|---|
| Critical | Verification ran agent-written code with controller privilege | Principle 8: workers and verification run inside an isolation boundary; state root outside it; HMAC-keyed journal and manifests (arch §1, §3; T18) |
| Critical | Git worktrees share `.git`, so planted hooks could run in the controller | Per-attempt independent clones; fetch with hooks and fsmonitor disabled (arch §3; T19; M2-7) |
| Critical | Test command not protected (`"test": "exit 0"`) | Controller-owned test command; `package.json`, runner config and `tsconfig` protected (arch §6.3; T20; M3-9) |
| High | Go version claim wrong (beads needs 1.26.x) | Pin Go 1.26.7, `GOTOOLCHAIN=local` (M1-9) |
| High | `--setting-sources` does not stop `CLAUDE.md`; `--restricted`/`--bare` not considered | Measured in M2-5 |
| High | Invalid settings silently drop the guard hook | Hook canary (M2-8) |
| High | Unbounded integration and infra loops | Counters and `blocked` transitions for every loop (arch §5; M3-8) |
| Medium | Repo approval, unattended escalation, red-evidence quality, traceability gaps, unverifiable criteria, inconsistencies | Fixed (see revision 1 history in git) |

## Round 2: owner's requested changes

| # | Request | Resolution |
|---|---|---|
| 1 | WSL2 alone is not a strong sandbox; document host access, interop, drive mounts, credential exposure, and the difference between Windows users, WSL2, containers and VMs | New `07-isolation-and-credentials.md` §2 compares all five options on each property. WSL2 is never an isolation tier. New tiers: P (supervised pilot, separate Windows user, sample project only), L1 (hardened container), L2 (local VM, preferred), PX (Proxmox). Tools were inspected read-only first (§1), with read-only commands listed for the user to settle the choice. Threats T6, T7, T23, T24; criterion M2-10 adds escape probes |
| 2 | Deploy keys do not restrict pushes to `eo/*` | Corrected (`07` §4). Before M8 the controller holds no GitHub credentials. Unattended pushes go to a separate staging repository using rulesets A1, A2 and B. Only the controller holds the key, Actions are disabled, and staging content is treated as untrusted. M8-6 tests every forbidden ref update with the real credential and stores GitHub's rejections |
| 3 | Budget flag and reported usage are not hard billing limits | `07` §5. The governor reserves `cap + maxTurnCost` before each launch, adds wall-clock timeouts and token caps, and uses a Console spend limit as the provider-side backstop. M2-6 now tests governor behaviour; M2-6b measures overshoot as information; M7-8 no longer asserts a dollar ceiling |
| 4 | Independent acceptance and mutation controls for test integrity, including helpers and result forgery | Arch §6.4. Adds holdout tests (only criterion ID and pass/fail are returned), forgery canaries, piped result collection, a mutation check with a sentinel mutant (built on the TypeScript compiler API, so nothing new to install), a base cross-run, protected test support code and a tamper scan. New scenario S10; criteria M3-10 to M3-15 |
| 5 | Preserve the M1 approval gate | Standing authorisation rule in `05` §1 and in the README: no installation, live spend, merge, production access or Proxmox change until approved |

## Round 2: second independent review

| Severity | Finding | Resolution |
|---|---|---|
| High | One ruleset cannot target both branches and tags | Split into A1 (branches except `eo/**`), A2 (all tags) and B (`eo/**`). Bypass lists are checked for deploy keys from the exported JSON |
| High | Unclear who holds the staging key; `eo/**` fast-forwards; refs and workflow files outside the rulesets | Only the controller holds the key, outside every container. Actions are disabled on staging, and staging content is untrusted. M8-6 covers notes and custom refs and probes for the key |
| High | Reservation factor of 3× was below the 8.4× already observed | Reserve `cap + maxTurnCost`, initially `max(10 × cap, cap + $1)`. The between-turns mechanism is marked as a hypothesis |
| High | Holdout assertion messages leak expected values | Only criterion ID and pass/fail are returned; M3-11 adds a leakage test |
| High | The nonce is readable inside the boundary, and a result file there could be overwritten | Results are streamed over a pipe. Canaries are documented as catching naive forgery only, and invariant 11 is weakened to match. A tamper scan of the diff is added (M3-15). Deliberate in-boundary forgery is stated as a residual risk |
| Medium | Pilot tier had no process-control mechanism | Broker run as the pilot user (interactive `runas`, no saved password), named pipe ACL, Job Object kill-on-close |
| Medium | Epic overshoot described as a guarantee | Reworded as an estimate from measurements |
| Medium | "Non-equivalent mutants" not measurable; M6-1 manual | Excluded mutants must be listed with reasons; M6-1 is a scripted headless run |
| Low | Stale wording (T2, Tier-1, deploy key vs PAT, "hard spend limit", S1–S9, controller principal, list break) and this report | Fixed |

## Remaining limitations

- Deliberately written forgery code inside the isolation boundary can defeat runtime checks. It must appear in the diff and is caught only by the tamper scan, the security reviewer and human PR review (T18 residual).
- The supervised pilot tier relies on NTFS ACLs between two local accounts and shares network and drives with permissive ACLs. It is limited to the sample project with a person watching.
- Client-side budget overshoot per invocation is measured, not prevented. The Console spend limit's enforcement timing is the provider's.
- Folder names suggest Docker Desktop, WSL, Hyper-V and VirtualBox are present on the PC. Their versions and enabled state are unverified until the user runs the read-only checks in `07` §1.
- Whether beads builds on Windows is unknown until M1. The L2 VM (Linux) avoids the question.
- Rulesets on a private staging repository would need GitHub Pro, Team or Enterprise.

## Spend

No live orchestrator workers were run. Planning used this Claude session plus four read-only helper sessions: two source reviews and two independent document reviews (one per revision).
