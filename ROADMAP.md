# Claudex roadmap

This roadmap describes project direction, not promised dates. Priorities may
change as Claude Code, Codex, operating systems, and community needs evolve.
Specific work is tracked in [GitHub Issues](https://github.com/BeamoINT/Claudex/issues)
and shaped in [GitHub Discussions](https://github.com/BeamoINT/Claudex/discussions).

## Current priorities

1. **Upstream compatibility** — detect Claude Code and Codex interface changes
   early, preserve unknown arguments, and keep macOS, Linux, WSL, and Windows
   behavior aligned.
2. **Safe installation and updating** — keep downloads reproducible and
   checksum-verified, make updates recoverable, and expand verified package
   manager availability without weakening the trust boundary.
3. **Skills and plugin interoperability** — preserve existing Claude and Codex
   skills non-destructively while improving collision handling, diagnostics,
   policy compatibility, and project scoping.
4. **Terminal experience** — maintain stable fullscreen rendering, clear model
   and agent activity, accessible output, actionable failures, and minimal
   startup noise.
5. **Contributor experience** — grow well-scoped starter issues, improve
   fixtures and focused tests, document architectural decisions, and reduce the
   cost of validating cross-platform changes.

## Good community contributions

- safe regression fixtures for new upstream versions or operating systems;
- documentation examples and troubleshooting improvements;
- focused accessibility and terminal-rendering fixes;
- package-manager validation and installation diagnostics;
- tests that demonstrate a confirmed compatibility or concurrency bug.

Browse [`good first issue`](https://github.com/BeamoINT/Claudex/labels/good%20first%20issue)
or [`help wanted`](https://github.com/BeamoINT/Claudex/labels/help%20wanted), or
start an [Ideas discussion](https://github.com/BeamoINT/Claudex/discussions/categories/ideas)
before investing in a large design.

## Non-goals

Claudex will not patch the signed Claude Code executable, bypass provider
entitlements or safety controls, expose a local credential bridge publicly by
default, silently upload private user state, or trade checksum verification for
installation convenience.
