# Claude Code and Codex compatibility

This matrix was rechecked with live safe `--help` and `--version` probes against
Claude Code 2.1.211 and Codex CLI 0.144.4 in July 2026. The default Claudex mode
is a Claude Code harness
backed by Codex GPT models, not a fork of either coding harness. Its interactive
UI, tools, transcripts, and machine output protocol remain Claude Code's. Codex
supplies the authenticated model session and the portable features that Claudex
explicitly translates. Explicit native routes are described below for features
that should remain in their original harness.

That distinction matters: preserving a command line argument is not the same as
implementing the equivalent Codex feature. The tables below describe the
current boundary without treating unrelated upstream interfaces as
interchangeable.

## Classification

| Status | Meaning |
| --- | --- |
| **Native** | Claude Code implements the feature inside the GPT backed session; Claudex does not replace its runtime semantics. |
| **Translated** | Claudex converts a Codex facing concept or local state into a Claude Code compatible representation. |
| **Pass through** | Claudex preserves the Claude Code arguments, but the upstream CLI, project configuration, account, and external services still determine whether the feature succeeds. |
| **First party only** | The feature requires a normal Anthropic backed Claude session; Claudex provides a direct route where one is available. |
| **Not portable** | The Claude Code and Codex implementations do not have a safe, equivalent mapping. Use the feature in its native harness. |

## Two harness capability matrix

| Capability | Claude Code side in Claudex | Codex side | Status and boundary |
| --- | --- | --- | --- |
| Interactive UI and tools | Claude Code owns the terminal UI and tool schemas | Codex models answer through the local provider bridge | **Native** Claude Code runtime; the Codex TUI and its tool protocol are **not portable** |
| Authentication and model access | Claude Code receives a generated loopback provider configuration | The standard file backed Codex login is synchronized into a private bridge credential | **Translated** |
| Model selection | Claude Code model aliases expose Sol, Terra, Luna, and Solplan | The aliases resolve to advertised Codex GPT model IDs | **Translated**; this is not the complete native Codex model catalog |
| Project instructions | Claude Code discovers its supported `CLAUDE.md` hierarchy | Claudex snapshots Codex guidance in global to launch directory order into a private `CLAUDE.md` overlay, honoring effective fallback filenames, the configured byte budget, and trusted project config | **Native** plus **translated**; broader managed Codex policy remains a native route concern |
| Skills | Claude project skills remain native; imported skills are supplied through an additional private directory | Personal, project, legacy, admin, and enabled plugin skill content is snapshotted and adapted | **Native** plus **translated**; see [the skills contract](skills.md) |
| Plugins | Claude plugin management and explicit `--plugin-dir` arguments remain Claude interfaces | Validated Codex plugin skill content can be adapted, but plugin hooks, MCP servers, agents, settings, and app runtime are not activated in the default mode | **Pass through** for Claude plugins, **translated** for skill content, and otherwise **not portable** between harnesses; native routes retain each harness's plugin runtime |
| MCP servers | Claude's native configuration and explicit `--mcp-config` arguments remain authoritative | Codex `[mcp_servers]`, managed MCP policy, and plugin provided MCP configuration are not translated into Claude configuration | **Pass through** on the Claude side and **native** on the Codex route; configurations are **not portable** between them |
| Hooks | Claude hooks remain part of the Claude runtime; Claudex generates one bounded `UserPromptSubmit` adapter for Codex style `$skill` references | Codex hook layers and plugin hooks are not imported into the default mode | **Native** plus a narrow **translated** adapter; other hooks stay **native** to their explicit harness route |
| Agents and tasks | Claude custom agents and task tools remain authoritative; Claudex adds bounded Terra and Luna agents unless the caller supplies `--agents` | Codex custom agent files, thread controls, and native collaboration protocol are not imported into Claude Code | **Translated** managed agents in the default mode; custom agents stay **native** to their harness route |
| Permissions and sandboxing | Claude permission modes and the sandbox available on the host platform remain authoritative | Codex approval policy, rules, managed requirements, and sandbox configuration are not enforcement inputs to Claude Code | **Native** controls on each explicit harness route; policy semantics are **not portable** between them |
| Sessions, resume, and worktrees | Claude session IDs, resume, fork, PR, worktree, IDE, and tmux arguments are preserved | Codex thread IDs and resume, fork, archive, cloud, and app server state remain separate | **Pass through** for Claude sessions and **native** on each explicit route; session stores are **not portable** |
| Structured and streaming output | Claude Code emits text, JSON, stream JSON, and schema constrained output | Codex JSONL and app server thread/turn/item events are not exposed by the default Claude harness | **Native** output on each explicit route; event protocols are **not portable** |
| Usage limits | A bundled skill and status helper render sanitized Codex account limits | Data comes from the authenticated Codex usage endpoint or bounded app server fallback | **Translated** |
| Browser, web search, and apps | `--claude-chrome` uses a normal Claude profile; other Claude flags remain upstream controlled | Codex web search modes, browser behavior, apps, and connectors are not recreated in Claude Code | Claude in Chrome is **first party only**; each native route preserves its own browser, search, and app surfaces, which are **not portable** |
| Management commands | Claude management subcommands bypass the GPT provider and session injection | Codex management commands run through the explicit native Codex route | **Pass through** for Claude commands and **native** for Codex commands; management state is **not portable** |

## Harness routes

The route is an execution boundary, not a session converter. Complete
harness specific access means executing the feature in its installed native
harness: `claudex codex ...` for Codex and `claudex claude ...` for the native
Claude harness. It does not mean that configuration, sessions,
plugins, policy, tools, or event protocols become portable between products.

| Command | Harness contract |
| --- | --- |
| `claudex [CLAUDEX-OPTIONS] [CLAUDE-ARGS]` | Default portable mode: Claude Code UI and tools backed by the Codex model bridge, with the translations documented above. |
| `claudex codex [CODEX-ARGS]` | Native Codex route: hand off to the installed Codex CLI so Codex configuration, instructions, policy, sandbox, MCP, hooks, plugins, apps, sessions, and output protocols retain their native semantics. |
| `claudex claude [CLAUDE-ARGS]` | Native Claude route: hand off without Codex provider or Claudex session injection. Caller owned Claude provider and profile configuration remain authoritative; managed Claudex state is scrubbed when crossing out of a managed session. |
| `claudex --claude-chrome [CLAUDE-ARGS]` | First party Claude convenience route that also requests Claude in Chrome. |

Claude and Codex session identifiers, configuration files, policy decisions,
plugin runtime state, and event streams are not converted between routes. A
feature that is marked not portable remains fully available through its native
route when the installed CLI, account, platform, and external services support
it.

The default proxied mode translates only the portable semantics listed in the
matrix. It does not emulate the Codex TUI or tool protocol, and it does not load
Codex plugin hooks, MCP servers, agents, settings, apps, or other non skill
runtime components into Claude Code.

`claudex --remote-control` (including `--rc`) and `claudex ultrareview` are
automatically routed through the clean first party Claude profile because those
Claude hosted services do not run through Claudex's third party model provider
bridge. They use the user's Anthropic account, entitlement, and billing context,
not the Codex backed session. The explicit `claudex claude ...` route preserves
caller owned provider configuration, so the automatic form is the clean
first party convenience for these hosted services. A native Codex cloud or
remote control workflow instead belongs under `claudex codex ...`; its sessions
and account state remain separate.

## Exercised Claudex owned adaptations

| Surface | Claudex behavior | Verification |
| --- | --- | --- |
| Interactive and print sessions | GPT-5.6 model aliases, status line, auto permissions, context controls, bounded retries, and leader guard are injected | Isolated argument tests and manual live Sol prompts |
| Sol, Terra, and Luna | Friendly names and one picker entry per real model | Proxy model inventory, launcher tests, and manual live Sol calls |
| Solplan | Friendly `/model solplan` entry backed by Claude Code's `opusplan` selector; Sol plans and Terra implements | Model cache, alias environment, and launcher regressions |
| Max effort | `--max-effort` maps to native `--effort max` and labels the session `max` | Isolated launcher regression and manual exact output prompt |
| Ultracode | `--ultracode` enables session only `ultracode`, `workflows`, and xhigh effort | Isolated launcher regression and manual exact output prompt |
| Auto mode | Terra classifier is pinned through the Codex bridge, explicit named approvals are carried into classification, and Anthropic model IDs are rejected for classifier overrides | Environment, settings schema, and doctor regressions |
| Managed agents and tasks | `Terra (high)` and `Luna (medium)` expose the actual model and configured reasoning effort; concurrency and no recursion guards limit cooldown storms; Sol reconciles task state | Argument contract regressions |
| Claude and Codex skills | Existing personal/project skills, legacy Claude commands, admin skills, and enabled plugin skills are exposed through a non destructive private overlay; compatible files and frontmatter are preserved for Claude Code's native skill runtime, while Codex manual only policy and Claude model family pins are adapted | Shared helper fixtures, launcher arguments, and cross platform installer regressions; upstream skill runtime behavior is not emulated by Claudex |
| Context and compaction | 400k accounting, 280k automatic compaction, Anthropic only 1M selector suppression, and session cache suppression of transient false zero values | Launcher and status line regressions |
| Usage limits | Direct web response, cached outage behavior, low quota alert, account selection, and app server recovery | Fake service regressions and manual live app server query |
| Model picker and banner | Stable friendly model metadata, no unsupported Anthropic 1M row, an account bound ChatGPT plan label in the welcome banner, and a width aware status line | JSON/state, one shot welcome write, narrow width, and output immutability regressions |
| Cursor and mouse | Native terminal cursor plus application pointer OSC with cleanup | Pseudo terminal regression on macOS |
| macOS/Linux install | Bash installer, dependency selection, service startup, backups, and private permissions | Isolated installer regression and hosted OS matrix |
| Native Windows install | PowerShell tool mode, CMD shim, native installer, backups, and private config | PowerShell isolated suite and hosted Windows runner |
| Codex authentication | Standard Codex file backed session is synchronized atomically; live account changes invalidate account scoped state; logout removes the bridge | Logged in, refreshed session, switched account, missing file, and logged out regressions |
| Claude Code updates | Installer checks immediately; launcher checks daily without blocking and negotiates optional flags from current `--help` | Capability and update scheduling regressions |
| Resume hints | An unambiguous Claudex or direct Chrome resume command is appended without cursor movement or row erasure | Concurrent session and narrow terminal safety regressions |
| Machine output | After the one positioned interactive welcome field replacement, stdout/stderr, JSON, stream JSON, and schema constrained output remain byte preserving | One shot writer restoration, split UTF-8, callback order, and structured output regressions |

The manual checks named above are point in time verification, not CI coverage or
a guarantee about future account entitlements. Hosted tests use isolated fake
homes and service doubles so they never consume a real account session.

## Claude Code pass through contract

Claudex specific switches are parsed only as a leading prefix. Once the first
Claude Code argument is reached, the remaining command line is forwarded in
order. The documented pass through set includes `--continue`, `--resume`, `--fork-session`,
`--from-pr`, `--worktree`, `--tmux`, `--ide`,
`--plugin-dir`, `--mcp-config`, `--strict-mcp-config`, `--settings`,
`--system-prompt`, `--append-system-prompt`, `--output-format`,
`--input-format`, `--json-schema`, `--session-id`, `--debug`, `--verbose`,
`--brief`, `--bg`, `--chrome`, and `--no-chrome`.

Unknown options are also forwarded rather than silently dropped. That is an
argument preservation promise, not a claim that Claudex has independently
exercised every upstream feature or external integration represented by an
unknown option. `--remote-control` and `--rc` in the documented global option
prefix are the narrow exception: Claudex recognizes them so it can select the
clean first party profile before handing the remaining arguments to Claude
Code.

Claude maintenance and management subcommands (`agents`, `auth`, `auto-mode`,
`doctor`, `gateway`, `install`, `mcp`, `plugin`, `plugins`, `project`,
`setup-token`, `ultrareview`, `update`, and `upgrade`) bypass the GPT proxy and
Claudex session injection. This preserves the upstream command's
authentication, output, and configuration semantics. `--bare` and `--safe-mode`
likewise suppress custom agents, leader prompts, and the default permission
override. An explicit `--agents` or permission flag wins over the Claudex
default.

## Provider and platform boundaries

- Claude in Chrome requires a direct Anthropic plan and is not supported by
  Anthropic through third party model providers. `--claude-chrome` switches to
  the normal first party Claude profile; `--chrome` remains a literal
  pass through.
- Claude in Chrome supports Chrome and Edge, not WSL, Brave, Arc, or other
  Chromium variants.
- Native Windows Claude Code does not currently provide the same sandbox
  implementation as macOS, Linux, and WSL2. Claudex does not emulate an
  unavailable sandbox.
- Claude hosted Remote Control and Ultrareview use the clean first party Claude
  route rather than the Codex backed provider bridge. They can require a
  first party Claude login and use the Anthropic account's entitlement and
  billing context; service availability remains upstream controlled.
- Plugin, MCP, IDE, worktree, Git, hook, and cloud behavior can depend on
  project configuration and external services. Claudex preserves the documented
  Claude interfaces; it cannot make an unavailable external service succeed.
- `--bg` is forwarded and Claude Code detaches the agent. Claudex detaches its
  authentication and proxy recovery watchers as well, verifies the launcher's
  process identity, and keeps both watchers active while the managed
  `claude agents --json` registry contains any live session.
- Codex intentionally does not export access tokens through `account/read`.
  When Codex uses an OS keyring and no standard `auth.json` is present,
  `claudex --login` asks Codex itself to create a file backed local session.
  Claudex does not scrape undocumented keychain entries.
- Future upstream releases can remove or fundamentally change interfaces.
  Claudex detects supported optional Claude flags and fails with an actionable
  update message if the essential custom model interface disappears; it does
  not claim to predict arbitrary future breaking changes.

## Regression policy

The cross platform suites verify Claudex owned wrapper arguments,
authentication lifecycle, environment isolation, effort and Solplan modes,
conservative plan policy, permissions, task/agent policy, model labels, quota
sanitization, fallback behavior, resume attribution, status rendering,
compaction stabilization, cursor behavior, skills, and installers. A
classification in this document should be promoted only when both platform
implementations and the corresponding regression evidence exist. Upstream only
or account dependent behavior remains labeled pass through, first party only,
or not portable.

The shared Node.js bridge tests run on Node.js 18 and the hosted runners' current
Node.js version. Hosted platform jobs currently cover GitHub's current macOS,
Ubuntu, and x64 Windows images plus an Ubuntu 20.04 container. ARM64 and WSL
remain supported installer paths without dedicated hosted jobs. The live safe
version probes above are point in time evidence; CI uses isolated doubles for
account dependent behavior and cannot guarantee a future upstream release.
