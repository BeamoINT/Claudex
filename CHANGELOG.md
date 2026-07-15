# Changelog

All notable user-facing changes to Claudex are documented here. The project
uses [Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

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

[Unreleased]: https://github.com/BeamoINT/Claudex/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/BeamoINT/Claudex/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/BeamoINT/Claudex/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/BeamoINT/Claudex/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BeamoINT/Claudex/releases/tag/v1.0.0
