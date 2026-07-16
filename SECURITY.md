# Security policy

Claudex handles local authentication material and launches a loopback
compatibility service, so security reports are taken seriously.

## Supported versions

Security fixes are applied to the latest release and the `main` branch. Older
releases and unmerged forks are not supported. Before reporting a problem,
confirm it still exists on the latest release when it is safe to do so.

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability and do not include
real credentials in a reproduction.

Use GitHub's private vulnerability reporting form:

<https://github.com/BeamoINT/Claudex/security/advisories/new>

Include:

- the affected version or commit;
- operating system and shell;
- impact and realistic attack scenario;
- minimal reproduction steps;
- suggested remediation, if known;
- whether the issue is already public.

Replace all OAuth tokens, generated proxy keys, account IDs, paths, prompts,
and session IDs with placeholders. Maintainers will acknowledge the report,
investigate it, coordinate a fix, and credit the reporter unless anonymity is
requested.

Claudex is volunteer maintained. The project targets acknowledgement within
three business days, an initial impact assessment within seven days, and a
status update at least weekly while a validated report remains unresolved.
These are response targets rather than a support SLA. Disclosure timing is
coordinated with the reporter and may be delayed long enough to prepare and
ship fixes across every supported platform.

## Safe testing and disclosure

Good faith research is welcome when it:

- uses only accounts, machines, and data you own or are authorized to test;
- avoids privacy violations, service disruption, persistence, and accessing
  more data than the minimal proof requires;
- stops after confirming the issue and reports it privately without exploiting
  other users;
- follows applicable law and upstream provider terms.

The project will not pursue action against research that follows these rules
and makes a reasonable effort to avoid harm. This safe harbor statement cannot
authorize testing against third party systems or override their policies.

## Security boundary

Claudex:

- reads the standard local Codex file backed session;
- writes a minimal bridge credential into a mode restricted private directory;
- binds its compatibility service to `127.0.0.1` by default;
- generates a local 256-bit proxy key;
- downloads a pinned CLIProxyAPI archive over HTTPS and verifies its SHA-256
  digest before installation;
- stores only sanitized quota values in its usage cache.

Claudex does not commit credentials, upload local session files, or print OAuth
tokens. It cannot secure a compromised machine, an unsafe fork, a manually
exposed proxy port, or third party software outside this repository.

See [docs/architecture.md](docs/architecture.md) for the data flow and trust
boundaries.
