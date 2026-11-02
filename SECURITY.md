<!-- SPDX-License-Identifier: Apache-2.0 -->
# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately**, through GitHub's private vulnerability reporting:
[Report a vulnerability](https://github.com/memhousehq/memhouse/security/advisories/new) on the
repository's Security tab. It is the only channel; the report and the discussion stay private
until a fix is released.

Include what you found, how to reproduce it, the affected version or commit, and its impact as you
understand it. Please don't open public issues or discuss the problem publicly until a fix is
released.

What to expect:

| Step | Target |
|---|---|
| Acknowledgement | within 5 working days |
| First assessment and severity | within 20 working days |
| Fix released for supported versions | depends on severity; critical issues first |
| Public advisory with credit (if you want it) | when the fix is available |

## Supported versions

Before 1.0, security fixes go into the latest release. Supported lines after 1.0 are listed here.

## Scope

In scope: the `memhouse` binary and its crates, the server's REST and MCP endpoints, the CLI and
the benchmark tool. SDKs, container images and other artefacts join the scope when they are
published. The governance controls (redaction,
injection quarantine, isolation, deletion, audit chain) are described in
[docs/governance.md](docs/governance.md); a way around any of them is a vulnerability.

## Handling of secrets in this project

See [docs/security/secrets.md](docs/security/secrets.md). If you find a credential in this
repository or its history, report it the same way.
