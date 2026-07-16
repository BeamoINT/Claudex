# Installation

Claudex installs a small launcher and private configuration around Codex and
Claude Code. When either CLI is missing, the installer installs it from its
official distribution. Users do not manually create provider keys or configure
model endpoints.

## Requirements

| Requirement | Purpose |
| --- | --- |
| Codex CLI | Supplies the user's ChatGPT/Codex sign in; installed automatically when missing |
| Claude Code | Supplies the terminal UI and tool protocol; installed automatically when missing |
| Internet connection during installation | Downloads or updates dependencies and verifies the model endpoint |
| Supported account access | The signed in Codex account must advertise the configured models |

The platform list describes supported installer and launcher paths, not a claim
that every CPU and operating system combination runs in hosted CI. The current
matrix exercises GitHub hosted macOS, Ubuntu, and x64 Windows, plus an Ubuntu
20.04 container. ARM64 and WSL paths do not currently have dedicated hosted
jobs; see the [platform evidence table](../README.md#supported-platforms).

The Unix installer also needs `curl`, `tar`, and a supported package manager if
`jq`, Node.js, or npm is missing. On legacy Linux distributions whose stock
repository is below Node.js 18, it installs a checksum verified official Node.js
22 LTS runtime under the private Claudex config directory. The Windows installer uses built in PowerShell
download and archive commands and can install Node.js through WinGet,
Chocolatey, or Scoop. Codex CLI is installed from OpenAI's official
`@openai/codex` npm package.

## Download

The shortest verified source installation is hosted on the Claudex website.

macOS, Linux, or WSL:

```bash
curl -fsSL --proto '=https' --tlsv1.2 https://claudex.work/install.sh | bash
```

Windows PowerShell:

```powershell
irm https://claudex.work/install.ps1 | iex
```

The website bootstrap verifies the latest stable GitHub release before running
its native installer. For package managed installation, see
[package manager guide](package-managers.md) for Homebrew and Scoop commands and
the current WinGet submission status. Package installs configure themselves on
first use and refresh the managed launcher after upgrades.

For the simplest verified source installation on macOS, Linux, or WSL:

```bash
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output /tmp/claudex-bootstrap.sh \
  https://raw.githubusercontent.com/BeamoINT/Claudex/main/bootstrap.sh
bash /tmp/claudex-bootstrap.sh
```

Windows PowerShell:

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/BeamoINT/Claudex/main/bootstrap.ps1 -OutFile "$env:TEMP\claudex-bootstrap.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\claudex-bootstrap.ps1"
```

The bootstrap resolves the latest GitHub release, verifies its SHA-256 entry,
rejects unsafe archive paths, confirms the embedded package version, and only
then runs the platform installer. To inspect the installable runtime or obtain
a complete contributor checkout, choose the appropriate method:

1. Download the platform release archive from the
   [latest release](https://github.com/BeamoINT/Claudex/releases/latest) and
   extract it to inspect or run the shipped installer and runtime files. Release
   archives intentionally omit the repository's tests, CI configuration, and
   maintainer only development files.
2. Clone the complete repository for development, tests, or contributions:

   ```bash
   git clone https://github.com/BeamoINT/Claudex.git
   cd Claudex
   ```

Release archives are preferable for ordinary users. Contributors need a Git
clone so the full test and development toolchain is available; a clone also
makes source checkout updates with `git pull` straightforward.

## macOS, Linux, and WSL

From the extracted or cloned repository:

```bash
bash ./install.sh --login
```

`--login` always opens Codex's official ChatGPT sign in and requests file backed
credential storage, including when an existing session is valid and you want to
switch accounts. Omit it to reuse a valid standard Codex `auth.json`; an
interactive install still opens login automatically when authentication is
missing.

The installer:

1. checks required commands and installs `jq`, Node.js, and npm when needed,
   falling back to a checksum verified private Node.js 22 runtime when the
   platform package manager is unavailable, unprivileged, or unsuccessful;
2. installs Codex CLI from OpenAI's official npm package and Claude Code from Anthropic's installer when missing;
3. updates Claude Code on a best effort basis;
4. downloads the pinned CLIProxyAPI archive and verifies its SHA-256 digest;
5. generates a random localhost only proxy key;
6. creates private state in `~/.config/claudex`;
7. installs `claudex` into `~/.local/bin`;
8. opens the official Codex browser login when needed in an interactive terminal;
9. synchronizes the Codex login and runs `claudex --doctor`.

Transient Claude Code and compatibility service downloads use bounded retries
and timeouts. Reinstalls keep a private rollback generation until every managed
file, environment value, authentication step, and health check succeeds; a
later failure restores the complete prior managed installation.

If `~/.local/bin` is not on `PATH`, add it to the shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then open a new terminal and run:

```bash
claudex
```

## Native Windows

Open Windows PowerShell in the extracted or cloned repository:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Login
```

The installer adds `%USERPROFILE%\.local\bin` to the user `PATH` and installs
the native PowerShell launcher plus a Command Prompt shim. Git Bash is not
required. Open a new terminal after the first installation so the updated user
`PATH` is visible.

## Verify the installation

Run:

```text
claudex --auth-status
claudex --doctor
claudex --usage-limit
```

`--doctor` must report a healthy loopback proxy and advertise Sol, Terra, and
Luna. If the account does not provide one of those models, Claudex exits with
an actionable error instead of silently substituting a model.

## Update

Claudex checks its stable release channel once per day without blocking startup
and applies updates by default. Inspect, check immediately, or apply immediately
with:

```text
claudex self-update --status
claudex self-update --check
claudex self-update --apply
```

Package installations delegate to their recorded package manager without
requesting `sudo`. Release archive and source installs use an exact stable
GitHub release asset only after its version, checksum, and archive paths pass
validation. A failed or offline update keeps the installed release intact and
retries later with backoff. See the [package manager guide](package-managers.md).

For a Git checkout:

```bash
git pull --ff-only
./install.sh
```

On Windows:

```powershell
git pull --ff-only
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

For a release archive, download the latest archive, extract it to a new
directory, and rerun the installer. Existing private credentials and custom
environment entries are preserved. Replaced managed files are backed up under
`~/.config/claudex/backups`.

The separate Claude Code update check also runs every 24 hours by default. See
[configuration.md](configuration.md) to configure either update channel.

## Install on another machine

Install Codex and Claude Code, sign into Codex on that machine, download
Claudex, and run the platform installer. Do not copy `auth.json`,
`~/.config/claudex`, generated proxy keys, history, or session files between
machines. Re authentication is safer and keeps each installation independent.

## Remove Claudex

Claudex does not modify the normal Claude Code profile. To remove it, first
close active Claudex sessions. Back up any intentional custom settings, then
remove the Claudex launcher and its private config directory:

```bash
rm "$HOME/.local/bin/claudex"
rm -rf "$HOME/.config/claudex"
```

Windows PowerShell:

```powershell
Remove-Item "$env:USERPROFILE\.local\bin\claudex.cmd" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.local\bin\claudex.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.config\claudex" -Recurse -Force
```

Removing Claudex does not uninstall Codex or Claude Code and does not delete
their normal profiles.
