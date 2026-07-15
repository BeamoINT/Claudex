# Troubleshooting

Start with:

```text
claudex --auth-status
claudex --doctor
```

Do not paste real credentials, `auth.json`, generated proxy keys, prompts,
session IDs, or unsanitized private paths into an issue.

## `claudex: missing .../env`

The launcher is installed without its matching private configuration. Rerun the
installer from the latest release. Do not create a token by hand unless you are
developing a controlled custom installation.

## Codex is logged out

Run:

```text
claudex --login
```

Claudex uses Codex's official ChatGPT sign-in. If `codex login status` succeeds
but no standard `auth.json` exists, `claudex --login` requests file-backed
credential storage. Claudex does not scrape the OS keyring.

## Model is not advertised

Run `claudex --doctor`. The signed-in account must advertise Sol, Terra, and
Luna. Sign into the intended Codex account, update Codex and Claudex, and try
again. Claudex will not silently map an unavailable model to a different one.

Temporary provider outages and cooldowns are upstream conditions. Claudex
bounds retries and agent concurrency to avoid turning them into retry storms.
The managed bridge retries transient upstream 500/502/503/504 responses before
Claude Code sees them, including failures before the first stream byte. A red
API error that remains after those bounded retries is a persistent failure and
is intentionally still shown.
When Codex reports an exhausted model quota, Claudex labels it as a rate limit
and points to `/usage-limit`. If you sign into another account in Codex Desktop
or the Codex CLI, the running Claudex session follows that account
automatically; press Continue after the new sign-in completes.

## Local proxy does not become healthy

An open Claudex session automatically restarts a proxy that exits unexpectedly.
The recovery is shared across tabs and normally completes within the client's
bounded retry window. If `ConnectionRefused` persists:

1. Confirm no unrelated process is using port 8318.
2. Rerun the installer so the pinned compatibility binary and config are
   restored.
3. Check the sanitized logs under `~/.config/claudex/logs`.
4. Run `claudex --doctor` again.

Do not expose the generated proxy port to the network.

## `jq` is missing

Rerun `./install.sh`; it supports Homebrew, apt, dnf, yum, zypper, pacman, and
apk. If the package manager requires elevation, the installer uses `sudo`.

## The model picker has duplicates or stale labels

Close Claudex and start a new session. The launcher reconciles managed entries
in its isolated `.claude.json` on every launch. If the issue persists, update
Claudex and rerun the installer.

## The status line briefly shows no context percentage

A brand-new session intentionally omits a zero value until Claude Code reports
real usage. During compaction, Claudex retains the last trustworthy value for
that session. It should never flash a misleading `0%` and then jump back.

## Usage limits are missing or stale

Run:

```text
claudex --usage-limit
```

If the live request fails, Claudex displays a recent sanitized cache when it is
within the configured maximum age. Check `CLAUDEX_USAGE_SOURCE`, network
connectivity, and Codex login. Selecting another account clears the old cache.

## Claude in Chrome does not connect

Use `claudex --claude-chrome`, not a model selector combined with `--chrome`.
The direct command intentionally uses the normal first-party Claude profile.
Browser support, extension versions, subscription plans, and sign-in are
controlled by Anthropic. WSL and unsupported Chromium variants may not work.

## Launch command remains visible or the terminal flickers

Confirm that the terminal supports alternate-screen/fullscreen applications
and that accessibility or reduced-motion settings are not forcing a different
rendering mode. Run the latest Claude Code and Claudex releases. Include the
terminal name and version in a sanitized bug report.

Claudex leaves interactive fullscreen cursor and redraw frames byte-for-byte
native. If the bottom input or status area is clipped after upgrading, close
the older running session and start a new `claudex` session so the updated
preload is active.

## Windows script execution is blocked

Run the documented installer command from Windows PowerShell:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

This applies only to that process and does not change the machine-wide policy.
If organizational policy still blocks scripts, consult the machine
administrator.

## Still stuck

Read [SUPPORT.md](../SUPPORT.md) and open the appropriate discussion or issue.
Include a minimal reproduction and sanitized `claudex --doctor` output.
