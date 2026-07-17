# Changelog

All notable user facing changes to Claudex are documented here. The project
uses [Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

## [1.5.9] - 2026-07-16

### Added

- Kept authentication and proxy recovery watchers active for detached Claude
  Code background agents until the managed agent registry becomes empty.
- Added deterministic release archive generation with canonical gzip, tar, ZIP,
  line ending, permission, ordering, and timestamp metadata on every host.
- Added adversarial cross platform coverage for signals, process groups,
  concurrent state writers, prior release lock formats, private environments,
  installer rollback journals, and extracted release installations.

### Changed

- Made worktree skill discovery global only while retaining personal, managed,
  system, and installed plugin skills without importing the source repository.
- Improved Claude and Codex skill adaptation for nested commands, manifest
  discovery, policy precedence, TOML arrays and inline tables, quoted model
  metadata, collision aliases, and policy bound fallback generations.
- Made packaged launchers preserve interactive terminal job control while
  isolating noninteractive descendants and forwarding terminal signals.

### Fixed

- Prevented ABA races, PID reuse errors, stale owner theft, incomplete
  publication loss, and mixed release corruption in proxy startup, automatic
  updates, self updates, Codex session synchronization, usage refreshes, and
  other private state writers on Unix and Windows.
- Preserved Codex file credential lifecycle behavior, fractional refresh time
  ordering, exact account projection, and destructive session serialization
  without changing native Codex commands.
- Preserved native Claude provider, hosted, Chrome, remote control, debug,
  positional prompt, delimiter, model, and global flag semantics while keeping
  managed provider state isolated.
- Prevented update and status refresh helpers, plus unrelated Windows child
  processes, from inheriting proxy credentials, provider routing, or managed
  session secrets.
- Hardened terminal status text against OSC, CSI, C1, bidi, and semantic label
  injection while preserving benign Unicode and Claudex owned styling.
- Made source installers fail closed from deleted working directories, protect
  private directories and ACLs, canonicalize relative roots, sanitize journals,
  and roll back paths containing newlines or tabs safely.
- Made package bootstrap wrappers propagate normal and signal exits, resize and
  job control events, and descendant cleanup without orphaning processes.
- Fixed deterministic release checks for quoted checkout paths, CRLF source
  trees, Windows execute bits, source links, unsupported files, and untracked
  release directory contents.

## [1.5.8] - 2026-07-16

### Fixed

- Preserved the native Claude Code `--` delimiter through the PowerShell host
  process and exercised it through the installed launcher's process boundary.
- Preferred sibling PowerShell shims for Windows Claude and Codex launchers so
  long managed arguments do not hit the batch command length ceiling.
- Kept empty Windows launcher argument collections as arrays so proxy recovery
  and zero argument entry points remain valid under strict mode.

## [1.5.7] - 2026-07-16

### Fixed

- Preserved native Claude Code global flags such as `--verbose` on Windows by
  keeping them outside PowerShell's common parameter binder.

## [1.5.6] - 2026-07-16

### Fixed

- Cleared inherited managed session credentials and routing state before
  maintenance commands reach Claude Code on Windows, macOS, and Linux while
  preserving caller owned Bun options.

## [1.5.5] - 2026-07-16

### Fixed

- Updated the Windows command boundary regression to verify decoded argument
  slots, preserving exact command arguments without treating required batch
  quoting as part of an argument value.

## [1.5.4] - 2026-07-16

### Added

- Added explicit `claudex codex` and `claudex claude` routes so harness specific
  policy, plugins, MCP, sessions, tools, and output protocols remain available
  without unsafe cross protocol emulation.
- Added a bounded, immutable Codex `AGENTS.md` instruction bridge alongside the
  existing Claude and Codex skill compatibility overlay.

### Changed

- Preserved Claude Code's native per agent model routing, explicit model
  selection, literal arguments after `--`, restricted tool surfaces, and
  no session persistence behavior.
- Adjusted the injected capacity guidance so explicitly requested native Agent
  Teams remain permitted without claiming to implement or emulate that
  upstream runtime.
- Replaced broad compatibility claims with a tested native/translated/
  pass through capability matrix and documented harness boundaries.
- Rechecked the documented command surfaces with live safe `--help` and
  `--version` probes against Claude Code 2.1.211 and Codex CLI 0.144.4.
- Reworked repository prose and injected agent guidance to use plain punctuation
  and open compounds while preserving required command, file, URL, and schema
  syntax.

### Fixed

- Fixed direct Claude/Chrome environment leakage, Windows watcher output,
  typed credential validation, mutable auth snapshot races, usage refresh lock
  ownership, and native PowerShell shim exit code propagation.
- Fixed skill snapshots that could include credential stores, remap nested
  model metadata, or import malformed plugin manifests.
- Fixed Codex bundled/system skills being omitted from Claudex discovery and
  bounded `$skill` expansion to Claude Code's direct hook context limit.

### Security

- Pinned authenticated usage refreshes to the exact official HTTPS ChatGPT
  endpoint before loading credentials; test overrides are loopback only.

## [1.5.3] - 2026-07-16

### Added

- Added code ownership, maintainer and roadmap documentation, a dedicated
  documentation issue form, component aware pull request labeling, Dependabot,
  dependency review, and CodeQL scanning for a clearer and safer contributor
  workflow.
- Added public triage targets, label guidance, contribution discovery links,
  responsible AI assisted contribution expectations, security response targets,
  and a good faith research safe harbor policy.

### Changed

- Expanded repository governance, support expectations, contributor recognition,
  and maintainer release policy while keeping the project lightweight and
  volunteer friendly.

### Security

- Replaced ambiguous YAML plain scalar comment stripping with bounded linear
  parsing so a large imported skill cannot stall startup with polynomial regex
  backtracking.

## [1.5.1] - 2026-07-16

### Added

- Added transactional, retrying source installers with automatic Node.js 22,
  Claude Code, and Codex CLI provisioning, explicit Codex browser login, safe
  crash recovery, and rollback on interrupted upgrades across Unix and Windows.
- Added deterministic, type safe release archives, an immutable draft first
  publication workflow, full cross platform tag gates, and automatic live
  website installer verification after every successful release.
- Added generation fenced package bootstrap locking so simultaneous first runs
  share one verified result without stale lock takeovers or retry storms.

### Changed

- Made auto mode honor explicit, scoped user authorization after a soft policy
  denial, ask fewer questions, stay in execution mode for routine work, and
  keep all leader, classifier, and subagent paths on Codex/OpenAI models.
- Hardened Claude Code and Codex skill compatibility with complete file secret
  screening, policy bound last known good generations, structural self heal,
  collision safe aliases, bounded garbage collection, and fresh diagnostics.
- Added `Fable` model remapping and consistent `Terra (high)` / `Luna (medium)`
  activity labels on both Bash and PowerShell launchers.
- Restricted remote proxy use to explicit HTTPS opt in while preserving
  automatic recovery for Claudex's managed local proxy.

### Fixed

- Fixed intermittent `ConnectionRefused` and repeated API warning loops by
  recovering stale local authentication once, cleaning failed proxy children,
  and avoiding unsafe retries against user managed or remote proxies.
- Fixed Codex usage refresh hangs, orphaned app server processes, unbounded
  output drains, refresh lock races, stale cache buildup, and noisy `/dev/tty`
  errors; plan labels and cached usage now degrade cleanly under failure.
- Fixed split terminal writes that could leave `API Usage Billing`, `/opus 1m`,
  duplicated status lines, or broken bottom of screen UI visible.
- Fixed launch from a deleted working directory, ignored `CLAUDEX_NODE_BIN`,
  shell metacharacter handling on Windows, and self update shell edge cases.
- Fixed package setup failure propagation, accidental npm publication risk,
  generated release documentation scanning, and inaccurate WinGet availability
  claims.

## [1.5.0] - 2026-07-16

### Added

- Added automatic, non destructive compatibility for existing Claude Code and
  Codex skills: personal and project roots, legacy Claude commands and Codex
  homes, admin skills, enabled plugins, support assets, disabled skill policy,
  deterministic collision aliases, and `/skill` plus `$skill` references.
- Added `claudex skills` diagnostics and a shared content addressed bridge used
  identically by the Bash and PowerShell launchers.
- Added isolated plugin adapters that preserve plugin namespaces without
  activating source hooks, MCP servers, agents, or other plugin runtime code;
  skills directory plugins and direct legacy plugin commands are adapted into
  inert namespaced skills.

### Changed

- Remap explicit Claude skill model family pins to Sol, Terra, or Luna so
  imported skills, including `[1m]` selectors, remain on Codex/OpenAI models.
- Preserve Claude's four `skillOverrides` visibility states and plugin
  `defaultEnabled` policy in the isolated compatibility view.
- Install a native PowerShell version of `/usage-limit` on Windows while
  retaining the Bash version on macOS, Linux, and WSL.
- Require Node.js 18 or newer for the shared skill runtime, with automatic,
  rollback safe dependency migration for existing archive installations.

### Security

- Snapshot imported skills into bounded immutable generations, reject escaping
  links, special files, credentials, and private key material, and fall back to
  the last known good generation if a concurrent source refresh cannot finish.

## [1.4.5] - 2026-07-15

### Fixed

- Kept the one shot welcome plan filter active across Claude Code's separate
  alternate screen prelude and banner writes. The real embedded Bun renderer
  now shows the detected ChatGPT plan before native stdout is restored.

## [1.4.4] - 2026-07-15

### Changed

- Added each managed subagent's configured reasoning effort to its native
  activity name: `Terra (high)` and `Luna (medium)`.

### Fixed

- Replaced Claude Code's misleading `API Usage Billing` welcome field with the
  detected account bound ChatGPT plan, including Free, Go, Plus, Pro, Business,
  Enterprise, Edu, and other current workspace tiers.
- Limited the welcome field compatibility shim to one positioned startup write,
  restored native stdout immediately afterward, and retained byte for byte
  machine output and fullscreen rendering for all subsequent writes.

## [1.4.3] - 2026-07-15

### Removed

- Discontinued the unpublished `claudex-codex` npm distribution: the npm
  publish workflow, the npm self update path, and every npm install
  instruction. Homebrew, Scoop, and the verified source installers are the
  supported channels; WinGet remains unavailable until its community manifest
  passes validation and review.

## [1.4.2] - 2026-07-15

### Fixed

- Fixed a Windows PowerShell parser error in the self updater's bounded native
  process argument construction.

## [1.4.1] - 2026-07-15

### Fixed

- Fixed a fresh Windows install failure caused by npm's PowerShell shim
  re evaluating a strict mode scoped prefix instead of receiving its value.
- Added clean runner verification for the public macOS, Linux, and Windows
  website installers.

## [1.4.0] - 2026-07-15

### Added

- Added verified one command source bootstraps for macOS, Linux, WSL, and
  Windows. They resolve the latest stable GitHub release, validate SHA-256 and
  archive paths, and then run the release's native installer.
- Added a production self updater with automatic background updates by default,
  explicit check/apply/status commands, stable version and downgrade guards,
  package manager delegation, safe staging, rollback, backoff, and install
  provenance on both Unix and Windows.
- Added prerequisite setup for missing Claude Code, Codex CLI, Node.js, and npm.
  Interactive installs and foreground launches open Codex's official browser
  sign in when required, while noninteractive, CI, and watcher paths remain
  prompt free.

### Changed

- Made auto mode honor explicit consent for a narrowly scoped transfer of
  task required source to a named private build or deployment host, while
  keeping secrets, public destinations, broader trees, and agent selected
  targets hard blocked.
- Increased transient retry tolerance and slowed semantic bridge monitoring to
  reduce noisy connection failures without hiding persistent faults.
- Kept the fewer question execution policy active even when callers provide
  their own subagent definitions.
- Disabled Claude Code's Anthropic only Opus 1M selector in proxied sessions;
  all normal Claudex routes continue to use managed Codex/OpenAI models.

### Fixed

- Prevented narrow terminals from wrapping or corrupting the bottom status row
  by progressively eliding optional status details to fit the available width.
- Reconciled every auto mode rule category with upstream defaults instead of
  shipping partial arrays that could replace Claude Code's current rules.
- Fixed custom authentication directory installation, managed proxy port
  migration, concurrent installer runs, and package manager launcher ownership.
- Fixed first run Claude Code discovery on Windows and restored inherited
  model selector environment state after every Claudex session.
- Avoided misclassifying npm packages installed below `/opt/homebrew` as a
  Homebrew formula, which could send future updates through the wrong manager.
- Strengthened byte level terminal regressions for split UTF-8, typed array
  views, JSON output, callbacks, and fullscreen ANSI frames.

## [1.3.1] - 2026-07-15

### Changed

- Shortened visible custom agent names to `Terra` and `Luna` and standardized
  their task labels as `Model - concise task`, while retaining the managed
  Codex/OpenAI model IDs behind those labels.

### Fixed

- Corrected curl header file syntax in authenticated proxy health checks. The
  authorization token remains outside the process argument list, and healthy
  bridge sessions no longer produce a false token rejection error.
- Isolated proxy recovery tests from locally installed Homebrew services and
  added a regression that rejects literal header file paths without curl's
  required `@` prefix.

## [1.3.0] - 2026-07-15

### Changed

- Made `CLAUDEX_MODEL` the actual default launch route, while keeping explicit
  Sol, Terra, Luna, and Solplan selectors authoritative and rejecting non Codex
  model IDs before proxy recovery.
- Reconciled auto mode rules against a private snapshot of Claude Code's prior
  defaults, so upstream permission changes no longer leave obsolete rules
  behind while user authored rules remain intact.
- Upgraded the verified CLIProxyAPI dependency to 7.2.80 and preserved explicit
  or persisted custom proxy, configuration, and account directory locations
  during installer repairs.
- Kept terminal and structured output byte for byte native. The preload now
  handles only the `/model solplan` input alias and supports split UTF-8,
  bracketed paste, cursor editing, Unicode deletion, and multiple listeners.

### Fixed

- Replaced TCP only bridge checks with authenticated semantic model catalog
  checks, hard wall clock deadlines, safe stale lock recovery, managed process
  restart, and bounded diagnostic logs. Hung or unrelated listeners can no
  longer masquerade as a healthy Codex bridge or stretch recovery into minutes.
- Prevented stale quota data from crossing logout or account switch boundaries,
  stopped obsolete in flight refreshes from publishing, made refresh locks
  owner aware, enforced maximum cache age and complete schemas, and included
  code review and model specific limits in warnings.
- Removed terminal output rewriting that could corrupt split UTF-8, JSON,
  stream JSON, ANSI resets, callback ordering, and the bottom rows of the
  fullscreen interface.
- Made resume guidance append only and ambiguity safe, preventing cursor up row
  erasure and avoiding attribution to another same directory session.
- Preserved empty, quoted, whitespace containing, and trailing backslash native
  arguments on Windows PowerShell 5 launch paths.
- Serialized package manager first run repair, recovered abandoned setup locks,
  repaired missing managed files, and avoided overwriting a package manager's
  own command shim.
- Versioned the managed Windows proxy executable so an upgrade does not replace
  a binary that is still running.

## [1.2.0] - 2026-07-15

### Changed

- Upgraded auto mode classification from Luna to Terra while enforcing that
  auto and background classifiers remain on managed Codex GPT models.
- Added scoped consent rules so a user's explicit approval of a named action
  and target is not discarded after an auto mode denial, including concise
  approval by reference and exact repository to build or deployment transfers.
- Increased client retry tolerance for brief local or upstream API outages.
- Reduced unnecessary questions by making context inspection, safe assumptions,
  and autonomous execution the default for reversible in scope work.

### Fixed

- Moved bounded transient 5xx and pre stream retries into the local bridge so
  recovered upstream blips no longer flash as red API errors in Claude Code.
- Prevented intermittent bottom of screen corruption by leaving fullscreen TUI
  cursor/redraw frames byte for byte native and removing an unsupported terminal
  title control sequence from status line output.
- Kept the localhost Codex bridge healthy for the lifetime of a session and
  serialized recovery across concurrent Claudex tabs, preventing intermittent
  `ConnectionRefused` failures after a proxy exit.
- Kept the no BOM encoding object available to native Windows resume footer
  cleanup even when Claudex is launched outside the test harness.

## [1.1.1] - 2026-07-15

### Fixed

- Replaced Claude Code's native `claude --resume` shutdown instruction after
  interrupted and nonzero exits, while preserving the original exit status.
- Cleared account scoped usage state before activating switched Codex
  credentials, preventing stale quota data from appearing for the new account.

## [1.1.0] - 2026-07-15

### Added

- First run package manager bootstrap with automatic managed file upgrades.
- Public npm packaging under `claudex-codex` with the `claudex` executable.
- Homebrew, Scoop, and WinGet distribution metadata and documentation.
- Versioned `.tar.gz` and Windows `.zip` release artifacts with SHA-256 sums.
- Release asset automation and package content validation in CI.

### Fixed

- Friendly model names in Claude Code's secondary footer without leaked SGR
  fragments such as `[1m`.
- Clear Codex rate limit guidance instead of internal credential pool cooldown
  messages when model access is exhausted.
- Reliable `claudex --resume` shutdown guidance even when agent or concurrent
  session logs are updated at the same time.
- Live Codex Desktop and CLI account change detection, atomic bridge refresh,
  and automatic invalidation of account scoped usage state.

## [1.0.0] - 2026-07-15

### Added

- MIT licensing and complete open source community documentation.
- Contributor, conduct, support, security, and governance policies.
- Structured bug report, feature request, and pull request templates.
- User, configuration, architecture, troubleshooting, and development guides.
- Zero configuration installers for macOS, Linux, WSL, and native Windows.
- Codex authentication synchronization and local compatibility service.
- GPT-5.6 Sol, Terra, Luna, and Solplan model integration.
- Auto mode, max effort, Ultracode, bounded agents, and task reconciliation.
- 400k context reporting and automatic compaction around 280k tokens.
- Usage limit status, low quota alerts, and safe account selection.
- Claude in Chrome first party profile support.
- Cross platform regression coverage in GitHub Actions.

[Unreleased]: https://github.com/BeamoINT/Claudex/compare/v1.5.9...HEAD
[1.5.9]: https://github.com/BeamoINT/Claudex/compare/v1.5.8...v1.5.9
[1.5.8]: https://github.com/BeamoINT/Claudex/compare/v1.5.7...v1.5.8
[1.5.7]: https://github.com/BeamoINT/Claudex/compare/v1.5.6...v1.5.7
[1.5.6]: https://github.com/BeamoINT/Claudex/compare/v1.5.5...v1.5.6
[1.5.5]: https://github.com/BeamoINT/Claudex/compare/v1.5.4...v1.5.5
[1.5.4]: https://github.com/BeamoINT/Claudex/compare/v1.5.3...v1.5.4
[1.5.3]: https://github.com/BeamoINT/Claudex/compare/v1.5.1...v1.5.3
[1.5.1]: https://github.com/BeamoINT/Claudex/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/BeamoINT/Claudex/compare/v1.4.5...v1.5.0
[1.4.5]: https://github.com/BeamoINT/Claudex/compare/v1.4.4...v1.4.5
[1.4.4]: https://github.com/BeamoINT/Claudex/compare/v1.4.3...v1.4.4
[1.4.3]: https://github.com/BeamoINT/Claudex/compare/v1.4.2...v1.4.3
[1.4.2]: https://github.com/BeamoINT/Claudex/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/BeamoINT/Claudex/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/BeamoINT/Claudex/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/BeamoINT/Claudex/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/BeamoINT/Claudex/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/BeamoINT/Claudex/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/BeamoINT/Claudex/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/BeamoINT/Claudex/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BeamoINT/Claudex/releases/tag/v1.0.0
