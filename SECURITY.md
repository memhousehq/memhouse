<!-- SPDX-License-Identifier: Apache-2.0 -->
# Security policy

> **Draft.** The reporting channel below is confirmed by the founder before the repository is
> published (roadmap goal G09).

## Reporting a vulnerability

Please report vulnerabilities **privately**: through the forge's private vulnerability reporting
("Report a vulnerability" on the repository's Security tab) once the repository is public, or by
email to the security contact listed here at publication.

Include what you found, how to reproduce it, the affected version or commit, and its impact as you
understand it. Please don't open public issues or discuss the problem publicly until a fix is
released.

What to expect:

| Step | Target |
|---|---|
| Acknowledgement | within 3 working days |
| First assessment and severity | within 10 working days |
| Fix released for supported versions | depends on severity; critical issues first |
| Public advisory with credit (if you want it) | when the fix is available |

## Supported versions

Before 1.0, security fixes go into the latest release. Supported lines after 1.0 are listed here.

## Scope

In scope: the `memhouse` binary and its crates, the server's REST and MCP endpoints, the CLI, the
SDKs, the published container images and Helm chart. The governance controls (redaction,
injection quarantine, isolation, deletion, audit chain) are described in
[docs/governance.md](docs/governance.md); a way around any of them is a vulnerability.

## Handling of secrets in this project

See [docs/security/secrets.md](docs/security/secrets.md). If you find a credential in this
repository or its history, report it the same way.
