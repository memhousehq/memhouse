# Security Policy

MemHouse is pre-release software. This policy records the project's initial
security posture and reporting expectations for issue #7; it should be refined
by a human maintainer before the project has a public supported release.

## Supported versions

MemHouse does not yet have a stable supported release line.

| Version | Supported |
| --- | --- |
| Pre-release / `main` | Best-effort security review only |
| Public stable releases | Not yet available |

Until the release policy is finalized, security fixes may land on `main` without
backports. A human maintainer must update this table when MemHouse publishes a
supported version.

## Reporting a vulnerability

Do not report suspected vulnerabilities by opening a public GitHub issue.

A human maintainer still needs to provide and confirm the official disclosure
contact before this policy is complete. Until that contact exists, coordinate
privately with the project maintainer who directed your work, and include only
the minimum information needed to establish a secure reporting channel.

When reporting, include:

- Affected component, deployment mode, and version or commit when known.
- A concise description of impact and exploitability.
- Reproduction steps, proof-of-concept details, or logs with secrets and PII
  removed.
- Whether tenant isolation, authentication, authorization, audit integrity,
  model/provider keys, restricted content, or personal data may be affected.

## Safe handling expectations

MemHouse's architecture treats user data, keys, and tenant boundaries as hard
security requirements:

- Users own their data and keys. Secrets, model/provider keys, API keys,
  credentials, and encryption material must not be committed, logged, copied
  into issues, or included in screenshots.
- Cross-account isolation is absolute. Account identity must be derived from the
  authenticated identity, not from request parameters, and any suspected
  cross-tenant read, write, cache, blob, secret, audit, or model-routing leak is
  security-sensitive.
- Do not log or disclose PII, restricted content, customer data, prompts,
  completions, embeddings, raw observations, audit payloads, or tenant-scoped
  identifiers unless the data is explicitly approved for that purpose and
  minimized to the least sensitive form.
- Prefer references, redacted examples, hashes, synthetic fixtures, or
  maintainer-provided test data when documenting security behavior.
- Treat secrets backends, model credentials, blob namespaces, audit chains,
  tenant filters, RLS policies, exports, and derived caches as sensitive review
  areas.

## Security-sensitive changes

Changes that affect authentication, authorization, tenancy, secrets, PII or
restricted-content handling, auditability, exports, model-key routing, pipeline
promotion, or deployment security require human security review before merge.
This includes documentation-only changes that alter stated security guarantees
or disclosure expectations.

Security review must preserve the product invariants in `AGENTS.md`, above all
user-owned data and keys, and absolute Account isolation with the Account
derived from identity rather than from a request parameter.
