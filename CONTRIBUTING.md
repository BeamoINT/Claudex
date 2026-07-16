# Contributing to Claudex

Thank you for helping make Claudex safer, clearer, and more portable. Bug
reports, documentation fixes, tests, design discussion, and focused code
changes are all welcome.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
General questions belong in [GitHub Discussions](https://github.com/BeamoINT/Claudex/discussions),
confirmed bugs and feature proposals belong in
[GitHub Issues](https://github.com/BeamoINT/Claudex/issues), and vulnerabilities
must be reported through the private process in [SECURITY.md](SECURITY.md).

## Find a contribution

- Browse [`good first issue`](https://github.com/BeamoINT/Claudex/labels/good%20first%20issue)
  for narrow tasks with a known approach.
- Browse [`help wanted`](https://github.com/BeamoINT/Claudex/labels/help%20wanted)
  for work where maintainer guidance is available.
- Improve documentation through the
  [documentation issue form](https://github.com/BeamoINT/Claudex/issues/new?template=documentation.yml).
- Read the [roadmap](ROADMAP.md) and start an Ideas discussion before building a
  large or cross-cutting feature.

If you want to help but no existing issue fits, open a Discussion. Maintainers
can help turn the idea into a reviewable issue before you invest significant
time.

## Before opening an issue

1. Update to the current `main` branch and rerun the installer.
2. Run `claudex --doctor` and remove credentials, account identifiers, paths,
   prompts, and session IDs before sharing its output.
3. Search existing issues and discussions.
4. Use the appropriate issue form and include the operating system, shell,
   Claude Code version, Codex CLI version, and a minimal reproduction.

Do not post OAuth tokens, `auth.json`, the generated proxy token, session files,
or the contents of `~/.config/claudex`.

## Development setup

Claudex has no package installation step. A development checkout needs:

- Git;
- Bash 3.2 or later and Zsh on macOS/Linux;
- PowerShell 5.1 or later for Windows changes;
- Node.js for terminal-filter and documentation checks;
- `jq` for the Unix test harness.

Fork the repository, clone your fork, and create a focused branch:

```bash
git clone https://github.com/YOUR-USER/Claudex.git
cd Claudex
git switch -c fix/short-description
```

Read [docs/development.md](docs/development.md) for the component map, testing
strategy, cross-platform expectations, and review checklist.

Draft pull requests are welcome for early design or cross-platform feedback.
You do not need every supported operating system locally: run the checks your
platform supports, list them exactly, and let GitHub Actions provide the full
matrix. Mark the pull request ready only after the documented behavior and
regression coverage are complete.

## Making changes

- Keep macOS, Linux, and Windows behavior aligned. Change the Bash and
  PowerShell implementations together unless a feature is platform-specific.
- Preserve the zero-configuration installer and existing private user state.
- Treat authentication, usage data, and session files as sensitive.
- Pin and verify every downloaded executable or archive.
- Preserve unknown Claude Code arguments exactly and avoid assuming future
  upstream interfaces.
- Add a regression for every bug fix.
- Update user documentation when behavior, flags, defaults, or limitations
  change.
- Keep changes focused; unrelated cleanup should use a separate pull request.

## Testing

Run the Unix suite on macOS or Linux:

```bash
./test.sh
```

Run the native Windows suite in Windows PowerShell:

```powershell
.\test.ps1
```

Before submitting, also run the lightweight syntax checks available on your
platform:

```bash
node --check preload.cjs
bash -n claudex codex-session install.sh statusline usage-limit
zsh -n test.zsh
```

GitHub Actions runs the complete isolated suite on macOS, Ubuntu, and Windows.
A pull request is not ready to merge until every required platform passes.

## Pull requests

Pull requests should:

- explain the problem and the user impact;
- describe the implementation and important tradeoffs;
- link related issues;
- list the exact checks that were run;
- include screenshots or terminal captures for visible changes, with sensitive
  data removed;
- be small enough to review confidently.

Maintainers may ask for revisions, additional tests, or a smaller scope. A
maintainer merges accepted changes after CI passes. No contributor license
agreement is required; contributors retain copyright in their work and license
their contribution under this repository's MIT License.

Contributors are responsible for every submitted line, including AI-assisted
work. Review generated changes, remove private or proprietary data, disclose
substantial automated assistance in the pull request when it affects review,
and provide the same tests and reasoning expected for manually written code.
Accepted contributions are credited through Git history, release notes when
user-visible, and the repository's
[contributors page](https://github.com/BeamoINT/Claudex/graphs/contributors).
