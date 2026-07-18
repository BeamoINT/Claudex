# Claudex agent guide

This file is the authoritative repository guide for every AI coding agent
working here (Claude Code, Codex, Gemini, Grok, Copilot, and others).
`AGENTS.md` is a deliberate short stub that sends Codex here; keep it a stub.
Do not add mirrored copies of this guide (`GEMINI.md`, `GROK.md`,
`.github/copilot-instructions.md`): this repository is excluded from the
workspace convention of mirrored instruction files, because
`scripts/check-docs.mjs` (part of `npm test` and CI) lints every Markdown file
in the repository and rejects long dashes and hyphenated words in prose, which
that convention's required mirror header contains.

## What this is

Claudex is an open source compatibility layer that lets Codex GPT models and
native Claude models run through the Claude Code terminal interface. Managed
GPT sessions reuse an existing local Codex login, run a pinned, verified
CLIProxyAPI binary bound to `127.0.0.1`, and launch an isolated Claude Code
profile pointed at that proxy. Native Claude model routes use the caller owned
Claude profile in a separate process after managed routing is removed.
Fableplan uses a native read only Fable planner and an isolated managed Terra
implementer, transferring only bounded plan text through a private temporary
file. Claudex does not fork or patch the signed Claude Code executable: it is a
launcher/wrapper, distributed as Bash + PowerShell scripts.

Production code is intentionally dependency light: Bash, PowerShell, a small Node preload module, and JSON. There is no application build step or bundler.

## Commands

```bash
./test.sh                    # full Unix suite (runs test.zsh in an isolated fake home)
./test.ps1                   # full Windows suite (run from PowerShell)
npm test                     # docs, preload, skill bridge/contract/security, package bootstrap and setup lock checks
npm run test:all             # same as ./test.sh
./scripts/build-release.sh   # build release archives (tarball + Windows zip) into dist/
```

Focused checks (fast, no fake home setup) before opening a PR:

```bash
node scripts/check-docs.mjs        # community-file + relative Markdown link validation
node scripts/check-preload.mjs     # preload.cjs integrity
node --check preload.cjs           # Node syntax check
node --check skill-bridge.cjs       # shared skill bridge syntax check
node tests/skill-bridge.test.cjs    # discovery/materialization behavior
node tests/skill-contract.test.cjs  # Claude/Codex compatibility contract
node tests/skill-security.test.cjs  # hostile filesystem/plugin inputs
bash -n claudex codex-session install.sh statusline usage-limit
zsh -n test.zsh
git diff --check
```

There is no single test runner: `test.zsh`/`test.ps1` are one large suite of isolated regressions using fake homes and fake provider commands (Codex, Claude Code, curl, CLIProxyAPI) so tests never touch a real session. To narrow scope while iterating, grep the suite file for the relevant test function name and read it directly; there's no `--filter` flag.

CI (`.github/workflows/test.yml`) runs the Unix suite on macOS + Ubuntu, the PowerShell suite on Windows, and a `package-artifacts` job (`npm test` + `build-release.sh`) on Ubuntu, on every push to `main` and every PR.

## Architecture

### Request flow

```
user -> claudex launcher (Bash or PowerShell)
           |-- managed GPT -> isolated Claude profile -> loopback proxy -> Codex
           |-- native Claude -> scrub managed state -> caller owned Claude profile
           `-- Fableplan -> native Fable plan file -> managed Terra
```

Native Claude and managed GPT processes may run concurrently, but each process
receives one provider environment only. Provider credentials, profiles,
sessions, and billing contexts never cross that boundary.

### Components (Unix / Windows implementations kept behaviorally in sync)

| Component | Unix | Windows | Responsibility |
| --- | --- | --- | --- |
| Launcher | `claudex` | `claudex.ps1`, `claudex.cmd` | Parse Claudex flags, negotiate Claude Code capabilities, configure the session, launch Claude Code |
| Installer | `install.sh` | `install.ps1` | Install dependencies, private config, launchers, verified compatibility binary |
| Auth bridge | `codex-session` | `codex-session.ps1` | Validate Codex login, atomically sync the minimum credential fields |
| Usage helper | `usage-limit` | `usage-limit.ps1` | Fetch, sanitize, cache, and display Codex usage limits |
| Status line | `statusline` | `statusline.ps1` | Render model, effort, stable context %, cached usage status |
| Terminal preload | `preload.cjs` | shared | Translate Solplan input and replace only the positioned interactive welcome billing field before restoring native stdout |
| Skill bridge | `skill-bridge.cjs` | shared | Snapshot and adapt existing Claude/Codex skills and plugin skills without activating source plugin code |
| Settings template | `settings.json` | shared | Isolated default Claude Code settings written into the managed config |

Every shared behavior change must touch both the Bash and PowerShell implementation (`claudex`/`claudex.ps1`, `codex-session`/`codex-session.ps1`, etc.): platform drift is treated as a bug unless the underlying OS genuinely lacks the feature, in which case the boundary must be documented, not silently emulated.

### Authentication lifecycle

Codex owns the actual login/logout UX. Claudex only verifies `codex login status`, reads the file backed ChatGPT session from the standard Codex location, and atomically writes the minimum fields CLIProxyAPI needs into Claudex's private credential directory (restrictive permissions). A background watcher fingerprints the standard Codex credential file for the life of a proxied session and re syncs on account changes, clearing any cached usage snapshot/account selection so stale account data can't leak into the footer. Logout always tears down the bridge even if the upstream logout call fails.

### Usage limit flow

The status line never blocks on network I/O: it reads a sanitized cached summary and triggers a bounded background refresh when stale. Detailed usage comes from the authenticated web endpoint, falling back to the Codex app server `account/rateLimits/read` interface (fallback disabled while a specific bridge account is explicitly selected, since app server may represent a different account). Identity/credential fields are stripped before any snapshot is written to disk.

### Context stabilization

Claude Code can emit zero/missing context data transiently during startup and compaction. The status line stores the last trustworthy context percentage per session and reuses only that session's own last known value: never a false zero, and sub-1% usage renders as `<1%`.

### Update and compatibility strategy

At every launch, `claudex` reads `claude --help` and only injects flags Claude Code actually supports; unrecognized arguments are passed through unchanged. The installer does a best effort Claude Code update; the launcher re checks on a configurable interval without blocking startup, recovers stale lock directories, and avoids racing an explicit update command. The CLIProxyAPI dependency is pinned by version and SHA-256 per OS/arch pair and verified at install time: never vendored into the repo.

### Trust boundaries

- Trusted: repo managed scripts, installed private config, standard Codex credentials, supported CLI flags.
- Loopback boundary: CLIProxyAPI binds `127.0.0.1` only, guarded by a generated local key.
- Provider process boundary: native Claude and managed GPT routing and
  credentials remain in separate processes.
- Fableplan boundary: only bounded validated plan text crosses from the native
  planner to the managed implementer through a private temporary file.
- Third party boundary: Codex, Claude Code, provider APIs, browser extensions, and CLIProxyAPI are separately maintained.
- Public repo boundary: no generated config, auth, prompts, history, sessions, or usage caches are ever committed. `~/.config/claudex` is fully separate from normal Claude Code state.

## Design rules (from docs/development.md: treat as binding)

1. Never modify the signed Claude Code binary.
2. Keep normal Claude Code state separate from `~/.config/claudex`.
3. Let Codex own login and logout.
4. Keep secrets out of arguments, logs, caches, tests, and Git.
5. Bind the compatibility service to loopback only; verify every downloaded asset's SHA-256.
6. Preserve unknown Claude Code arguments exactly (pass through, don't drop or reinterpret).
7. Keep Bash and PowerShell behavior aligned.
8. Fail clearly when an essential upstream interface is unavailable: no silent degradation.
9. Add a regression test before considering a bug fixed.

Updating the CLIProxyAPI pin is security sensitive: collect every macOS/Linux/Windows x64/ARM64 asset from the official upstream release, compute each digest independently, update both installers together, and run the full platform test matrix. Never replace a digest just to make a failed download pass.

## Repository layout

| Path | Purpose |
| --- | --- |
| `claudex`, `claudex.ps1`, `claudex.cmd` | Cross platform launchers |
| `install.sh`, `install.ps1`, `install.zsh` | Install and compatibility entry points |
| `codex-session*` | Authentication bridge |
| `usage-limit*` | Detailed and cached quota reporting |
| `statusline*` | Stable compact footer |
| `preload.cjs` | Byte preserving Solplan input alias and one shot interactive ChatGPT plan label |
| `skill-bridge.cjs`, `skills/` | Existing skill compatibility, isolated plugin adapters, and platform specific bundled skills |
| `settings.json`, `env.example` | Reproducible configuration templates |
| `test.zsh`, `test.ps1`, `test.sh` | Isolated cross platform regression suites |
| `scripts/` | `build-release.sh`, `check-docs.mjs`, `check-preload.mjs` |
| `bin/claudex-package.mjs` | package manager bootstrap entrypoint (Homebrew / Scoop / WinGet) |
| `docs/` | User/maintainer docs: architecture, configuration, development, installation, troubleshooting, usage, compatibility matrix |

## Configuration model

The installer writes private runtime config to `~/.config/claudex/env`; `env.example` documents supported overrides (model aliases, permission mode, concurrency/retry limits, context window/compaction thresholds, usage display cadence, proxy URL/token/binary path, auto update behavior). See `docs/configuration.md` for the full variable table: don't hardcode defaults elsewhere without checking there first, since values like the default model ID or context window change between releases.

## Releasing

Maintainers release from a clean `main` after CI passes: bump `CHANGELOG.md` (Unreleased -> SemVer version, kept in sync with `package.json`), tag `vMAJOR.MINOR.PATCH`, push the tag, publish a GitHub Release, then update the Homebrew tap / Scoop bucket / WinGet manifest with the exact release asset hashes.
