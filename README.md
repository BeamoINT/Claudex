# Claudex setup

Private, portable backup of the Claudex launcher used to run Claude Code through a local CLIProxyAPI-backed GPT-5.6 model family.

## What this config provides

- GPT-5.6 Sol as the leader and default model
- GPT-5.6 Terra for implementation and deep subagents
- GPT-5.6 Luna for auto-mode safety classification, background work, and fast subagents
- auto mode enabled by default
- three concurrent tools and a guarded maximum of three active agents
- bounded retries to prevent 429 retry storms
- 400k context accounting with automatic compaction around 280k tokens
- full-screen terminal rendering, friendly model names, a normal mouse pointer, and a compact status line
- a separate `~/.config/claudex` state directory that does not modify normal Claude Code settings

## New Mac installation

Prerequisites are macOS, Homebrew, GitHub CLI access to this private repository, and Claude Code's `claude` command.

```zsh
git clone https://github.com/BeamoINT/claudex-setup.git
cd claudex-setup
./install.zsh --login
```

The installer adds missing `jq` and `cliproxyapi` Homebrew packages, performs the Codex OAuth login when `--login` is supplied, discovers the local CLIProxyAPI key without printing it, installs the launcher, starts the proxy service, and runs `claudex --doctor`.

If `~/.local/bin` is not already on `PATH`, add this to `~/.zshrc`:

```zsh
export PATH="$HOME/.local/bin:$PATH"
```

## Updating an existing machine

```zsh
git pull --ff-only
./install.zsh
```

Existing private `~/.config/claudex/env` credentials are preserved. Replaced launcher and settings files are backed up under `~/.config/claudex/backups/`.

## Usage

```zsh
claudex                 # Sol leader, auto mode
claudex --terra         # start on Terra
claudex --luna          # start on Luna
claudex --manual        # disable auto permissions for this launch
claudex --doctor        # verify proxy, models, and configuration
```

## Testing

```zsh
./test.zsh
```

The test suite uses an isolated temporary home and fake proxy commands. It does not access or alter live credentials or Claude sessions.

## Security and backup boundary

This repository intentionally excludes API keys, OAuth credentials, sessions, prompts, history, telemetry, usage data, caches, and machine-generated Claude state. Those files should never be committed, even to a private repository. Only reproducible configuration and installer code belong here.
