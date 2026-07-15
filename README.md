# Claudex setup

Private, portable setup for running Claude Code through a local CLIProxyAPI-backed GPT-5.6 model family on macOS, Linux, and Windows.

## What this config provides

- GPT-5.6 Sol as the leader and default model
- GPT-5.6 Terra for implementation and deep subagents
- GPT-5.6 Luna for auto-mode safety classification, background work, and fast subagents
- a clean `/model` picker with exactly one Sol, Terra, and Luna entry
- auto mode enabled by default
- three concurrent tools and a guarded maximum of three active agents
- transparent delegated-agent names that match the real model: `gpt-5-6-terra` and `gpt-5-6-luna`
- Sol-owned task lifecycle with immediate agent-result reconciliation and no stale `in_progress` entries at final handoff
- bounded retries to prevent 429 retry storms
- 400k context accounting with automatic compaction around 280k tokens
- session-scoped context stabilization that never flashes a misleading `0%` during startup or compaction refreshes
- live Codex plan limits in the status line, refreshed asynchronously every five minutes without blocking the UI
- `/usage-limit` inside Claudex and `claudex --usage-limit` in the shell for detailed percentages, reset times, and reset credits
- full-screen rendering that hides the shell launch command while Claudex is open
- friendly model names, no-flicker rendering, a native terminal cursor, a normal mouse pointer, and a compact status line
- removal of Claude Code's hardcoded `API Usage Billing` welcome label without modifying the signed Claude binary
- a separate `~/.config/claudex` state directory that does not modify normal Claude Code settings

## Supported platforms

| Platform | Launcher | Installer | Status |
| --- | --- | --- | --- |
| macOS 13+ (Intel and Apple silicon) | Bash | `install.sh` | Fully supported |
| Ubuntu 20.04+, Debian 10+, and compatible Linux (x64/ARM64) | Bash | `install.sh` | Fully supported |
| Windows 10 1809+, Windows 11, and Windows Server 2019+ (x64/ARM64) | PowerShell | `install.ps1` | Fully supported |
| WSL 1/2 | Bash | `install.sh` | Supported as Linux |

The model UI, stabilized status line, auto mode, compaction, task/agent policy, banner cleanup, and local proxy behavior are shared across platforms. Claude Code itself currently supports sandboxing on macOS, Linux, and WSL2; its native Windows build does not currently provide sandboxing. That upstream difference is not something Claudex can safely emulate.

## New macOS or Linux installation

```bash
git clone https://github.com/BeamoINT/Claudex.git
cd Claudex
./install.sh --login
```

The installer adds `jq` with a supported package manager if needed, installs Claude Code with Anthropic's native installer when it is absent, and installs a checksum-verified CLIProxyAPI v7.2.77 binary when no existing proxy is available. Existing Homebrew CLIProxyAPI installs continue to use their current service and configuration.

If `~/.local/bin` is not already on `PATH`, add it to your Bash or Zsh profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## New Windows installation

Run PowerShell from the cloned repository:

```powershell
git clone https://github.com/BeamoINT/Claudex.git
Set-Location Claudex
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Login
```

The native Windows installer adds `~\.local\bin` to the user `PATH`, installs Claude Code when needed, downloads the checksum-verified x64 or ARM64 CLIProxyAPI release, creates a private local-only proxy configuration, performs Codex OAuth login, and runs the same doctor checks as macOS/Linux. Claudex explicitly selects Claude Code's PowerShell tool integration on native Windows; Git Bash is not required.

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
claudex --manual        # disable auto permissions for this launch
claudex --doctor        # verify proxy, models, and configuration
claudex --usage-limit   # refresh and print Codex plan limits
```

Inside an active Claudex session, run `/usage-limit` for the same detailed report. The compact footer uses the account authenticated through CLIProxyAPI and shows remaining capacity, such as `Codex 5h 74% left · 7d 61% left`. Refreshes happen in the background, use short network timeouts, and retain a sanitized cache for temporary network outages. The cache contains plan and quota values only—never account identity or OAuth credentials.

Optional usage controls are `CLAUDEX_USAGE_DISPLAY=on|off`, `CLAUDEX_USAGE_REFRESH_SECONDS` (60–3600, default 300), `CLAUDEX_USAGE_TIMEOUT_SECONDS` (1–30, default 8), and `CLAUDEX_USAGE_MAX_STALE_SECONDS` (default 86400). Set `CLAUDEX_CODEX_AUTH_FILE` only when a multi-account CLIProxyAPI installation needs an explicit account selection; otherwise Claudex follows the most recently refreshed Codex credential.

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

This repository intentionally excludes API keys, OAuth credentials, sessions, prompts, history, telemetry, usage data, caches, and machine-generated Claude state. Usage requests go directly to OpenAI over HTTPS with the existing CLIProxyAPI OAuth credential, keep that credential out of process arguments, and write only sanitized quota fields to a mode-restricted local cache. Fresh installs generate a random 256-bit local proxy key and bind the proxy to `127.0.0.1`. Downloaded proxy binaries are pinned to release v7.2.77 and checked against upstream SHA-256 digests before installation.

Never commit a real token, even to this private repository. Only reproducible configuration and installer code belong here.
