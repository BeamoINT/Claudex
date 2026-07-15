# Claude Code compatibility audit

This audit targets Claude Code 2.1.210, the version used for the July 2026 production verification. Claudex is a launcher and compatibility layer, not a fork of the signed Claude Code binary. Unknown options and arguments are preserved in order and forwarded to Claude Code.

## Fully exercised Claudex paths

| Surface | Claudex behavior | Verification |
| --- | --- | --- |
| Interactive and print sessions | GPT-5.6 model aliases, status line, auto permissions, context controls, bounded retries, and leader guard are injected | Isolated argument tests and live Sol prompts |
| Sol, Terra, and Luna | Friendly names and one picker entry per real model | Proxy model inventory, launcher tests, and live Sol calls |
| Solplan | Friendly `/model solplan` entry backed by Claude Code's `opusplan` selector; Sol plans and Terra implements | Model-cache, alias-environment, and launcher regressions |
| Max effort | `--max-effort` maps to native `--effort max` and labels the session `max` | Isolated launcher test and live exact-output prompt |
| Ultracode | `--ultracode` enables session-only `ultracode`, `workflows`, and xhigh effort | Isolated launcher test and live exact-output prompt |
| Auto mode | Terra classifier is pinned through the Codex bridge, explicit named approvals are carried into classification, and Anthropic model IDs are rejected for classifier overrides | Environment, settings-schema, and doctor tests |
| Agents and tasks | Terra/Luna names expose the actual model; concurrency and no-recursion guards limit cooldown storms; Sol reconciles task state | Argument-contract tests |
| Context and compaction | 400k accounting, 280k automatic compaction, and session cache suppress transient false zero values | Status-line regression tests |
| Usage limits | Direct web response, cached outage behavior, low-quota alert, account selection, and app-server recovery | Fake-service regressions and live app-server query |
| Model picker and banner | Stable friendly labels through model metadata and the status line; non-interactive cleanup without rewriting fullscreen cursor frames | JSON/state, byte-stream, and interactive-frame regressions |
| Cursor and mouse | Native terminal cursor plus application pointer OSC with cleanup | Pseudo-terminal regression on macOS |
| macOS/Linux install | Bash installer, dependency selection, service startup, backups, and private permissions | Isolated install test and GitHub matrix |
| Native Windows install | PowerShell tool mode, CMD shim, native installer, backups, and private config | PowerShell isolated suite and GitHub Windows runner |
| Codex authentication | Standard Codex file-backed session is synchronized atomically; live account changes invalidate account-scoped state; logout removes the bridge | Logged-in, refreshed-session, switched-account, missing-file, and logged-out regressions |
| Claude Code updates | Installer checks immediately; launcher checks daily without blocking and negotiates optional flags from current `--help` | Capability and update scheduling regressions |
| Resume hints | Claude's generated resume footer is rewritten to the matching Claudex or direct-Chrome launcher | Byte-stream and concurrent-session regressions |

## Transparent Claude Code features

The following current Claude Code surfaces are forwarded without Claudex rewriting their arguments: `--continue`, `--resume`, `--fork-session`, `--from-pr`, `--worktree`, `--tmux`, `--ide`, `--remote-control`, `--plugin-dir`, `--mcp-config`, `--strict-mcp-config`, `--settings`, `--system-prompt`, `--append-system-prompt`, `--output-format`, `--input-format`, `--json-schema`, `--session-id`, `--debug`, `--verbose`, `--brief`, `--bg`, `--chrome`, and `--no-chrome`.

Claudex-specific switches are parsed only as a leading prefix. Once the first Claude Code argument is reached, the rest of the command line is forwarded literally so prompts and option values that resemble Claudex switches cannot be consumed accidentally.

Maintenance and management subcommands (`agents`, `auth`, `auto-mode`, `doctor`, `gateway`, `install`, `mcp`, `plugin`, `plugins`, `project`, `setup-token`, `ultrareview`, `update`, and `upgrade`) bypass the GPT proxy and Claudex session injection. This preserves the upstream command's authentication, output, and configuration semantics. `--bare` and `--safe-mode` likewise suppress custom agents, leader prompts, and the default permission override. An explicit `--agents` or permission flag wins over the Claudex default.

## Provider and platform boundaries

- Claude in Chrome requires a direct Anthropic plan and is not supported by Anthropic through third-party model providers. `--claude-chrome` switches to the normal first-party Claude profile; `--chrome` remains a literal pass-through.
- Claude in Chrome supports Chrome and Edge, not WSL, Brave, Arc, or other Chromium variants.
- Native Windows Claude Code does not currently provide the same sandbox implementation as macOS, Linux, and WSL2. Claudex does not pretend to emulate an unavailable sandbox.
- Claude-hosted features such as remote control and Ultrareview can require a first-party Claude login. Their management commands bypass the GPT proxy, but account entitlements and service availability remain upstream concerns.
- Plugin, MCP, IDE, worktree, Git, hook, and cloud behavior can depend on project configuration and external services. Claudex preserves those interfaces; it cannot make an unavailable external service succeed.
- Codex intentionally does not export access tokens through `account/read`. When Codex uses an OS keyring and no standard `auth.json` is present, `claudex --login` asks Codex itself to create a file-backed local session. Claudex does not scrape undocumented keychain entries.
- Future Claude Code releases can remove or fundamentally change interfaces. Claudex detects supported optional flags and fails with an actionable update message if the essential custom-model interface disappears; it does not claim to predict arbitrary future breaking changes.

## Regression policy

The repository's cross-platform tests verify wrapper arguments, authentication lifecycle, environment isolation, effort and Solplan modes, conservative plan policy, permissions, task/agent policy, model labels, quota sanitization, fallback behavior, resume rewriting, status rendering, compaction stabilization, cursor behavior, and installers. The runtime capability check handles additive CLI changes automatically; the matrix is extended whenever a release introduces a new behavior that needs Claudex-specific adaptation.
