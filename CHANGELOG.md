# Changelog

All notable user-facing changes to Claudex are documented here. The project
uses [Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

## [1.3.1] - 2026-07-15

### Changed

- Shortened visible custom-agent names to `Terra` and `Luna` and standardized
  their task labels as `Model - concise task`, while retaining the managed
  Codex/OpenAI model IDs behind those labels.

### Fixed

- Corrected curl header-file syntax in authenticated proxy health checks. The
  authorization token remains outside the process argument list, and healthy
  bridge sessions no longer produce a false token-rejection error.
- Isolated proxy recovery tests from locally installed Homebrew services and
  added a regression that rejects literal header-file paths without curl's
  required `@` prefix.

## [1.3.0] - 2026-07-15

### Changed

- Made `CLAUDEX_MODEL` the actual default launch route, while keeping explicit
  Sol, Terra, Luna, and Solplan selectors authoritative and rejecting non-Codex
  model IDs before proxy recovery.
- Reconciled auto-mode rules against a private snapshot of Claude Code's prior
  defaults, so upstream permission changes no longer leave obsolete rules
  behind while user-authored rules remain intact.
- Upgraded the verified CLIProxyAPI dependency to 7.2.80 and preserved explicit
  or persisted custom proxy, configuration, and account-directory locations
  during installer repairs.
- Kept terminal and structured output byte-for-byte native. The preload now
  handles only the `/model solplan` input alias and supports split UTF-8,
  bracketed paste, cursor editing, Unicode deletion, and multiple listeners.

### Fixed

- Replaced TCP-only bridge checks with authenticated semantic model-catalog
  checks, hard wall-clock deadlines, safe stale-lock recovery, managed-process
  restart, and bounded diagnostic logs. Hung or unrelated listeners can no
  longer masquerade as a healthy Codex bridge or stretch recovery into minutes.
- Prevented stale quota data from crossing logout or account-switch boundaries,
  stopped obsolete in-flight refreshes from publishing, made refresh locks
  owner-aware, enforced maximum cache age and complete schemas, and included
  code-review and model-specific limits in warnings.
- Removed terminal-output rewriting that could corrupt split UTF-8, JSON,
  stream-JSON, ANSI resets, callback ordering, and the bottom rows of the
  fullscreen interface.
- Made resume guidance append-only and ambiguity-safe, preventing cursor-up row
  erasure and avoiding attribution to another same-directory session.
- Preserved empty, quoted, whitespace-containing, and trailing-backslash native
  arguments on Windows PowerShell 5 launch paths.
- Serialized package-manager first-run repair, recovered abandoned setup locks,
  repaired missing managed files, and avoided overwriting a package manager's
  own command shim.
- Versioned the managed Windows proxy executable so an upgrade does not replace
  a binary that is still running.

## [1.2.0] - 2026-07-15

### Changed

- Upgraded auto-mode classification from Luna to Terra while enforcing that
  auto and background classifiers remain on managed Codex GPT models.
- Added scoped consent rules so a user's explicit approval of a named action
  and target is not discarded after an auto-mode denial, including concise
  approval by reference and exact repository-to-build or deployment transfers.
- Increased client retry tolerance for brief local or upstream API outages.
- Reduced unnecessary questions by making context inspection, safe assumptions,
  and autonomous execution the default for reversible in-scope work.

### Fixed

- Moved bounded transient 5xx and pre-stream retries into the local bridge so
  recovered upstream blips no longer flash as red API errors in Claude Code.
- Prevented intermittent bottom-of-screen corruption by leaving fullscreen TUI
  cursor/redraw frames byte-for-byte native and removing an unsupported terminal
  title control sequence from status-line output.
- Kept the localhost Codex bridge healthy for the lifetime of a session and
  serialized recovery across concurrent Claudex tabs, preventing intermittent
  `ConnectionRefused` failures after a proxy exit.
- Kept the no-BOM encoding object available to native Windows resume-footer
  cleanup even when Claudex is launched outside the test harness.

## [1.1.1] - 2026-07-15

### Fixed

- Replaced Claude Code's native `claude --resume` shutdown instruction after
  interrupted and nonzero exits, while preserving the original exit status.
- Cleared account-scoped usage state before activating switched Codex
  credentials, preventing stale quota data from appearing for the new account.

## [1.1.0] - 2026-07-15

### Added

- First-run package-manager bootstrap with automatic managed-file upgrades.
- Public npm packaging under `claudex-codex` with the `claudex` executable.
- Homebrew, Scoop, and WinGet distribution metadata and documentation.
- Versioned `.tar.gz` and Windows `.zip` release artifacts with SHA-256 sums.
- Release-asset automation and package-content validation in CI.

### Fixed

- Friendly model names in Claude Code's secondary footer without leaked SGR
  fragments such as `[1m`.
- Clear Codex rate-limit guidance instead of internal credential-pool cooldown
  messages when model access is exhausted.
- Reliable `claudex --resume` shutdown guidance even when agent or concurrent
  session logs are updated at the same time.
- Live Codex Desktop and CLI account-change detection, atomic bridge refresh,
  and automatic invalidation of account-scoped usage state.

## [1.0.0] - 2026-07-15

### Added

- MIT licensing and complete open-source community documentation.
- Contributor, conduct, support, security, and governance policies.
- Structured bug report, feature request, and pull request templates.
- User, configuration, architecture, troubleshooting, and development guides.
- Zero-configuration installers for macOS, Linux, WSL, and native Windows.
- Codex authentication synchronization and local compatibility service.
- GPT-5.6 Sol, Terra, Luna, and Solplan model integration.
- Auto mode, max effort, Ultracode, bounded agents, and task reconciliation.
- 400k context reporting and automatic compaction around 280k tokens.
- Usage-limit status, low-quota alerts, and safe account selection.
- Claude in Chrome first-party profile support.
- Cross-platform regression coverage in GitHub Actions.

[Unreleased]: https://github.com/BeamoINT/Claudex/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/BeamoINT/Claudex/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/BeamoINT/Claudex/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/BeamoINT/Claudex/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/BeamoINT/Claudex/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BeamoINT/Claudex/releases/tag/v1.0.0
