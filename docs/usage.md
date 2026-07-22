# Command reference

Claudex specific launch switches must appear before the first Claude Code
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
| `claudex --fable` | Start native Claude Code with the Fable alias |
| `claudex --opus` | Start native Claude Code with the Opus alias |
| `claudex --sonnet` | Start native Claude Code with the Sonnet alias |
| `claudex --haiku` | Start native Claude Code with the Haiku alias |
| `claudex --claude-model MODEL` | Start native Claude Code with any alias or full model ID accepted by that CLI |
| `claudex --fableplan "TASK"` | Ask native Fable for a read only plan, then start managed Terra with that plan |
| `claudex --manual` | Use manual permission handling for this launch |
| `claudex --auto` | Use auto permission handling for this launch |
| `claudex --accept-edits` | Automatically accept edit operations for this launch |
| `claudex --max-effort` | Pass Claude Code's native `--effort max` |
| `claudex --ultracode` | Enable session only workflows with xhigh effort |
| `claudex --claude-chrome` | Use the normal first party Claude profile with Chrome integration |
| `claudex --remote-control [NAME]` | Use Claude Remote Control through the clean first party profile (`--rc` is an alias) |
| `claudex ultrareview [ARGS]` | Run Claude Ultrareview through the clean first party profile |
| `claudex codex [ARGS]` | Run the native Codex CLI without Claudex provider, prompt, session, or policy translation |
| `claudex claude [ARGS]` | Run native Claude Code with caller owned provider/profile configuration and without Claudex provider/model injection |

`--max-effort` and `--ultracode` are mutually exclusive. Explicit `--effort`
or `--settings` arguments cannot be combined with either shortcut because they
could silently override the selected mode.

The native Claude selectors and `--fableplan` must be the first Claudex option.
`--claude-model` requires one nonempty value. Each selector forwards every
remaining token to Claude Code in order. Use the explicit native route when a
model argument must appear in a different position:

```bash
claudex claude --model fable --print "Explain this repository"
```

Availability and accepted aliases or full identifiers come from the installed
Claude Code CLI and the signed in Anthropic account. Claudex does not
substitute another Claude model when an identifier is unavailable.

Auto mode uses GPT-5.6 Terra through the authenticated Codex bridge for its
safety classifier. It recognizes an explicit user approval for the named
action and target without demanding a duplicate confirmation; hard security
boundaries and actions outside that scope remain blocked. Classifier overrides
accept managed Codex GPT model IDs only.

An approval may clearly refer to the immediately preceding denial (for example,
"I approve that" or "go ahead") without restating the full command. One narrow
private development transfer is treated as named and specific soft consent: the
task required source from the current trusted repository to an explicitly named,
private, user controlled build or deployment host. Public or agent selected
destinations, credentials and secrets, unrelated files, broader source trees,
and a different host remain under the hard data exfiltration boundary.

Claudex composes these additions with all four rule arrays reported by the
installed Claude Code build. It never ships a partial replacement for upstream
defaults; if defaults are temporarily unavailable, it uses the last validated
snapshot or removes only a recognizable legacy Claudex only seed.

The Sol leader is tuned to inspect context and make safe, reasonable assumptions
instead of asking for routine confirmations. It asks only when an answer cannot
be discovered and would materially change the result, expand scope, or precede
an irreversible action, and it does not repeat questions already answered. This
leader guidance remains active when callers provide their own `--agents` JSON;
only Claudex's built in `Terra (high)` and `Luna (medium)` definitions are
replaced in that case.

## Model picker

Inside Claudex, use `/model` to choose a model. Claudex maintains exactly one
entry for each managed model:

- **GPT-5.6 Sol**: leader and hardest reasoning work;
- **GPT-5.6 Terra**: balanced implementation and substantial delegated work;
- **GPT-5.6 Luna**: fast search, triage, and bounded mechanical tasks;
- **GPT-5.6 Solplan**: Sol in plan mode and Terra during implementation.

Delegated activity shows both the short model name and its configured reasoning
effort: `Terra (high)` or `Luna (medium)`. Each activity also includes a concise
task label, for example `Terra (high) - Audit JSON parser bugs`. Sol remains the
leader unless the user supplies an explicit custom agent configuration.

On interactive startup, Claudex reads the sanitized plan type from the same
account bound Codex usage snapshot used by `/usage-limit`. The welcome banner
shows `ChatGPT Free`, `ChatGPT Go`, `ChatGPT Plus`, `ChatGPT Pro`, or the
applicable workspace tier. If OpenAI does not return a recognized tier, it
shows the honest fallback `ChatGPT` and never claims API usage billing.

Enter `/model solplan` as a shortcut for the built in plan/execution selector.
Claudex does not activate plan mode merely because a task is large; plan mode
is reserved for explicit planning or a decision that must precede execution.

Model availability depends on the signed in Codex account. `claudex --doctor`
shows what the local authenticated endpoint advertises.

## Native Claude models

`--fable`, `--opus`, `--sonnet`, and `--haiku` are short forms of a native
Claude Code launch with the matching model alias. `--claude-model MODEL`
accepts an alias or exact model ID. `claudex claude --model MODEL ...` exposes
the same native model interface without any Claudex option translation.

These commands do not use the Codex bridge, managed model picker, managed
status line, Codex usage display, or managed agent definitions. Claudex removes
managed provider variables and credentials before it starts the native process,
then lets the caller owned Claude profile, account, platform, and service entitlement
control the result.

Claude and GPT models can run concurrently by using separate processes. For
example, start `claudex --fable` in one terminal and `claudex --terra` in
another. A process receives one provider environment only. Claudex never loads
Anthropic and Codex credentials into the same process, and sessions, context,
tool state, and billing remain independent.

## Fableplan

`claudex --fableplan "TASK"` is a deliberate two process workflow:

1. A native Fable process receives the task with safe mode, plan permission,
   and read only `Read`, `Glob`, and `Grep` tools.
2. Claudex captures only its plan text into a private temporary file. The plan
   must be nonempty valid UTF-8 without NUL bytes and must stay within the
   one mebibyte limit.
3. If planning succeeds, an isolated managed Terra process receives the
   original task and access to the private plan file. The implementation
   prompt treats the plan as untrusted planning guidance.
4. Claudex removes the temporary file after Terra exits. A planning failure,
   invalid plan, or oversized plan prevents Terra from starting.

The native planner and managed implementer never share a provider environment,
credential, session, or writable state directory. The private plan file is the
only data transferred from the planner process to the implementer process.
Fableplan requires exactly one nonempty task string, so quote a task that
contains spaces.

## Authentication

| Command | Behavior |
| --- | --- |
| `claudex --auth-status` | Validate the shared Codex session and repair the local bridge if needed |
| `claudex --login` | Open Codex's official ChatGPT sign in and synchronize it |
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
| `claudex --account auto` | Return to automatic newest credential selection |

Inside an interactive session, `/usage-limit` displays the detailed report.
The status line refreshes a compact summary asynchronously. Selecting an
account invalidates the prior quota cache so values from different accounts
cannot be mixed. Changing the active login in Codex Desktop or the Codex CLI is
detected while Claudex is running; the local bridge follows the new account and
clears account scoped usage state automatically. Disabled and expired
credentials are never selected.

## Skills

| Command or reference | Behavior |
| --- | --- |
| `claudex skills` | List every bridged alias, shortcut, source, and inactive source plugin runtime component for the current project |
| `/skill-name` | Invoke a Claude native or bridged Codex skill inside Claudex |
| `$skill-name` | Codex style explicit reference to the matching bridged skill |

Claudex automatically discovers existing personal, project, legacy, admin, and
enabled plugin skills from both ecosystems without changing the source files.
See [Claude Code and Codex skills](skills.md) for the complete location,
collision, policy translation, and opt out contract.

## Claude in Chrome

`claudex --claude-chrome` intentionally bypasses the GPT compatibility path,
uses the user's normal first party Claude profile, and adds `--chrome`. This is
the supported integration route for Anthropic's browser extension.

The first launch may request a Claude Code sign in. Browser, account, and plan
requirements are controlled by Anthropic. The normal Claudex configuration is
not modified. Resume hints preserve the direct route:

```text
claudex --claude-chrome --resume SESSION-ID
```

## Native harness routes

Use `claudex codex ...` for Codex only configuration, policy, sandboxing, MCP,
hooks, plugins, apps, web search, threads, and Codex event formats. Use
`claudex claude ...` for native Claude configuration, providers, plugins, and
features without automatically enabling Chrome. Native Claude model shortcuts
use that same clean route. Both commands preserve their
remaining arguments and hand control to the installed upstream CLI. They do
not translate sessions, policy decisions, plugins, or event streams between
the two harnesses. When called from a managed Claudex session, the native Claude
route removes Claudex owned provider and session state before launch; explicit
caller owned Claude configuration remains authoritative.

These routes are how Claudex provides complete harness specific access:
native Codex on the Codex route and native Claude on the Claude route, subject
to the installed CLI, caller owned provider configuration, account, platform,
and upstream service.
The default GPT backed mode translates only documented portable semantics; it
does not emulate Codex only tools or activate full Codex plugin components in
Claude Code.

Remote Control and Ultrareview are Claude hosted, first party services.
`claudex --remote-control` (or `--rc`) and `claudex ultrareview` automatically
use the clean first party Claude profile. The explicit `claudex claude ...`
route instead preserves caller owned provider configuration, so the automatic
form is the clean first party convenience for these hosted services. These
paths use the user's Anthropic account, entitlement, and billing context rather
than the Codex backed provider bridge. Codex cloud and remote control features
remain available separately through `claudex codex ...`; sessions and account
state are not interchangeable.

## Claude Code passthrough

Unknown options and subcommands are forwarded in order. Management commands
such as `mcp`, `plugin`, `auth`, `update`, and `doctor` bypass the GPT proxy and
Claudex session injection. `--bare` and `--safe-mode` suppress the custom
leader prompt, agents, and default permission override.
An explicit `--tools` selection suppresses the task lifecycle prompt when its
replacement tool set cannot support the managed lifecycle. `--disallowedTools`
does the same only when it explicitly denies `Agent` or `TaskList`;
`--allowedTools` changes approval policy without incorrectly hiding lifecycle
guidance for tools that remain available.
`--bg` is forwarded and Claude Code detaches the agent. Claudex detaches its
auth and proxy recovery watchers too. They verify the foreground launcher's
process identity, then remain active while the managed `claude agents --json`
registry contains any live session, so detached GPT backed work continues to
follow account changes and recover proxy outages.

Examples:

```bash
claudex --continue
claudex --resume SESSION-ID
claudex --worktree audit-branch
claudex mcp list
claudex plugin list
claudex update
```

See [Claude Code compatibility](claude-code-compatibility.md) for the tested
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
