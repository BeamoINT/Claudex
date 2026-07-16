# Claude Code and Codex skills

Claudex automatically makes existing Claude Code and Codex skills available in
ordinary GPT-backed sessions. Source skills are never moved, rewritten, or
deleted. Claudex creates a private compatibility view under
`~/.config/claudex/skill-bridge` for each project and passes that view to
Claude Code with its native skill-discovery interface.

## Discovered locations

| Ecosystem | Locations available inside Claudex |
| --- | --- |
| Claude Code personal | `~/.claude/skills/*/SKILL.md`, including skills-directory plugins |
| Claude Code legacy personal commands | `~/.claude/commands/*.md` |
| Claude Code project | `.claude/skills` and `.claude/commands`, discovered natively by Claude Code |
| Claude Code plugins | Enabled user, managed, and matching project plugin installations |
| Codex personal | `~/.agents/skills/*/SKILL.md` |
| Codex legacy/custom home | `$CODEX_HOME/skills/*/SKILL.md` |
| Codex project | `.agents/skills` and legacy `.codex/skills` from the launch directory through the Git repository root |
| Codex admin | `/etc/codex/skills` on Unix or `%ProgramData%\Codex\skills` on Windows |
| Codex plugins | Skills from installed and enabled Codex plugins, including Claude-format plugins installed through Codex |

Set `CLAUDEX_CLAUDE_CONFIG_DIR` when the normal Claude profile is not
`~/.claude`. Set `CLAUDEX_SKILL_EXTRA_DIRS` to an OS path-list of additional
Agent Skills directories.

## Invocation and compatibility

Claude Code's `/skill-name` form works for every standalone bridged skill.
Plugin skills retain their `/plugin-name:skill-name` namespace. Codex-style
`$skill-name` and `$plugin-name:skill-name` references are resolved by an
isolated, size-bounded `UserPromptSubmit` compatibility hook for both Claude
and Codex sources, including skills whose Codex policy disables implicit
invocation. Set
`CLAUDEX_SKILL_DOLLAR_REFERENCES=off` to disable only that hook. Run
`claudex skills` outside a session to list the exact aliases, sources,
compatibility plugins, and model mappings for the current project.

Both products implement the open Agent Skills `SKILL.md` format, so skill
instructions, scripts, references, assets, and relative paths stay intact.
Claudex applies only the compatibility adaptations that are necessary:

- Codex `agents/openai.yaml` with `policy.allow_implicit_invocation: false`
  becomes Claude Code `disable-model-invocation: true` while explicit
  invocation remains available.
- Claude skill model pins using Opus, Fable, Best, Sonnet, or Haiku family IDs,
  including `[1m]` selectors, map to Sol, Sol, Sol, Terra, or Luna for bridged
  personal, legacy-command, and plugin sources. Native project skills remain
  source-exact; Claudex's Claude-family runtime aliases still route their
  requests through the Codex/OpenAI gateway.
- Legacy Claude command Markdown is exposed as a skill without changing the
  original file.
- On Windows, the bundled `/usage-limit` skill uses native PowerShell syntax;
  Unix installations use Bash.

Claude-only frontmatter stays native when Claude Code understands it. Codex's
optional `agents/openai.yaml` interface metadata and dependency declarations
remain alongside the skill. A dependency still needs its corresponding tool,
MCP server, app, binary, or account authorization to be installed and enabled;
the skill bridge does not fabricate external services.

## Collisions and updates

For Claude skills, the source directory is the default identity. For Codex
skills, the required frontmatter `name` is the identity. When imported sources
collide, the highest-priority imported source keeps the short alias and every
source also receives a deterministic qualified alias such as `/claude-name`,
`/codex-name`, or `/codex-legacy-name`. Claude Code classifies compatibility
views supplied through `--add-dir` as additional-directory skills rather than
personal-profile skills. A native project or Claudex-managed isolated-profile
skill therefore keeps its short alias; an imported personal conflict receives
only a qualified alias instead of claiming personal-scope precedence it does
not have at runtime. Plugin namespaces remain separate. `claudex skills` shows
the resolved mapping rather than silently dropping either skill.

The bridge recomputes discovery on every launch and creates a hard-bounded,
content-addressed snapshot. The newest eight generations per project are kept,
with a global emergency cap, and abandoned staging directories are age- and
count-bounded. Scripts, references, assets, executable bits, and
metadata all participate in the fingerprint, so an active session cannot
change underneath the user. Source trees are never linked into the runtime
view. Escaping symlinks, special files, private keys, credential files, and
unreasonably large trees are rejected without blocking other skills. Codex
user and project `[[skills.config]]` entries with `enabled = false`, Claude
`skillOverrides` states (`on`, `name-only`, `user-invocable-only`, and `off`),
`defaultEnabled`, disabled plugins, and project plugin scope are respected.
Published generations are structurally validated before cache or last-known-
good reuse, and policy changes receive distinct generations so fallback never
crosses a compatibility-policy boundary.
Existing plugin packages are never loaded wholesale: Claudex copies only their
validated skill content into generated plugins and strips plugin manifests,
hooks, MCP configuration, agents, settings, and nested component roots from a
plugin-root skill. Legacy Claude plugin commands, including direct Markdown
component paths, are adapted into inert namespaced skills; their source plugin
runtime is never activated.

Use these opt-outs only when isolation is more important than sharing:

```text
CLAUDEX_SKILL_BRIDGE=off
CLAUDEX_SKILL_PLUGINS=off
CLAUDEX_SKILL_DOLLAR_REFERENCES=off
```

Direct `--claude-chrome`, `--bare`, `--safe-mode`, and maintenance commands do
not receive the compatibility overlay. Direct Chrome already uses the normal
Claude profile; bare and safe modes intentionally suppress Claudex additions.
