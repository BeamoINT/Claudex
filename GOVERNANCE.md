# Project governance

Claudex uses a lightweight maintainer led governance model.

## Roles

- **Users** install Claudex, report problems, and participate in discussions.
- **Contributors** submit documentation, tests, code, and reviews under the MIT
  License.
- **Maintainers** are repository collaborators with merge and moderation
  permissions. They triage reports, review contributions, publish releases,
  and enforce project policies.

The current maintainer roster, response targets, label policy, and release
responsibilities are documented in [MAINTAINERS.md](MAINTAINERS.md).

Roles are based on sustained, constructive participation rather than employer
or affiliation. Maintainers may invite contributors who demonstrate sound
judgment, reliable follow through, security awareness, and respectful review.

## Decisions

Routine decisions happen in issues and pull requests. Maintainers seek rough
consensus, with priority given to security, user privacy, cross platform
correctness, backward compatibility, and maintainability. When consensus is
not possible, maintainers make the final decision and document the reasoning.

Changes to authentication, credential handling, downloaded binaries, default
permissions, provider routing, or governance require explicit maintainer
review. Security fixes may be developed privately until disclosure is safe.

Maintainers disclose material conflicts of interest and avoid being the sole
reviewer of a change when another active maintainer is available. Major
decisions should record the problem, alternatives, compatibility impact, and
reasoning in an issue, discussion, or pull request.

## Releases

Maintainers publish releases from a clean, tested `main` branch. Release tags
follow semantic versioning, and release notes summarize user visible changes,
compatibility changes, and security fixes. See [CHANGELOG.md](CHANGELOG.md) and
[docs/development.md](docs/development.md).

## Project policies

- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Contributing guide](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Support policy](SUPPORT.md)
- [Maintainer guide](MAINTAINERS.md)
- [Roadmap](ROADMAP.md)

This governance model may evolve through a documented pull request as the
community grows.
