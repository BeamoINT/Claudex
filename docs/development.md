# Development guide

Claudex is intentionally dependency-light. The production code is Bash,
PowerShell, a small Node preload, and JSON; the test harness uses fake homes and
fake provider commands so it never touches a developer's real sessions.

## Repository layout

| Path | Purpose |
| --- | --- |
| `claudex`, `claudex.ps1`, `claudex.cmd` | Cross-platform launchers |
| `install.sh`, `install.ps1`, `install.zsh` | Install and compatibility entry points |
| `codex-session*` | Authentication bridge |
| `usage-limit*` | Detailed and cached quota reporting |
| `statusline*` | Stable compact footer |
| `preload.cjs` | Byte-preserving Solplan input alias and one-shot interactive ChatGPT plan label |
| `settings.json`, `env.example` | Reproducible configuration templates |
| `test.zsh`, `test.ps1`, `test.sh` | Isolated cross-platform regressions |
| `scripts/check-docs.mjs` | Community-file and local documentation link validation |
| `.github` | CI and contribution templates |
| `docs` | User and maintainer documentation |

## Design rules

1. Do not modify the signed Claude Code binary.
2. Keep normal Claude Code state separate from `~/.config/claudex`.
3. Let Codex own login and logout.
4. Keep secrets out of arguments, logs, caches, tests, and Git.
5. Bind the compatibility service to loopback and verify downloaded assets.
6. Preserve unknown Claude Code arguments exactly.
7. Keep Bash and PowerShell behavior aligned.
8. Fail clearly when an essential upstream interface is unavailable.
9. Add a regression before considering a bug fixed.

## Tests

`./test.sh` executes `test.zsh` on macOS and Linux. The suite creates a
temporary home, installs test doubles for Codex, Claude Code, curl, and
CLIProxyAPI, and verifies launch arguments, state, auth, usage, rendering,
updates, and installation.

`.\test.ps1` provides the corresponding native Windows coverage. GitHub
Actions runs both suites on macOS, Ubuntu, and Windows for every pull request.

Documentation validation checks required community files, issue-form metadata,
and every relative Markdown link. Keep it part of both platform suites.

Useful focused checks:

```bash
node scripts/check-docs.mjs
node --check preload.cjs
bash -n claudex codex-session install.sh statusline usage-limit
zsh -n test.zsh
git diff --check
```

## Cross-platform changes

When changing shared behavior:

1. update both launcher or helper implementations;
2. add Unix and PowerShell assertions;
3. verify path quoting with spaces;
4. test missing tools and failed subprocesses;
5. consider Bash 3.2 on macOS and Windows PowerShell 5.1;
6. update docs and `env.example` if the public interface changes;
7. wait for all three hosted runners before merging.

Platform-specific differences are acceptable only when the upstream platform
lacks an equivalent feature. Document the boundary instead of pretending to
emulate security or browser behavior that does not exist.

## Updating CLIProxyAPI

The binary version and SHA-256 digests are security-sensitive. To update them:

1. use the official upstream release;
2. collect every macOS, Linux, and Windows x64/ARM64 asset used by the
   installers;
3. calculate each digest independently;
4. update both installers together;
5. run the full test matrix;
6. describe the upstream changes and digest verification in the pull request.

Never replace a digest just to make a failed download pass.

## Releasing

Maintainers release from a clean `main` branch after the post-merge matrix
passes:

1. update `CHANGELOG.md` and move Unreleased entries into a SemVer version;
2. run local tests and confirm hosted CI on `main`;
3. create an annotated `vMAJOR.MINOR.PATCH` tag on the verified main commit;
4. push the tag, which invokes the reusable full macOS, Linux, legacy-Linux,
   Windows, and package-artifact matrix against that exact tag;
5. after the matrix passes, let the release workflow build both archives and
   `SHA256SUMS` reproducibly from the explicit payload allowlist, rejecting
   non-regular source files and ignoring unlisted files under `bin/`, `docs/`,
   and `skills/`;
6. let the workflow create a private draft, attach and re-download the exact
   three verified assets, and only then publish it and mark it latest;
7. verify the latest-release link and the automatically triggered live website
   installer matrix.

A failed test, build, or upload leaves no public release. An interrupted upload
may leave a private draft; manually dispatch `release-assets.yml` with the same
annotated tag to resume it. A retry accepts only missing assets or existing
assets with identical SHA-256 digests. It refuses unexpected or mismatched
draft assets and never changes an already-published release.

For a package-manager release, also:

1. keep `package.json` and `CHANGELOG.md` on the same version;
2. verify `npm test` and `./scripts/check-release-artifacts.sh`;
3. wait for the release-assets workflow to publish both archives and
   `SHA256SUMS` from the verified tag;
4. update and test the BeamoINT Homebrew tap and Scoop bucket with the exact
   release-asset hashes;
5. submit the matching WinGet manifest and link its external review.

Publish only archives built from the verified release tag. Do not publish
credentials, installed state, or the downloaded CLIProxyAPI binary from a local
machine; CLIProxyAPI remains a verified install-time dependency.
When adding a release-time runtime or support file, add its exact path to the
payload in `scripts/build-release.sh` and extend the required-content checks
when installation depends on it.

## Review checklist

- The problem is demonstrated, not speculative.
- Behavior is consistent on supported platforms.
- Failure modes are actionable and safe.
- Credentials and identity data remain private.
- Tests cover success, failure, and stale-state cases.
- Documentation matches the implemented defaults.
- The diff contains no installed state or unrelated changes.
