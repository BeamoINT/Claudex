# Installation

Claudex installs a small launcher and private configuration around existing
Codex and Claude Code installations. Users do not manually create provider
keys or configure model endpoints.

## Requirements

| Requirement | Purpose |
| --- | --- |
| Codex desktop app or CLI | Supplies the user's existing ChatGPT/Codex sign-in |
| Claude Code | Supplies the terminal UI and tool protocol |
| Internet connection during installation | Downloads or updates dependencies and verifies the model endpoint |
| Supported account access | The signed-in Codex account must advertise the configured models |

The Unix installer also needs `curl`, `tar`, and a supported package manager if
`jq` is missing. The Windows installer uses built-in PowerShell download and
archive commands.

## Download

Choose one of these methods:

1. Download the source archive from the
   [latest release](https://github.com/BeamoINT/Claudex/releases/latest) and
   extract it.
2. Clone the repository:

   ```bash
   git clone https://github.com/BeamoINT/Claudex.git
   cd Claudex
   ```

Release archives are preferable for ordinary users. A Git clone is convenient
for contributors and makes updates with `git pull` straightforward.

## macOS, Linux, and WSL

From the extracted or cloned repository:

```bash
bash ./install.sh --login
```

`--login` opens Codex's official ChatGPT sign-in and requests file-backed
credential storage. It is optional when `codex login status` already succeeds
and the standard Codex `auth.json` exists.

The installer:

1. checks required commands and installs `jq` when supported;
2. installs Claude Code from Anthropic's installer if it is missing;
3. updates Claude Code on a best-effort basis;
4. downloads the pinned CLIProxyAPI archive and verifies its SHA-256 digest;
5. generates a random localhost-only proxy key;
6. creates private state in `~/.config/claudex`;
7. installs `claudex` into `~/.local/bin`;
8. synchronizes the Codex login and runs `claudex --doctor`.

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

The launcher also performs a non-blocking Claude Code update check every 24
hours by default. See [configuration.md](configuration.md) to change or disable
that check.

## Install on another machine

Install Codex and Claude Code, sign into Codex on that machine, download
Claudex, and run the platform installer. Do not copy `auth.json`,
`~/.config/claudex`, generated proxy keys, history, or session files between
machines. Re-authentication is safer and keeps each installation independent.

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
