# Claudex

[![CI](https://github.com/BeamoINT/Claudex/actions/workflows/test.yml/badge.svg)](https://github.com/BeamoINT/Claudex/actions/workflows/test.yml)
[![CodeQL](https://github.com/BeamoINT/Claudex/actions/workflows/codeql.yml/badge.svg)](https://github.com/BeamoINT/Claudex/actions/workflows/codeql.yml)
[![Latest release](https://img.shields.io/github/v/release/BeamoINT/Claudex)](https://github.com/BeamoINT/Claudex/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows-informational.svg)](docs/installation.md)

Claudex is an open-source compatibility layer for using Codex GPT models through the Claude Code interface. It reuses the Codex login already on your computer, configures the local bridge automatically, and preserves the Claude Code workflows people already know.

> [!IMPORTANT]
> Claudex is an independent community project. It is not affiliated with, endorsed by, or supported by OpenAI or Anthropic. Its installer uses the official [Codex CLI](https://developers.openai.com/codex/cli/) npm package and [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) installer when either prerequisite is missing. You remain responsible for the terms and usage limits of those services.

## Quick start

Install Claudex, then complete the official Codex browser sign-in when prompted.

### One-command source installer

macOS, Linux, or WSL:

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://claudex.work/install.sh | bash
```

Windows PowerShell:

```powershell
irm https://claudex.work/install.ps1 | iex
```

These small website bootstraps resolve the latest stable GitHub release,
validate its published SHA-256 digest and archive paths, and only then run the
native Claudex installer. The longer download-first commands below are useful
when you want to inspect the bootstrap before running it.

### Package managers

```bash
brew install BeamoINT/tap/claudex       # macOS or Linux
```

Windows users can also install from the BeamoINT Scoop bucket:

```powershell
scoop bucket add beamoint https://github.com/BeamoINT/scoop-bucket
scoop install beamoint/claudex
```

Then run `claudex --login`. Package installs bootstrap their private managed
configuration automatically on first use. See the
[package-manager guide](docs/package-managers.md) for upgrades and WinGet
submission status; WinGet is not currently an installable channel.

### macOS, Linux, or WSL

```bash
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output /tmp/claudex-bootstrap.sh \
  https://raw.githubusercontent.com/BeamoINT/Claudex/main/bootstrap.sh
bash /tmp/claudex-bootstrap.sh
claudex
```

The bootstrap verifies the latest release archive before running it. The installer
opens Codex's official browser login only when authentication is needed and the
terminal is interactive. If `~/.local/bin` is not on your `PATH`, follow the
instruction printed by the installer.

### Windows

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/BeamoINT/Claudex/main/bootstrap.ps1 -OutFile "$env:TEMP\claudex-bootstrap.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\claudex-bootstrap.ps1"
claudex
```

The installer adds the Claudex launcher directory to your user `PATH`. Open a new terminal if the `claudex` command is not immediately available.

For release downloads, system requirements, updating, and removal, see the [installation guide](docs/installation.md).

## What Claudex adds

- Automatic authentication through the existing Codex desktop or CLI session,
  including live account-switch detection and clear login/logout recovery.
- Friendly model choices for GPT-5.6 Sol, Terra, Luna, and Solplan.
- Solplan planning with Sol and implementation with Terra.
- Auto, max-effort, and Ultracode modes with explicit and separate behavior.
- Stable context accounting and automatic compaction near 280k tokens.
- Codex usage-limit reporting in the status line and through `/usage-limit`.
- Automatic, non-destructive discovery of already-installed Claude Code and
  Codex skills, project skills, legacy Claude commands, and enabled plugin
  skills, with `/skill` and `$skill` references inside Claudex.
- The detected ChatGPT subscription tier in the startup banner instead of
  Claude Code's misleading API-billing label.
- Native agent activity labels that include model, reasoning effort, and task,
  such as `Terra (high) - Audit JSON parser bugs`.
- Cross-platform launchers and installers for macOS, Linux, Windows, and WSL.
- Claude Code argument pass-through, resume-command rewriting, task cleanup, bounded retries, and compatibility detection.
- A clean full-screen terminal experience without exposing launch commands or internal tool traffic unnecessarily.
- An optional direct Claude profile for the officially supported Claude in Chrome path.

Claudex keeps its generated configuration under `~/.config/claudex` and does not replace your normal Claude Code settings. It never commits or bundles your Codex tokens, Claude sessions, prompts, history, or usage data.

## Common commands

```text
claudex                    Start with Sol and auto mode
claudex --terra            Start with Terra
claudex --luna             Start with Luna
claudex --solplan          Use Sol for planning and Terra for implementation
claudex --max-effort       Use Claude Code's maximum reasoning effort
claudex --ultracode        Enable the session-scoped Ultracode workflow
claudex --manual           Disable automatic permissions for this launch
claudex --usage-limit      Refresh and display Codex plan limits
claudex skills             List Claude and Codex skills available in this project
claudex --accounts         List locally available Codex usage accounts
claudex --doctor           Check installation, authentication, and models
claudex --login            Sign in through Codex and synchronize the session
claudex --logout           Sign out and clear the managed bridge session
claudex self-update --status  Inspect automatic update state
claudex self-update --apply   Apply the latest stable release now
claudex --claude-chrome    Use the direct Claude profile with Chrome support
```

Inside Claudex, `/model solplan` selects Solplan and `/usage-limit` prints the detailed quota report. Existing Claude and Codex skills can be referenced with `/skill-name` or `$skill-name`; see the [skills guide](docs/skills.md) for discovery and collision behavior. Unknown options and supported Claude Code subcommands are passed through unchanged. See the [usage guide](docs/usage.md) for the complete command reference.

## Supported platforms

| Platform | Support | Installer |
| --- | --- | --- |
| macOS 13+ on Apple silicon or Intel | Full | `install.sh` |
| Ubuntu 20.04+, Debian 10+, and compatible Linux on x64 or ARM64 | Full | `install.sh` |
| Windows 10 1809+, Windows 11, and Windows Server 2019+ on x64 or ARM64 | Full | `install.ps1` |
| WSL 1 or WSL 2 | Linux environment | `install.sh` |

Claude Code's own platform limitations still apply. In particular, native Windows does not provide the same sandbox implementation as macOS, Linux, and WSL2, and Claude in Chrome follows Anthropic's browser, plan, and environment requirements.

## Documentation

| Guide | Purpose |
| --- | --- |
| [Documentation index](docs/README.md) | Find the right guide quickly |
| [Installation](docs/installation.md) | Requirements, setup, updates, and removal |
| [Package managers](docs/package-managers.md) | Homebrew and Scoop installation; WinGet submission status |
| [Usage](docs/usage.md) | Commands, model modes, Chrome, and pass-through behavior |
| [Configuration](docs/configuration.md) | Supported environment variables and settings |
| [Skills](docs/skills.md) | Existing Claude Code and Codex skill discovery, aliases, and compatibility |
| [Architecture](docs/architecture.md) | Components, data flow, authentication, and trust boundaries |
| [Troubleshooting](docs/troubleshooting.md) | Diagnose common installation and runtime problems |
| [Development](docs/development.md) | Repository layout, tests, and release workflow |
| [Claude Code compatibility](docs/claude-code-compatibility.md) | Audited upstream feature matrix and known boundaries |
| [Roadmap](ROADMAP.md) | Current priorities, contribution ideas, and non-goals |

Project policies and history are in [CONTRIBUTING.md](CONTRIBUTING.md), [GOVERNANCE.md](GOVERNANCE.md), [MAINTAINERS.md](MAINTAINERS.md), [SECURITY.md](SECURITY.md), [SUPPORT.md](SUPPORT.md), and [CHANGELOG.md](CHANGELOG.md).

## How it works

```text
claudex command
    -> validates the local Codex session
    -> refreshes the private localhost bridge
    -> launches an isolated Claude Code profile
    -> maps friendly model names to Codex models
    -> preserves supported Claude Code commands and options
```

The installer downloads a pinned [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) release, verifies its published SHA-256 digest, and binds it to `127.0.0.1` on a dedicated port with a generated local key. The dependency is not vendored into this repository and retains its own license. Read the [architecture guide](docs/architecture.md) and [third-party notice](NOTICE.md) before changing authentication or proxy behavior.

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), which covers local setup, testing, cross-platform expectations, pull requests, and the project's no-CLA contribution terms. By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

- Ask usage questions in [GitHub Discussions](https://github.com/BeamoINT/Claudex/discussions).
- Report reproducible bugs or propose features with the [issue templates](https://github.com/BeamoINT/Claudex/issues/new/choose).
- Find approachable work under [`good first issue`](https://github.com/BeamoINT/Claudex/labels/good%20first%20issue) and maintainer-supported work under [`help wanted`](https://github.com/BeamoINT/Claudex/labels/help%20wanted).
- Review the [roadmap](ROADMAP.md) before proposing a large change.
- Report security vulnerabilities privately through [GitHub Security Advisories](https://github.com/BeamoINT/Claudex/security/advisories/new).

Run the complete local test suite before opening a pull request:

```bash
./test.sh
```

On Windows, run `./test.ps1` from PowerShell. GitHub Actions repeats the suite on macOS, Ubuntu, and Windows.

## License

Claudex is available under the [MIT License](LICENSE). See [NOTICE.md](NOTICE.md) for project independence, trademark, and third-party dependency notices.
