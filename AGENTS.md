# Claudex agent guide

`AGENTS.md` is the sole project instruction file for every coding agent.
Read `.ai/memory/MEMORY.md` only when prior context is relevant.
`scripts/check-docs.mjs` checks all Markdown for long dashes and hyphenated prose.

## CI, cost and documentation

When present, read `~/dev/AGENTS.md` for workspace rules. This guide also applies
to standalone checkouts. Follow the repository's mandated CI provider; otherwise
prefer verified free Cloud Build, then CodeBuild, then Blacksmith. Include shared
usage, machine, logging, storage and network costs with headroom; never reduce
verification or security to save cost. Keep one document per topic and link detail.

- Iterate locally; run the applicable full local gate before release. Hosted
  CI is only for necessary final public/customer production verification,
  do not manually trigger it for routine work, draft PRs, previews or unshipped
  instruction/doc maintenance. Authorized PRs/pushes still require their automatic
  checks; never disable or bypass them. Local scripts named `ci` remain local;
  do not push merely to trigger CI.
- Run the fewest required hosted jobs. Reuse only evidence for the exact final
  SHA, artifacts and config; revalidate after changes. Fix every candidate/gate
  failure and material warning, then rerun until all applicable checks pass.
  Pending, canceled, blocked, timed out and unexpected skips are not passes;
  path skips require workflow evidence. Never weaken tests/coverage or retry blindly.
- Check automatic triggers and gate publication on successful verification.
  Preserve required statuses, branch protection, scheduled security/ops checks,
  native acceptance and approvals; record proof and verify after deployment.
  No hosted CI means retain local/manual gates. Changes to automation or
  publication need task authority. Avoid duplicate providers/runs.

**Project gate:** For instruction maintenance, run `node scripts/check-docs.mjs` locally. For
public launcher/installer releases, finish applicable Unix/PowerShell and npm
checks, then require the final platform, minimum Node, legacy Linux and archive
matrix plus applicable security gates. Tags can trigger release publication;
use the existing gated release flow and exact asset hashes for downstream
manifests. Do not manually repeat the matrix for ordinary development.

## What this is

Claudex runs Codex GPT and native Claude models through the Claude Code terminal interface without modifying its signed binary. GPT uses existing Codex login, a pinned/verified CLIProxyAPI bound to `127.0.0.1` and isolated Claude profile; native Claude uses the caller profile in a separate process after managed routing is removed. Fableplan passes bounded plan text through a private temporary file from a native read only Fable planner to an isolated managed Terra implementer. Distribution: Bash + PowerShell wrappers.

Runtime: Bash, PowerShell, one Node preload and JSON; no bundler or application build.

## Commands

```bash
./test.sh                    # full Unix suite (targeted regressions, then test.zsh in an isolated fake home)
./test.ps1                   # full Windows suite (run from PowerShell)
npm test                     # docs, preload, skill bridge/contract/security, package bootstrap and setup lock checks
npm run test:all             # same as ./test.sh
./scripts/build-release.sh   # build release archives (tarball + Windows zip) into dist/
```

Focused checks (fast, no fake home setup) before opening a PR:

```bash
node scripts/check-docs.mjs        # community files, Markdown prose lint (dashes/hyphens), links, CHANGELOG, workflow pinning
node scripts/check-preload.mjs     # preload.cjs integrity
node --check preload.cjs           # Node syntax check
node --check skill-bridge.cjs      # shared skill bridge syntax check
node tests/skill-bridge.test.cjs   # discovery/materialization behavior
node tests/skill-contract.test.cjs # Claude/Codex compatibility contract
node tests/skill-security.test.cjs # hostile filesystem/plugin inputs
bash -n claudex codex-session install.sh statusline usage-limit
bash -n test.zsh
git diff --check
```

`test.zsh`/`test.ps1` are isolated suites using fake homes/providers, never real sessions. For focused work, read the relevant function directly; no `--filter` exists.

CI (`.github/workflows/test.yml`) runs on every push to `main` and every PR:
the Unix suite on macOS + Ubuntu, the PowerShell suite on Windows, plus three
Ubuntu jobs: `package-artifacts` (package metadata and reproducible archive
checks), `node-18-shared-runtime` (`npm test` on the minimum supported Node),
and `legacy-linux-node` (managed Node fallback in an Ubuntu 20.04 container).
Current runner selection and its cost exception are in `docs/development.md`.

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
| Self update | `self-update` | `self-update.ps1` | Check GitHub releases and refresh the installed Claudex, lock guarded |
| Terminal preload | `preload.cjs` | shared | Translate Solplan input and replace only the positioned interactive welcome billing field before restoring native stdout |
| Skill bridge | `skill-bridge.cjs` | shared | Snapshot and adapt existing Claude/Codex skills and plugin skills without activating source plugin code |
| Settings template | `settings.json` | shared | Isolated default Claude Code settings written into the managed config |

Shared changes must update both Unix and Windows: `claudex`/`claudex.ps1`, `codex-session`/`codex-session.ps1`, etc. Platform drift is a bug; document genuine OS limitations instead of emulating silently.

### Authentication lifecycle

Codex owns login/logout. Claudex checks `codex login status` and atomically copies only required session fields into a private credential directory with restrictive permissions. A watcher fingerprints Codex credentials throughout a proxied session, resyncs on account changes and clears cached usage/account selection. Logout tears down the bridge even if upstream logout fails.

### Usage limit flow

The status line reads a sanitized cache and starts bounded background refresh, never blocking on network I/O. Detailed usage prefers the authenticated web endpoint, then Codex app server `account/rateLimits/read`; disable fallback while a bridge account is selected to avoid another account's data. Strip identity/credentials before persisting snapshots.

### Context stabilization

Cache the last trustworthy context percentage per session through transient zero/missing startup or compaction data. Never invent zero or share sessions; values below 1% display `<1%`.

### Update and compatibility strategy

At launch, read `claude --help`, inject only supported flags and pass unknown arguments unchanged. Install/update Claude Code on a best effort basis; bounded configurable checks must not block startup or race explicit updates, and stale locks must recover. `claudex self-update` runs its helper; the launcher checks it in the background unless `CLAUDEX_AUTO_UPDATE` is off. CLIProxyAPI stays version/SHA-256 pinned for every OS/arch, verified at install and never vendored.

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

For CLIProxyAPI pin updates, fetch all official macOS/Linux/Windows x64/ARM64 assets, independently hash them, update both installers and pass the full platform matrix. Never replace a digest to conceal a bad download.

## Repository layout

| Path | Purpose |
| --- | --- |
| `claudex`, `claudex.ps1`, `claudex.cmd` | Cross platform launchers |
| `install.sh`, `install.ps1`, `install.zsh` | Install and compatibility entry points |
| `bootstrap.sh`, `bootstrap.ps1` | One command installers: fetch and verify the latest release, then run the platform installer |
| `codex-session*` | Authentication bridge |
| `usage-limit*` | Detailed and cached quota reporting |
| `statusline*` | Stable compact footer |
| `self-update`, `self-update.ps1` | Claudex self update helpers (GitHub release check, lock guarded refresh) |
| `preload.cjs` | Byte preserving Solplan input alias and one shot interactive ChatGPT plan label |
| `skill-bridge.cjs`, `skills/` | Existing skill compatibility, isolated plugin adapters, and platform specific bundled skills |
| `settings.json`, `env.example` | Reproducible configuration templates |
| `test.zsh`, `test.ps1`, `test.sh`, `tests/` | Isolated cross platform regression suites plus targeted helper suites and Node tests |
| `scripts/` | `build-release.sh`, `check-docs.mjs`, `check-preload.mjs`, `check-release-artifacts.sh`, `create-release-archives.mjs` |
| `bin/`, `claudex-package.cmd` | Package manager bootstrap entrypoint (Homebrew / Scoop / WinGet) plus the package setup lock helper |
| `docs/` | User/maintainer docs: architecture, Claude Code compatibility, configuration, development, installation, package managers, skills, troubleshooting, usage |

## Configuration model

Private config: `~/.config/claudex/env`; `env.example` documents model, permission, retry/concurrency, context, usage, proxy and update overrides. Check `docs/configuration.md` before reusing defaults or model IDs.

## Releasing

Release clean `main` after CI passes: align `CHANGELOG.md` and `package.json`, turn Unreleased into SemVer, tag/push `vMAJOR.MINOR.PATCH`, publish GitHub Release, then update Homebrew/Scoop/WinGet with exact asset hashes.

<!-- BEGIN BEAMO UNFINISHED WORK -->
## Unfinished work

- Read the project's unfinished work record at task start. Use its existing
  canonical backlog, or `.ai/memory/unfinished-work.md` if none exists; link
  the record from `.ai/memory/MEMORY.md` when creating it. Chat is not storage.
- Always save every incomplete requested item, deferred issue, blocked check
  and pending merge/release step as they arise and before ending, pausing,
  handing off or changing tasks. Checkpoint after meaningful progress.
- Each item needs an ID/status, remaining acceptance criteria, exact next
  action, blockers/required approval, date/author, repo/branch/commit/worktree
  and relevant files or links. Separate completed checks and their evidence
  from failed, skipped and unrun checks; distinguish local, pushed and deployed
  state. Preserve partial source work without staging another agent's changes.
- Resume from the record, recheck current source and evidence, and update or
  mark items done only when their acceptance criteria pass. Record reasons for
  canceled/superseded items. Preserve useful history and others' entries; reread
  before editing and append separate items when concurrent work would overwrite
  them.
- Never store credentials or raw personal/customer records. Notes do not grant
  approval or prove deployment. If project writing is blocked, save a durable
  workspace handoff with the exact project/ref, record the blocker, and report
  its location before stopping; do not silently lose unfinished work.
<!-- END BEAMO UNFINISHED WORK -->

<!-- BEGIN BEAMO STORAGE HYGIENE -->
## Storage

- For work generating >1 GiB, run `/Users/HP/dev/storage-maintenance --report`
  before/after and follow `/Users/HP/dev/STORAGE_HYGIENE.md`.
- Stage under `$TMPDIR` or `/private/tmp`; clean up normally or register verified
  staging outside Git with `storage-maintenance --register PATH --ttl-days 3`.
  Keep hashes/URLs/versions/receipts instead of duplicate binaries.
- Remove only clean, merged worktrees through Git; preserve dirty/unmerged work
  and history. Under pressure, remove only reproducible dependencies from them.
- Preserve others' work, browser profiles (Chrome/Google), Zoom, app databases,
  Docker volumes, cloud drive and personal data. No cleanup daemons or installs
  from the orphaned home `package.json`.
<!-- END BEAMO STORAGE HYGIENE -->
