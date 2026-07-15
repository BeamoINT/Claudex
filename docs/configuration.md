# Configuration

The installer writes private runtime configuration to
`~/.config/claudex/env` on every platform. Edit that file to persist supported
overrides, then start a new Claudex session. The repository's `env.example`
shows the most common values.

Do not commit the installed `env` file. It contains a generated local proxy
key.

## Core runtime

| Variable | Default | Accepted values or purpose |
| --- | --- | --- |
| `CLAUDEX_CONFIG_DIR` | `~/.config/claudex` | Private config and state root |
| `CLAUDEX_SETTINGS_FILE` | `<config>/settings.json` | Alternate Claude settings file |
| `CLAUDEX_MODEL` | `gpt-5.6-sol` | Default model ID |
| `CLAUDEX_PERMISSION_MODE` | `auto` | `manual`, `auto`, `acceptEdits`, `dontAsk`, or `plan` |
| `CLAUDEX_AUTO_MODE_MODEL` | `gpt-5.6-terra` | Auto-mode classifier model; restricted to managed Codex GPT models |
| `CLAUDEX_BACKGROUND_MODEL` | `gpt-5.6-luna` | Background classifier model |
| `CLAUDEX_SUBAGENT_MODEL` | `gpt-5.6-terra` | Default delegated model |
| `CLAUDEX_MAX_TOOL_USE_CONCURRENCY` | `3` | Positive integer |
| `CLAUDEX_MAX_AGENT_CONCURRENCY` | `3` | Positive integer |
| `CLAUDEX_MAX_RETRIES` | `4` | Integer from 0 through 15 |
| `CLAUDEX_CONTEXT_WINDOW` | `400000` | Integer from 100000 through 1000000 |
| `CLAUDEX_AUTO_COMPACT_WINDOW` | `280000` | Integer from 100000 through the context window |
| `CLAUDEX_PLAN_MODE_POLICY` | `conservative` | `conservative` or `normal` |
| `CLAUDEX_MOUSE_POINTER_SHAPE` | `pointer` | `pointer`, `default`, or `off` |
| `CLAUDEX_CHROME_CONFIG_DIR` | normal Claude profile | Optional dedicated first-party Claude profile |

The concurrency values are Claudex safeguards, not promises that an upstream
account will always accept that many simultaneous requests. Lower them when an
account or provider has tighter capacity.

## Usage-limit display

| Variable | Default | Accepted values or purpose |
| --- | --- | --- |
| `CLAUDEX_USAGE_DISPLAY` | `on` | `on` or `off` |
| `CLAUDEX_USAGE_REFRESH_SECONDS` | `300` | 60 through 3600 |
| `CLAUDEX_USAGE_TIMEOUT_SECONDS` | `8` | 1 through 30 |
| `CLAUDEX_USAGE_MAX_STALE_SECONDS` | `86400` | Refresh interval through 604800 |
| `CLAUDEX_USAGE_ALERT_PERCENT` | `20` | 0 through 100; 0 disables warnings |
| `CLAUDEX_USAGE_SOURCE` | `auto` | `auto`, `web`, or `app-server` |
| `CLAUDEX_USAGE_URL` | ChatGPT usage endpoint | Advanced web-source override |

`auto` first reads the authenticated web usage endpoint and falls back to
Codex app-server's `account/rateLimits/read` interface. The app-server fallback
is disabled while a specific bridge account is selected because that process
may represent a different account.

## Authentication and local proxy

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDEX_PROXY_URL` | `http://127.0.0.1:8318` | Local compatibility endpoint |
| `CLAUDEX_PROXY_TOKEN` | generated during install | Local service authentication key |
| `CLAUDEX_PROXY_CONFIG` | `<config>/cliproxyapi.yaml` | Generated service config |
| `CLAUDEX_PROXY_BIN` | installed managed binary | Compatibility executable path |
| `CLAUDEX_CODEX_AUTH_DIR` | `<config>/codex-accounts` | Private bridge credential directory |
| `CLAUDEX_CODEX_SOURCE_AUTH_FILE` | `$CODEX_HOME/auth.json` | Standard Codex source credential |
| `CLAUDEX_CODEX_AUTH_FILE` | automatic | Explicit credential for advanced usage selection |

Do not point the proxy at a non-loopback address without a separate security
review. Never share or commit `CLAUDEX_PROXY_TOKEN` or any Codex credential.

## Updates

| Variable | Default | Accepted values or purpose |
| --- | --- | --- |
| `CLAUDEX_CLAUDE_AUTO_UPDATE` | `on` | `on` or `off` |
| `CLAUDEX_CLAUDE_UPDATE_INTERVAL_SECONDS` | `86400` | 3600 through 2592000 |
| `CLAUDEX_SKIP_CLAUDE_UPDATE` | unset | Set to `1` to skip the install-time Claude update |

The runtime update check is non-blocking and uses a stale-lock recovery guard.
An explicit `claudex update` never races the background check.

## Installer-only overrides

These are primarily for packaging, CI, and advanced installations:

| Variable | Purpose |
| --- | --- |
| `CLAUDEX_BIN_DIR` | Alternate launcher installation directory |
| `CLAUDEX_PROXY_PORT` | Alternate generated loopback port |
| `CLAUDEX_SKIP_DEPENDENCY_INSTALL=1` | Skip dependency download and installation |
| `CLAUDEX_SKIP_SERVICE_START=1` | Install files without starting or verifying the service |

`CLAUDEX_SKIP_DEPENDENCY_INSTALL` and `CLAUDEX_SKIP_SERVICE_START` are intended
for controlled test or packaging environments. Ordinary users should not set
them.

Variables containing `CLAUDEX_TEST_`, `CLAUDEX_SESSION_MODE`,
`CLAUDEX_MODEL_MODE`, and helper binary overrides are internal implementation
details and are not a stable public interface.

## Installed files

| Path | Contents |
| --- | --- |
| `~/.local/bin/claudex` | Unix launcher |
| `~/.local/bin/claudex.ps1` and `claudex.cmd` | Windows launchers |
| `~/.config/claudex/env` | Private environment config and generated key |
| `~/.config/claudex/settings.json` | Isolated Claude Code settings |
| `~/.config/claudex/codex-accounts` | Mode-restricted local credential bridge |
| `~/.config/claudex/usage-cache` | Sanitized usage values only |
| `~/.config/claudex/statusline-cache` | Per-session context percentages |
| `~/.config/claudex/backups` | Previous managed files from reinstalls |

Run `claudex --doctor` after changing configuration. Invalid values fail fast
with the accepted range or enum.
