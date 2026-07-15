# Project governance

Claudex uses a lightweight maintainer-led governance model.

## Roles

- **Users** install Claudex, report problems, and participate in discussions.
- **Contributors** submit documentation, tests, code, and reviews under the MIT
  License.
- **Maintainers** are repository collaborators with merge and moderation
  permissions. They triage reports, review contributions, publish releases,
  and enforce project policies.

Roles are based on sustained, constructive participation rather than employer
or affiliation. Maintainers may invite contributors who demonstrate sound
judgment, reliable follow-through, security awareness, and respectful review.

## Decisions

Routine decisions happen in issues and pull requests. Maintainers seek rough
consensus, with priority given to security, user privacy, cross-platform
correctness, backward compatibility, and maintainability. When consensus is
not possible, maintainers make the final decision and document the reasoning.

Changes to authentication, credential handling, downloaded binaries, default
permissions, provider routing, or governance require explicit maintainer
review. Security fixes may be developed privately until disclosure is safe.

## Releases

Maintainers publish releases from a clean, tested `main` branch. Release tags
follow semantic versioning, and release notes summarize user-visible changes,
compatibility changes, and security fixes. See [CHANGELOG.md](CHANGELOG.md) and
[docs/development.md](docs/development.md).

## Project policies

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Contributing guide](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Support policy](SUPPORT.md)

This governance model may evolve through a documented pull request as the
community grows.
