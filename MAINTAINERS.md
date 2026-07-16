# Maintainers

Claudex uses a small maintainer-led model with transparent decisions in public
issues, discussions, and pull requests whenever security and privacy permit.

## Active maintainers

| Maintainer | Responsibilities |
| --- | --- |
| [@BeamoINT](https://github.com/BeamoINT) | Repository administration, triage, review, security response, releases, and community moderation |

Maintainer status reflects active responsibility rather than ownership of
community contributions. New maintainers may be invited under the criteria in
[GOVERNANCE.md](GOVERNANCE.md).

## Triage and response targets

Claudex is volunteer-maintained, so these are targets rather than service-level
agreements:

- acknowledge actionable bugs and pull requests within seven days;
- ask for missing reproduction details before labeling an issue confirmed;
- route support questions to Discussions and suspected vulnerabilities to the
  private process in [SECURITY.md](SECURITY.md);
- explain duplicate, declined, or out-of-scope decisions before closing;
- keep `good first issue` tasks narrow, documented, and free of hidden design
  decisions;
- add `help wanted` only when maintainers can review and support the work.

Issues that need more information may be closed after 30 days without a reply,
but can be reopened when the requested evidence is available. Confirmed bugs
are not closed solely because they are old.

## Label guide

| Label family | Meaning |
| --- | --- |
| `bug`, `enhancement`, `documentation`, `question` | Contribution type |
| `area: ...` | Primary component or maintenance surface |
| `platform: ...` | Platform-specific impact |
| `good first issue`, `help wanted` | Maintainer-supported contribution opportunities |
| `needs reproduction` | More evidence is required before implementation |
| `dependencies` | Automated or manual dependency maintenance |
| `breaking change` | Requires migration notes and explicit maintainer review |

Security vulnerabilities are never tracked with a public security label. Use a
private GitHub Security Advisory instead.

## Pull request and release policy

Every pull request must pass the required cross-platform checks and receive
maintainer review. Sensitive changes to authentication, installers, updates,
download verification, provider routing, permissions, or release workflows
require code-owner approval. Maintainers use squash merging for a readable
history and credit contributors in release notes when their work ships.

Releases are built only from annotated tags on a green `main` commit. The
release workflow verifies the exact archives before publication, and the public
website installers are tested from fresh Linux, macOS, and Windows runners
afterward. See [docs/development.md](docs/development.md) for the operational
release checklist.
