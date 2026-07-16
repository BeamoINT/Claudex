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
| `CLAUDEX_MAX_RETRIES` | `15` | Integer from 0 through 15; the default covers the local bridge recovery window |
| `CLAUDEX_CONTEXT_WINDOW` | `400000` | Integer from 100000 through 1000000 |
| `CLAUDEX_AUTO_COMPACT_WINDOW` | `280000` | Integer from 100000 through the context window |
| `CLAUDEX_PLAN_MODE_POLICY` | `conservative` | `conservative` or `normal` |
| `CLAUDEX_MOUSE_POINTER_SHAPE` | `pointer` | `pointer`, `default`, or `off` |
| `CLAUDEX_CHROME_CONFIG_DIR` | normal Claude profile | Optional dedicated first-party Claude profile |
| `CLAUDEX_SKILL_BRIDGE` | `on` | `on` discovers existing Claude and Codex skills; `off` disables the compatibility overlay |
| `CLAUDEX_SKILL_PLUGINS` | `on` | Include enabled Claude and Codex plugin skills in discovery |
| `CLAUDEX_SKILL_DOLLAR_REFERENCES` | `on` | Resolve Codex-style `$skill` references through the isolated compatibility hook |
| `CLAUDEX_CLAUDE_CONFIG_DIR` | `~/.claude` | Normal Claude profile whose personal skills and legacy commands should be shared |
| `CLAUDEX_SKILL_EXTRA_DIRS` | unset | OS path-list of additional Agent Skills roots |
| `CLAUDEX_CODEX_ADMIN_SKILLS_DIR` | platform admin root | Override Codex's admin skill directory |
| `CLAUDEX_NODE_BIN` | managed automatically | Private verified Node.js runtime path on legacy Linux distributions |

The concurrency values are Claudex safeguards, not promises that an upstream
account will always accept that many simultaneous requests. Lower them when an
account or provider has tighter capacity.

For proxied sessions, Claudex hides Claude Code's Anthropic-only 1M model
variant and uses `CLAUDEX_CONTEXT_WINDOW` plus the managed compaction boundary
instead. Direct `--claude-chrome` and maintenance commands do not inherit that
override.

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

The status line detects the available terminal width and removes the usage,
effort, and finally excess model detail as space becomes tight. This keeps the
footer on one row while preserving the model and context percentage whenever
they fit.

## Authentication and local proxy

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDEX_PROXY_URL` | `http://127.0.0.1:8318` | Local compatibility endpoint |
| `CLAUDEX_ALLOW_REMOTE_PROXY` | `0` | Set to `1` only to allow an explicitly configured HTTPS remote proxy |
| `CLAUDEX_PROXY_TOKEN` | generated during install | Local service authentication key |
| `CLAUDEX_PROXY_CONFIG` | `<config>/cliproxyapi.yaml` | Generated service config |
| `CLAUDEX_PROXY_BIN` | installed managed binary | Compatibility executable path |
| `CLAUDEX_CODEX_AUTH_DIR` | `<config>/codex-accounts` | Private bridge credential directory |
| `CLAUDEX_CODEX_SOURCE_AUTH_FILE` | `$CODEX_HOME/auth.json` | Standard Codex source credential |
| `CLAUDEX_CODEX_AUTH_FILE` | automatic | Explicit credential for advanced usage selection |
| `CLAUDEX_DISABLE_INTERACTIVE_LOGIN` | `0` | Set to `1` to keep foreground startup browser-free and require an explicit `claudex --login` |

Claudex rejects non-loopback proxy URLs before sending credentials. A reviewed
remote deployment requires both an HTTPS URL and
`CLAUDEX_ALLOW_REMOTE_PROXY=1`; automatic local process recovery is disabled
for remote endpoints. Never share or commit `CLAUDEX_PROXY_TOKEN` or any Codex credential.
The generated config performs three bounded retries for transient upstream 5xx
responses plus two pre-stream bootstrap retries, with short cooldowns so a
recovered blip does not flash as a user-facing API error.

## Updates

| Variable | Default | Accepted values or purpose |
| --- | --- | --- |
| `CLAUDEX_AUTO_UPDATE` | `on` | `on` applies stable Claudex releases, `notify` only checks, `off` disables checks |
| `CLAUDEX_UPDATE_INTERVAL_SECONDS` | `86400` | 3600 through 2592000 |
| `CLAUDEX_CLAUDE_AUTO_UPDATE` | `on` | `on` or `off` |
| `CLAUDEX_CLAUDE_UPDATE_INTERVAL_SECONDS` | `86400` | 3600 through 2592000 |
| `CLAUDEX_SKIP_CLAUDE_UPDATE` | unset | Set to `1` to skip the install-time Claude update |

Claudex and Claude Code use separate non-blocking update state and stale-lock
recovery guards. Failed or offline Claudex checks stay quiet in the background
and use bounded exponential backoff. Inspect or control the stable channel with
`claudex self-update --status`, `--check`, or `--apply`. Package installations
delegate updates to their recorded package manager without `sudo`; archive and
source installations accept only checksum-matched stable GitHub release assets.
An explicit `claudex update` remains Claude Code's native update command.

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
| `~/.config/claudex/skill-bridge.cjs` | Cross-platform skill discovery and compatibility helper |
| `~/.config/claudex/skill-bridge` | Content-addressed, rebuildable views of existing Claude and Codex skills |
| `~/.config/claudex/skills/usage-limit` | Bundled platform-native `/usage-limit` skill |
| `~/.config/claudex/codex-accounts` | Mode-restricted local credential bridge |
| `~/.config/claudex/usage-cache` | Sanitized usage values only |
| `~/.config/claudex/statusline-cache` | Per-session context percentages |
| `~/.config/claudex/backups` | Private transaction generations containing previous managed files, including env and proxy config, from successful reinstalls |

Run `claudex --doctor` after changing configuration. Invalid values fail fast
with the accepted range or enum.
