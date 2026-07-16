# Architecture

Claudex is a launcher and compatibility layer. It does not fork or patch the
signed Claude Code executable.

## Request flow

```text
User
  |
  v
claudex launcher (Bash or PowerShell)
  |-- validates config and Claude Code capabilities
  |-- synchronizes Codex auth through codex-session
  |-- injects model aliases, limits, agents, and status settings
  v
Claude Code terminal UI
  |
  v
CLIProxyAPI on 127.0.0.1:8318
  |
  v
authenticated Codex account
```

The preload module runs inside Claude Code's JavaScript runtime only for Claudex
sessions backed by GPT models. It translates the exact `/model solplan` input alias
and performs one width preserving replacement of Claude Code's hardcoded
startup billing field with the account bound ChatGPT plan label. The native
stdout writer is restored before the next fullscreen frame; stderr, print
output, and machine output are never intercepted. Direct Claude in Chrome
sessions do not receive that preload or the GPT proxy environment.

## Components

| Component | Unix | Windows | Responsibility |
| --- | --- | --- | --- |
| Launcher | `claudex` | `claudex.ps1`, `claudex.cmd` | Parse Claudex flags, negotiate Claude capabilities, configure the session, and launch Claude Code |
| Installer | `install.sh` | `install.ps1` | Install dependencies, private config, launchers, and verified compatibility binary |
| Auth bridge | `codex-session` | `codex-session.ps1` | Validate Codex login and atomically synchronize the minimum credential fields |
| Usage helper | `usage-limit` | `usage-limit.ps1` | Fetch, sanitize, cache, and display usage limits |
| Status line | `statusline` | `statusline.ps1` | Render model, effort, stable context, and cached usage status |
| Terminal preload | `preload.cjs` | shared | Translate Solplan input and replace only the interactive startup billing field without modifying Claude Code or machine output |
| Skill bridge | `skill-bridge.cjs` | shared | Discover existing Claude and Codex skills, preserve project scope, adapt provider specific policy/model metadata, and build an immutable private overlay |
| Settings template | `settings.json` | shared | Provide isolated default Claude Code settings |

## Authentication lifecycle

1. Codex owns the user facing login flow.
2. Claudex verifies `codex login status`.
3. A file backed ChatGPT session is read from the standard Codex location.
4. The minimum fields needed by CLIProxyAPI are written atomically into
   Claudex's private credential directory with restrictive permissions.
5. A newer source refresh, different account, disabled bridge, or expired
   bridge causes a replacement.
6. While a proxied Claudex session is open, a lightweight watcher fingerprints
   the standard Codex credential file. A Codex Desktop or CLI account change is
   synchronized atomically without exposing token contents.
7. An account change clears the explicit usage account selection and sanitized
   quota cache so data from the previous account cannot appear in the footer.
8. Logout always removes the bridge, even if the upstream logout command fails.

Claudex never places an OAuth token in process arguments or intended terminal
output. The repository contains no credentials.

## Usage limit flow

The status line never blocks on a network request. It reads a sanitized summary
and starts a bounded background refresh when needed. Detailed usage can come
from the authenticated web endpoint or Codex app server. Before a snapshot is
written, identity and credential fields are removed. Account selection clears
the prior snapshot.

## Context stabilization

Claude Code can briefly emit zero or missing context data during startup and
compaction. The status line stores the last trustworthy percentage per session
and uses it only for that same session. Real sub percent usage is shown as
`<1%`; a new session with no trustworthy data omits the percentage instead of
showing a false zero.

## Update and compatibility strategy

The installer performs a best effort Claude Code update. The launcher checks
again on a configurable interval without blocking startup, recovers stale lock
directories, and avoids racing explicit update commands. At every launch,
Claudex reads `claude --help` and injects optional switches only when supported.
Unknown arguments are forwarded exactly.

Before an ordinary GPT backed launch, the shared skill bridge discovers native
Claude personal skills, Codex personal and project skills, legacy locations,
admin skills, and enabled plugin skills. It creates immutable, content hashed
snapshots under the private Claudex configuration and injects standalone skills
with `--add-dir`. Validated plugin skills are rebuilt as inert generated
plugins and injected with `--plugin-dir`; the original plugin's hooks, MCP
servers, agents, and other executable components are not loaded. A separate
generated hook resolves explicit Codex `$skill` references without making
manual only skills implicitly invocable. Original skill and plugin trees are
read only inputs. Direct Chrome, safe, bare, and maintenance flows do not
receive the overlay.

For the lifetime of each proxied session, a lightweight watcher checks the
loopback listener without generating API traffic. If CLIProxyAPI exits, one
session acquires a shared startup lock and restores it while other open tabs
wait for the same healthy listener instead of launching competing processes.

The compatibility binary is pinned by version and SHA-256 for every supported
operating system and architecture pair. Changing that pin requires verifying
all asset digests and running the full platform matrix.

## Trust boundaries

- **Trusted local inputs:** repository managed scripts, installed private
  configuration, standard Codex credentials, and supported command line flags.
- **Loopback boundary:** CLIProxyAPI binds to `127.0.0.1` and requires a random
  local key.
- **Third party boundary:** Codex, Claude Code, provider APIs, browser
  extensions, and CLIProxyAPI remain separately maintained software and
  services.
- **Public repository boundary:** no generated config, auth, prompts, history,
  sessions, or usage caches belong in Git.

See [SECURITY.md](../SECURITY.md) for reporting and supported versions.
