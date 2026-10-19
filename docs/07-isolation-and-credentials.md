# 07 — Local isolation, GitHub credentials and spend limits

This document answers three questions the architecture depends on: what actually isolates agent-run code on the user's Windows PC, how pushes are restricted on GitHub, and what Claude Code's budget controls do and do not guarantee.

## 1. What is installed on the PC (read-only observation)

Observed on 2026-10-18 from folder names only, through the desktop app's directory listing. No folder was opened, no command was run on the PC and nothing was changed. Presence of a folder does **not** prove a feature is enabled, running or current.

| Evidence | Suggests |
|---|---|
| `C:\Program Files\Docker`, `%LOCALAPPDATA%\Docker`, `%LOCALAPPDATA%\docker-secrets-engine` | Docker Desktop installed (backend unknown: WSL2 or Hyper-V) |
| `C:\Program Files\WSL`, `%LOCALAPPDATA%\wsl` | WSL installed |
| `C:\Program Files\Hyper-V` | Hyper-V tools present; whether the Hyper-V role is enabled depends on Windows edition and settings |
| `~\.VirtualBox`, `~\VirtualBox VMs`, `C:\Program Files\VB` | VirtualBox in use |
| `C:\Program Files\Git`, `GitHub CLI`, `Go`, `nodejs` | git, gh, Go and Node on the host (versions unknown) |
| `%LOCALAPPDATA%\Claude`, `claude-cli-nodejs`, `~\.vscode`, `~\.vscode-insiders` | Claude desktop app, Claude Code CLI, VS Code |

### Read-only checks for the user to run before the isolation choice is final

These only print information. They are listed here, not executed by eo.

```powershell
wsl --version
wsl --status
wsl -l -v
docker version
docker info --format "{{.OperatingSystem}} {{.ServerVersion}} {{.Isolation}} {{.SecurityOptions}}"
VBoxManage --version
Get-ComputerInfo -Property WindowsProductName, OsVersion, HyperVRequirementVirtualizationFirmwareEnabled, HyperVisorPresent
git --version; node --version; go version; gh --version
```

## 2. Isolation options compared

The question for each option: if an agent (or code it wrote, run by the tests) is fully hostile, what can it reach?

| Property | Separate low-privilege Windows user | WSL2 distro | Container on Docker Desktop | Local VM (Hyper-V or VirtualBox) | Dedicated Proxmox VM (M8) |
|---|---|---|---|---|---|
| Kernel / boundary | Same Windows kernel, NTFS ACLs | Shared Linux utility VM for **all** distros; runs as the Windows user | Shared Linux VM (`docker-desktop` distro or Hyper-V VM), namespaces + cgroups inside it | Separate guest kernel, hypervisor boundary | Separate guest kernel on a separate physical host |
| Access to the user's files | Blocked for `C:\Users\<you>` by default ACLs; **other drives and folders with `Users`/`Authenticated Users` write ACLs are reachable** | **Full** by default: `/mnt/c` etc. are auto-mounted with the Windows user's rights, including `~\.claude`, `~\.ssh`, `~\.config\gh`, git credential files | None unless bind-mounted; but Docker Desktop shares host drives into its VM, so a container escape reaches them | None unless shared folders, clipboard or drag-and-drop are enabled | None |
| Windows process execution | Can start any program the user account may run | **Yes by default** (interop: `cmd.exe`, `powershell.exe`, any `.exe` on `/mnt/c`) | No, unless escape | No | No |
| Credential exposure | Its own profile only; but Windows Credential Manager, `docker-users` group membership (if added) or shared drive files could leak | Windows credential helpers callable via interop (e.g. git credential manager, `docker-credential-desktop.exe`) | Only what is passed in; Docker Desktop's own credential store stays outside | Only what is placed in the guest | Only what is placed in the guest |
| Network | Same host network and localhost services | Shares host networking (NAT or mirrored); can reach Windows localhost services | Docker networks; can be restricted with an egress proxy and an internal-only network | Guest NIC; NAT/host-only, firewallable | VLAN + firewall, separate from home network |
| Can the agent undo the restriction? | Not without an exploit | **Yes**: `/etc/wsl.conf` (`[interop] enabled=false`, `[automount] enabled=false`) is editable by root in the distro, and the default distro user has sudo | Not without an escape if run non-root, `--cap-drop ALL`, `no-new-privileges`, no Docker socket | Not without a hypervisor escape | Not without a hypervisor escape |
| Strength | Weak–moderate | **Not a security boundary** against the Windows user it runs as | Moderate (good with hardening) | Strong | Strongest |

Conclusions:
- **WSL2 alone is not a sandbox.** Turning off interop and automount in `wsl.conf` is easily reverted by root inside the distro, all distros share one VM, and the Windows-side `%UserProfile%\.wslconfig` is writable by the user's own processes. WSL2 is only acceptable as the *host* for a properly hardened container or as a convenience shell, never as the isolation layer.
- **A separate Windows user** blocks the most sensitive files (the user profile) but leaves shared drives, network and localhost services open. It is acceptable **only for a supervised pilot** on the disposable sample project, with a person watching, no unattended runs, and no credentials other than a dedicated spend-limited API key in that account.
- **Containers on Docker Desktop** are acceptable for local runs only with the hardening in §3, and with no Windows paths bind-mounted. Their weak point is the shared Docker Desktop VM, which has the host drives mounted.
- **A local VM** is the preferred local option. The whole eo runtime (controller + hardened containers for workers and verification) runs inside the guest, which has no shared folders. VS Code connects to it with Remote-SSH, so the chat workflow still works from the Windows desktop. This is the same layout as the Proxmox worker (M8), so the local VM is a development-scale copy of PX.

## 3. Execution tiers

| Tier | Layout | Required controls | Allowed use |
|---|---|---|---|
| **P (supervised pilot)** | Controller as the Windows user; workers and verification as a separate standard (non-admin) local Windows user | Account has no admin rights, no membership in `docker-users`/`Hyper-V Administrators`, no saved credentials; state root ACL denies that account; clones in a folder only that account can write; a person watches the run. **Mechanism:** the user starts a small broker as the pilot account at the start of a session (interactive `runas`, password typed, never saved); the controller talks to it over a named pipe whose ACL admits only the two accounts; the broker starts each worker inside a Windows Job Object with kill-on-job-close, so timeouts kill the whole process tree and the tree dies if the broker dies. If the broker is not running, the pilot tier is unavailable (there is no fallback to running as the user) | Disposable sample project only, short supervised sessions, fake runner or small approved live budgets |
| **L1 (local container)** | Controller on Windows or in WSL2; workers and verification in Docker Desktop containers | Non-root user in image; `--cap-drop ALL`; `--security-opt no-new-privileges`; read-only root filesystem with `tmpfs` for scratch; clone delivered via a named volume (no Windows bind mounts); no Docker socket; `--pids-limit`, memory and CPU limits; internal network with an allowlisting egress proxy | Sample project and approved repositories, attended runs |
| **L2 (local VM), preferred** | Hyper-V or VirtualBox guest (Linux) running controller + L1-style containers (rootless Podman or Docker inside the guest) | No shared folders, clipboard or drag-and-drop; NAT network with guest firewall egress allowlist; snapshot before each run; VS Code Remote-SSH from the host with a key only for that guest | Approved repositories; attended or unattended runs |
| **PX (Proxmox)** | As L2 on a dedicated Proxmox node | As L2, plus isolated VLAN and host firewall | Unattended scheduled runs (M8) |

Which of Hyper-V and VirtualBox to use for L2 is decided after the read-only checks in §1. Building any of these is an installation step and waits for approval.

## 4. GitHub credentials and ref restrictions

**Correction to the first draft:** GitHub deploy keys cannot be limited to branches. A write-enabled deploy key can push to every branch and tag of its repository. Fine-grained personal access tokens and GitHub App tokens are also repository-scoped, not branch-scoped. Branch restrictions must come from **repository rulesets**, which GitHub enforces server-side on every push, whatever the credential.

Design:
1. **Before M8 nothing pushes automatically.** Locally, the controller works against a bare mirror in the state root and holds no GitHub credentials. Publishing branches is a command the user runs (`eo publish`), using the user's own credentials, and it pushes only `eo/*` refs.
2. **Unattended runs push to a separate staging repository**, never to the real repository. The write deploy key exists only for that staging repository, so the blast radius of a stolen key is the staging repository. The user moves results into the real repository through a normal pull request.
3. **Only the controller holds the key.** It lives in the controller's state root inside the L2/PX guest, outside every container; nothing inside the isolation boundary can read it or reach an SSH agent holding it. Workers never push. M8-6 includes a probe from inside a worker container for the key file, the agent socket and outbound SSH to github.com.
4. **Rulesets on the staging repository** (rulesets are available on public repositories on every plan, and on private repositories with GitHub Pro, Team or Enterprise Cloud). A ruleset targets either branches or tags, so three are needed:
   - Ruleset A1 (branch ruleset), target: all branches **except** `eo/**`. Rules: restrict creations, restrict updates, restrict deletions, block force pushes.
   - Ruleset A2 (tag ruleset), target: all tags. Rules: restrict creations, restrict updates, restrict deletions.
   - Ruleset B (branch ruleset), target: `eo/**`. Rules: restrict deletions, block force pushes.
   - Bypass lists contain only the repository admin role (the human). No deploy key is in any bypass list (GitHub allows deploy keys there, so this is checked from the exported ruleset JSON).
5. **What rulesets don't cover.** A key holder can still fast-forward any `eo/**` branch, including `eo/<epic>/integration` and `eo/<epic>/status`, and can push other ref namespaces and `.github/workflows` files. So: the staging repository has **GitHub Actions disabled** (pushed workflows can't run); nothing reads staging branches back as trusted input (the controller's own mirror is the source of truth, and the human reviews staging content as untrusted); M8-6 also attempts a push to `refs/notes/x` and a custom ref and records the result; the human-side PR into the real repository is the review point for anything pushed.
6. **Real repository:** a ruleset protecting the default branch (require a pull request, block force pushes and deletions) is recommended for the user to enable. eo never needs write access to it.
7. **Tested, not assumed.** M8 acceptance tests use the controller's staging credential to attempt: push to `main`, create a non-`eo/` branch, create a tag, force-push an `eo/` branch, delete an `eo/` branch, and a normal push to a new `eo/` branch. Only the last may succeed; the GitHub rejection output of every other attempt is stored as evidence.

Note: `Rockhelljumper/Engineering-Orchestrator` is public. Evidence bundles and the sample project committed there are public too, so evidence must never contain secrets. The controller redacts environment values and stores only variable names.

## 5. Spend limits: what Claude Code does and does not guarantee

- `--max-budget-usd` is a **client-side, cumulative check**. Claude Code adds up the cost it estimates per turn and stops once the total exceeds the cap, so a run can end **above** the cap. That the check happens only between turns (a running turn always finishes) is the third-party author's hypothesis, not confirmed from source; M2-6b measures it. One third-party test reported a run with a $0.01 cap finishing at about $0.084 after a single turn, with result subtype `error_max_budget_usd` (linuxjedi.co.uk, "When the docs fall short: investigating Claude Code's budget cap"; a single, uncorroborated observation, re-measured in M2).
- `total_cost_usd` and token usage in the JSON result are Claude Code's **estimate**, not the provider's invoice. Under a subscription login the dollar figure is notional.
- **Neither is a hard billing limit.** The only provider-side backstop is a spend limit configured on the Anthropic Console organisation or workspace that owns the API key the workers use. Its exact enforcement timing is the provider's, so eo treats it as a backstop, not as the control.

What eo enforces itself:
1. A per-epic and per-task cap in the budget governor, checked **before** each launch against `spent + reserved`. The overshoot behaves like roughly one turn's cost rather than a ratio of the cap, so each launch reserves `cap + maxTurnCost`, where `maxTurnCost` is the largest single-turn cost measured in M2-6b at realistic context sizes, plus margin. Until measured, the reservation is `max(10 × cap, cap + $1)`, above the 8.4× already observed.
2. A per-invocation wall-clock timeout that kills the process tree, bounding overshoot independently of cost reporting.
3. Token caps as well as dollar caps, using the reported usage fields.
4. Unattended tiers use a dedicated API key whose workspace has a Console spend limit set at or below the epic cap. M8 cannot start without the user confirming that setting.
5. The ledger is reconciled against the Console usage report after each live milestone. This is a manual check by the user, recorded as informational, not as a pass/fail criterion.
