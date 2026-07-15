# Command reference

Claudex-specific launch switches must appear before the first Claude Code
argument. After the first forwarded argument, Claudex preserves every remaining
token literally.

```bash
claudex --terra --print "Explain this repository"
```

## Launch modes

| Command | Behavior |
| --- | --- |
| `claudex` | Start the Sol leader with auto permissions |
| `claudex --sol` | Explicitly start with GPT-5.6 Sol |
| `claudex --terra` | Start with GPT-5.6 Terra |
| `claudex --luna` | Start with GPT-5.6 Luna |
| `claudex --solplan` | Use Sol while planning and Terra while implementing |
| `claudex --manual` | Use manual permission handling for this launch |
| `claudex --auto` | Use auto permission handling for this launch |
| `claudex --accept-edits` | Automatically accept edit operations for this launch |
| `claudex --max-effort` | Pass Claude Code's native `--effort max` |
| `claudex --ultracode` | Enable session-only workflows with xhigh effort |
| `claudex --claude-chrome` | Use the normal first-party Claude profile with Chrome integration |

`--max-effort` and `--ultracode` are mutually exclusive. Explicit `--effort`
or `--settings` arguments cannot be combined with either shortcut because they
could silently override the selected mode.

## Model picker

Inside Claudex, use `/model` to choose a model. Claudex maintains exactly one
entry for each managed model:

- **GPT-5.6 Sol** — leader and hardest reasoning work;
- **GPT-5.6 Terra** — balanced implementation and substantial delegated work;
- **GPT-5.6 Luna** — fast search, triage, and bounded mechanical tasks;
- **GPT-5.6 Solplan** — Sol in plan mode and Terra during implementation.

Enter `/model solplan` as a shortcut for the built-in plan/execution selector.
Claudex does not activate plan mode merely because a task is large; plan mode
is reserved for explicit planning or a decision that must precede execution.

Model availability depends on the signed-in Codex account. `claudex --doctor`
shows what the local authenticated endpoint advertises.

## Authentication

| Command | Behavior |
| --- | --- |
| `claudex --auth-status` | Validate the shared Codex session and repair the local bridge if needed |
| `claudex --login` | Open Codex's official ChatGPT sign-in and synchronize it |
| `claudex --logout` | Log out through Codex and remove Claudex's bridge credential |

When Codex is logged out, Claudex clears its bridge rather than repeatedly
trying a stale credential. Sign in again with `claudex --login`.

## Usage limits

| Command | Behavior |
| --- | --- |
| `claudex --usage-limit` | Refresh and display detailed Codex limits |
| `claudex --usage-limit --cached` | Display the last sanitized snapshot without refreshing |
| `claudex --usage-limit --json` | Display the sanitized snapshot as JSON |
| `claudex --accounts` | List locally available Codex usage accounts |
| `claudex --account SELECTOR` | Select an account by number, email, or credential filename |
| `claudex --account auto` | Return to automatic newest-credential selection |

Inside an interactive session, `/usage-limit` displays the detailed report.
The status line refreshes a compact summary asynchronously. Selecting an
account invalidates the prior quota cache so values from different accounts
cannot be mixed. Disabled and expired credentials are never selected.

## Claude in Chrome

`claudex --claude-chrome` intentionally bypasses the GPT compatibility path,
uses the user's normal first-party Claude profile, and adds `--chrome`. This is
the supported integration route for Anthropic's browser extension.

The first launch may request a Claude Code sign-in. Browser, account, and plan
requirements are controlled by Anthropic. The normal Claudex configuration is
not modified. Resume hints preserve the direct route:

```text
claudex --claude-chrome --resume SESSION-ID
```

## Claude Code passthrough

Unknown options and subcommands are forwarded in order. Management commands
such as `mcp`, `plugin`, `auth`, `update`, and `doctor` bypass the GPT proxy and
Claudex session injection. `--bare` and `--safe-mode` suppress the custom
leader prompt, agents, and default permission override.

Examples:

```bash
claudex --continue
claudex --resume SESSION-ID
claudex --worktree audit-branch
claudex mcp list
claudex plugin list
claudex update
```

See [claude-code-compatibility.md](claude-code-compatibility.md) for the tested
passthrough matrix and upstream limitations.

## Diagnostics

`claudex --doctor` reports:

- Claude Code and CLIProxyAPI versions;
- Codex authentication state;
- loopback proxy health;
- current model and model advertisement;
- permission, context, compaction, usage, update, and concurrency settings;
- platform rendering and profile isolation.

Doctor output never intentionally prints tokens. Sanitize account details,
local paths, and other private context before posting it publicly.
