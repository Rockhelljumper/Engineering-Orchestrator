# 00 — Environment inspection

Inspection date: 2026-10-18. Everything here was observed read-only; nothing was installed or reconfigured.

## 1. Repository

| Item | Observed |
|---|---|
| Repository | `Rockhelljumper/Engineering-Orchestrator` |
| Contents at start | `LICENSE` (MIT) only, one commit `6a60780 Initial commit` |
| Branch protection / CI | None present (no `.github/`) |

The repository is empty, so it is the dedicated repository the brief asks for. No existing application repository is touched by this work.

## 2. Planning environment (cloud container used for this phase)

| Tool | Version | Notes |
|---|---|---|
| OS | Ubuntu 24.04.5 LTS, 4 vCPU, 15 GB RAM | Ephemeral container, not the target host |
| Claude Code CLI | 2.1.302 | Headless flags confirmed present via `claude --help`: `--print`, `--output-format`, `--json-schema`, `--max-budget-usd`, `--tools`, `--allowedTools`, `--disallowedTools`, `--permission-mode` (`acceptEdits, auto, bypassPermissions, manual, dontAsk, plan`), `--permission-prompts`, `--setting-sources`, `--settings`, `--strict-mcp-config`, `--mcp-config`, `--agents`, `--bare`, `--session-id`, `--resume`, `--no-session-persistence`, `-w/--worktree` |
| Node | 22.22.0 | |
| Python | 3.13.16 | |
| Go | 1.24.7 | **Not enough for beads**: beads `go.mod` requires `go 1.26.5` / `toolchain go1.26.7`. With the default `GOTOOLCHAIN=auto` Go would silently download a toolchain, so builds must use a pinned Go 1.26.7 with `GOTOOLCHAIN=local` |
| git | 2.43.0 | Clones and bare mirrors supported |
| Docker CLI | 29.8.2 | **No daemon** (`/var/run/docker.sock` missing). Container isolation cannot be tested here. |
| jq, ripgrep | present | |

`--max-turns` did not appear in `--help` for 2.1.302. The design therefore does not depend on it; turn bounds come from `--max-budget-usd` plus a controller-side wall-clock timeout.

Two further flags matter for isolation and are evaluated in M2:
- `--restricted`: removes Bash/PowerShell/code-running tools and WebFetch unless `--tools` names them, ignores user/project/local settings files (managed settings and `--settings` still apply). Help text notes that settings files failing validation are **silently ignored**.
- `--bare`: skips hooks, plugins, auto-memory, keychain reads and **CLAUDE.md auto-discovery**, but also skips settings hooks (which would remove the guard hook) and needs API-key auth rather than OAuth.

`--setting-sources` covers settings files only; it does not stop a repository's `CLAUDE.md` being loaded.

## 3. User workstation (observed through the linked desktop app)

| Item | Observed |
|---|---|
| Device | `rh-dt-m3`, Windows (win32 x64) |
| Editors | `.vscode`, `.vscode-insiders`, `.cursor` present in the home folder |
| Other agent tooling | `.codex`, `.copilot` folders present |
| Toolchains | `.cargo`, `.rustup`, `.dotnet`, `go`, `.gradle`, `.pnpm-store`, `npm-cache` |
| Virtualisation | `.VirtualBox`, `VirtualBox VMs` |
| Folders shared with this session | none |

Only folder names were visible (home folder, `Program Files`, `Program Files (x86)`, `%LOCALAPPDATA%`). No folder contents were read, no command was run and no access was requested. See `07-isolation-and-credentials.md` §1 for what those names suggest about isolation tooling; versions and enabled state remain unverified.

Consequences for the design:

1. The orchestrator must run on **Windows natively** for the interactive VS Code workflow. That rules out designs that need tmux (Oh My ClaudeCode team mode) on the host.
2. The unattended tier runs on **Linux** (L2 local VM or PX Proxmox VM, with workers in containers inside the guest), so the controller must be cross-platform: Node/TypeScript with no shell-specific glue.
3. Paths, process control (no POSIX signals on Windows) and file locking must be handled portably.

## 4. Proxmox

No Proxmox host is reachable from here and no details were supplied. Requirement 10 is designed for (see architecture §9 and milestone M8) but cannot be validated until the user provides a host and approves the VM template.

## 5. Open questions for the user

1. Results of the read-only checks in `07-isolation-and-credentials.md` §1 (WSL, Docker Desktop backend, Hyper-V, VirtualBox versions).
2. Proxmox: version, whether a dedicated non-production node or VLAN is available, and the staging repository for unattended pushes (`07` §4). These can wait until M8.
3. Which local isolation tier to build first. A follow-up read-only listing found Docker Desktop, WSL, Hyper-V and VirtualBox folders on the PC; the comparison, the recommendation (a local Linux VM) and the read-only commands that settle the choice are in `07-isolation-and-credentials.md`.
4. Which Claude authentication the unattended worker should use (a dedicated API key whose Console workspace has a spend limit is recommended over the user's personal OAuth login; that limit is a provider-side backstop, not a guaranteed hard cap, `07` §5).
