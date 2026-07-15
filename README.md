# Claudex

Download-and-run compatibility layer for using the Codex GPT-5.6 model family inside Claude Code on macOS, Linux, and Windows. Claudex reuses the login already managed by the Codex desktop app or CLI; it never asks users to copy OAuth tokens or configure a provider manually.

## What this config provides

- GPT-5.6 Sol as the leader and default model
- GPT-5.6 Terra for implementation and deep subagents
- GPT-5.6 Luna for auto-mode safety classification, background work, and fast subagents
- GPT-5.6 Solplan in `/model`: Sol while plan mode is active and Terra while implementing
- a clean `/model` picker with exactly one Solplan, Sol, Terra, and Luna entry
- auto mode enabled by default
- first-class max effort (`--max-effort`) and session-scoped Ultracode (`--ultracode`) without conflating the two modes
- three concurrent tools and a guarded maximum of three active agents
- transparent delegated-agent names that match the real model: `gpt-5-6-terra` and `gpt-5-6-luna`
- Sol-owned task lifecycle with immediate agent-result reconciliation and no stale `in_progress` entries at final handoff
- bounded retries to prevent 429 retry storms
- 400k context accounting with automatic compaction around 280k tokens
- session-scoped context stabilization that never flashes a misleading `0%` during startup or compaction refreshes
- live Codex plan limits in the status line, refreshed asynchronously every five minutes without blocking the UI
- `/usage-limit` inside Claudex and `claudex --usage-limit` in the shell for detailed percentages, reset times, and reset credits
- configurable low-capacity warnings, a safe multi-account usage picker, and automatic fallback to Codex app-server's documented `account/rateLimits/read` interface
- full-screen rendering that hides the shell launch command while Claudex is open
- friendly model names, no-flicker rendering, a native terminal cursor, a normal mouse pointer, and a compact status line
- removal of Claude Code's hardcoded `API Usage Billing` welcome label without modifying the signed Claude binary
- resume hints rewritten to `claudex --resume <session>` so resumed work stays on the same Codex-backed path
- automatic Codex login synchronization with clear logged-out recovery through `claudex --login`
- daily non-blocking Claude Code update checks plus runtime capability detection for new Claude Code releases
- conservative plan-mode tuning that implements concrete requests directly and reserves plan mode for explicit plans or material decisions
- a separate `~/.config/claudex` state directory that does not modify normal Claude Code settings
- transparent passthrough for Claude Code's MCP, plugin, agent, auth, update, resume, worktree, IDE, remote-control, safe-mode, bare-mode, and Chrome switches

## Supported platforms

| Platform | Launcher | Installer | Status |
| --- | --- | --- | --- |
| macOS 13+ (Intel and Apple silicon) | Bash | `install.sh` | Fully supported |
| Ubuntu 20.04+, Debian 10+, and compatible Linux (x64/ARM64) | Bash | `install.sh` | Fully supported |
| Windows 10 1809+, Windows 11, and Windows Server 2019+ (x64/ARM64) | PowerShell | `install.ps1` | Fully supported |
| WSL 1/2 | Bash | `install.sh` | Supported as Linux |

The model UI, stabilized status line, auto mode, compaction, task/agent policy, banner cleanup, and local proxy behavior are shared across platforms. Claude Code itself currently supports sandboxing on macOS, Linux, and WSL2; its native Windows build does not currently provide sandboxing. That upstream difference is not something Claudex can safely emulate.

## Zero-configuration installation

Prerequisites are Codex and Claude Code. Sign into Codex normally in the desktop app or with `codex login`; the CLI and supported local Codex surfaces share the cached session. Download the repository ZIP or clone it, then run one installer. Claudex automatically:

1. verifies the Codex login;
2. securely synchronizes the refreshable local session without printing credentials;
3. installs its checksum-verified internal compatibility service on a dedicated localhost port;
4. creates all private configuration and launcher files;
5. updates Claude Code and verifies the live models.

No provider URL, API key, proxy login, or model mapping needs to be entered.

### macOS or Linux

```bash
git clone https://github.com/BeamoINT/Claudex.git
cd Claudex
./install.sh --login
```

`--login` is optional when `codex login status` already succeeds and `~/.codex/auth.json` is available. It opens Codex's official sign-in flow and requests file-backed local credential storage when the OS keyring does not expose a reusable session. The installer adds `jq` automatically when needed and installs an isolated, checksum-verified compatibility binary; users do not configure or operate that internal service.

If `~/.local/bin` is not already on `PATH`, add it to your Bash or Zsh profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### Windows

Run PowerShell from the cloned repository:

```powershell
git clone https://github.com/BeamoINT/Claudex.git
Set-Location Claudex
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Login
```

The native Windows installer adds `~\.local\bin` to the user `PATH`, creates the same private Codex-session bridge, and uses native PowerShell tooling. Git Bash is not required.

If somebody logs out of Codex, Claudex immediately clears its managed bridge session and prints the recovery command instead of repeatedly failing API requests:

```text
claudex --login
```

## Updating an existing machine

macOS or Linux:

```bash
git pull --ff-only
./install.sh
```

Windows:

```powershell
git pull --ff-only
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Existing private credentials are preserved. Replaced launchers and settings are backed up under `~/.config/claudex/backups/` on every platform. The old `./install.zsh` entry point remains as a compatibility shim on macOS.

## Usage

The commands are the same in Bash, Zsh, PowerShell, and Command Prompt:

```text
claudex                 # Sol leader, auto mode
claudex --terra         # start on Terra
claudex --luna          # start on Luna
claudex --solplan       # Sol in plan mode, Terra while implementing
claudex --manual        # disable auto permissions for this launch
claudex --max-effort    # native maximum reasoning effort for this session
claudex --ultracode     # xhigh effort plus dynamic workflow orchestration
claudex --claude-chrome # direct Anthropic profile with Claude in Chrome enabled
claudex --doctor        # verify proxy, models, and configuration
claudex --auth-status   # verify the shared Codex login
claudex --login         # open official Codex login and synchronize it
claudex --logout        # log out Codex and clear Claudex's bridge session
claudex --usage-limit   # refresh and print Codex plan limits
claudex --accounts      # list available Codex usage accounts
claudex --account 2     # select an account by number, email, or auth filename
claudex --account auto  # return to newest-credential selection
```

Inside `/model`, choose **GPT-5.6 Solplan** or enter `/model solplan`. Claudex registers that friendly name against Claude Code's built-in `opusplan` selector: the Opus family alias maps to GPT-5.6 Sol during plan mode, and the Sonnet family alias maps to GPT-5.6 Terra for execution. It does not force every task into plan mode; the user can explicitly activate plan mode when a separate planning phase is useful.

`--max-effort` and `--ultracode` are intentionally separate. Max effort passes Claude Code's native `--effort max`. Ultracode enables the session-only `ultracode` and `workflows` settings and uses xhigh reasoning, matching Claude Code's own implementation. Explicit `--effort` or `--settings` flags are rejected when combined with either shortcut so a later argument cannot silently disable the requested mode.

Claudex forwards unrecognized Claude Code options and subcommands. It does not inject its leader prompt, custom agents, or permission mode into `--bare`, `--safe-mode`, or maintenance commands such as `mcp`, `plugin`, `auth`, `update`, and `doctor`. At launch it reads the installed Claude Code capability list and only injects supported optional switches. Claude Code's own updater is checked in the background every 24 hours by default, while installation performs an immediate update check. See the [Claude Code compatibility audit](docs/claude-code-compatibility.md) for the tested feature matrix and upstream boundaries.

## Claude in Chrome

Anthropic requires Chrome or Edge, Claude in Chrome extension 1.0.36 or later, and a direct Anthropic Pro, Max, Team, or Enterprise plan. Anthropic explicitly does not support Claude in Chrome through third-party model providers. For that reason, `claudex --chrome` remains a transparent GPT-backed pass-through for environments where it works, while `claudex --claude-chrome` uses the normal first-party Claude profile and automatically adds `--chrome`. The latter is the supported, predictable integration path and does not alter the isolated Claudex profile.

The first direct launch may ask you to sign in to Claude Code. The browser extension and native messaging host are then reused normally. Chrome and Edge are supported on macOS, Linux, and native Windows; Anthropic does not support this integration in WSL or in Brave, Arc, and other Chromium browsers.

Inside an active Claudex session, run `/usage-limit` for the same detailed report. The compact footer uses the account authenticated through CLIProxyAPI and shows remaining capacity, such as `Codex 5h 74% left · 7d 61% left`. Refreshes happen in the background, use short network timeouts, and retain a sanitized cache for temporary network outages. The cache contains plan and quota values only—never account identity or OAuth credentials.

Optional usage controls are `CLAUDEX_USAGE_DISPLAY=on|off`, `CLAUDEX_USAGE_REFRESH_SECONDS` (60–3600, default 300), `CLAUDEX_USAGE_TIMEOUT_SECONDS` (1–30, default 8), `CLAUDEX_USAGE_MAX_STALE_SECONDS` (default 86400), `CLAUDEX_USAGE_ALERT_PERCENT` (0–100, default 20; 0 disables), and `CLAUDEX_USAGE_SOURCE=auto|web|app-server` (default `auto`).

In auto source mode, Claudex first uses the Codex session synchronized from the normal Codex credential store. If that usage endpoint changes or is unavailable, it starts the local Codex app-server with a bounded timeout, completes the documented initialization handshake, and calls `account/rateLimits/read`. Selecting a specific bridge account disables app-server fallback for that request because app-server could be authenticated as a different account; stale cached data is safer than silently showing the wrong identity's limits. The multi-account selection file is private and stores only the chosen auth filename. The sanitized quota cache never stores email, account ID, or tokens.

## Testing

macOS and Linux:

```bash
./test.sh
```

Windows:

```powershell
.\test.ps1
```

GitHub Actions runs the isolated suite on `macos-latest`, `ubuntu-latest`, and `windows-latest`. Tests use temporary homes and fake proxy commands; they do not access live credentials or Claude sessions.

## Security and backup boundary

This repository intentionally excludes API keys, OAuth credentials, sessions, prompts, history, telemetry, usage data, caches, and machine-generated Claude state. Claudex validates login through the documented `codex login status` command, reads the standard file-backed Codex session locally, and writes a minimal mode-restricted bridge copy only when the Codex account or refresh timestamp changes. Logging out removes that copy. Credentials never enter command-line arguments, logs, status output, Git, or the sanitized quota cache. Fresh installs generate a random 256-bit local service key and bind the dedicated service to `127.0.0.1:8318`. Downloaded binaries are pinned to release v7.2.77 and checked against upstream SHA-256 digests before installation.

Never commit a real token, especially because this repository is public. Only reproducible configuration and installer code belong here.
