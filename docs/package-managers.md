# Package-manager installation

Package-manager installs expose the same `claudex` command as the source
installer. On first launch, a small cross-platform bootstrap installs the
managed files into `~/.config/claudex`, downloads the checksum-verified local
compatibility service, and then hands off to the normal launcher.

Codex and Claude Code are required at runtime, but the first-run bootstrap now
installs either missing CLI. In an interactive terminal it opens Codex's
official browser sign-in automatically when the standard file-backed session is
not ready. `claudex --login` remains available to retry or switch accounts.

## Homebrew

Homebrew installs Node.js and `jq` as formula dependencies:

```bash
brew install BeamoINT/tap/claudex
claudex --login
```

Upgrade with `brew upgrade claudex`. The updated package refreshes the managed
Claudex files automatically on the next launch.

## npm

The unscoped name `claudex` belongs to an unrelated npm project, so this
project is published as `claudex-codex` while retaining the `claudex` command:

```bash
npm install --global claudex-codex
claudex --login
```

For a one-shot installation and launch:

```bash
npx claudex-codex --login
```

Upgrade with `npm install --global claudex-codex@latest`.

## Scoop on Windows

```powershell
scoop bucket add beamoint https://github.com/BeamoINT/scoop-bucket
scoop install beamoint/claudex
claudex --login
```

Scoop installs the Node.js runtime required by the package bootstrap. Upgrade
with `scoop update claudex`.

## WinGet

The Windows Package Manager community repository requires external validation
and review for every new listing. Once the `BeamoINT.Claudex` submission is
accepted, install it with:

```powershell
winget install --id BeamoINT.Claudex --exact
```

The current submission status is tracked in the
[WinGet community repository](https://github.com/microsoft/winget-pkgs/pulls?q=is%3Apr+BeamoINT.Claudex).

## Explicit setup

Package installations normally configure themselves on first use. To perform
setup without starting an interactive Claudex session, run:

```text
claudex --package-setup
claudex --package-setup --login
```

Package metadata contains no credentials or generated user state. The setup
command creates those files locally with the same restrictive permissions as
the source installer.

The public `claudex` command remains owned by the package manager. Claudex keeps
its internal managed launcher under `~/.config/claudex/package-bin`, preventing
it from shadowing npm, Homebrew, Scoop, or WinGet after a later upgrade. The
installer records the manager in a private install receipt, and
`claudex self-update --apply` delegates to that manager without invoking
`sudo`. If manager policy or permissions reject the update, the current release
is retained and the normal manual upgrade command above remains available.

## Uninstall

Remove the package with `brew uninstall claudex`,
`npm uninstall --global claudex-codex`, or `scoop uninstall claudex`.
Package managers intentionally leave `~/.config/claudex` in place so an
uninstall cannot destroy private settings or session state unexpectedly. After
closing all Claudex sessions, remove that directory manually if the data is no
longer needed.
