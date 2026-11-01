<!-- SPDX-License-Identifier: Apache-2.0 -->
# Contributing to MemHouse

Thanks for helping. This page says how to get a change in.

## Before you start

- Read [docs/roadmap.md](docs/roadmap.md): work is organised as numbered goals, and a change
  should fit the goal it belongs to.
- Larger changes to the API, the Memory Format or the policy model start as a short design note
  in an issue, so the direction is agreed before the code is written.

## Developer Certificate of Origin (DCO)

Every commit must be signed off. By signing off you certify the
[Developer Certificate of Origin 1.1](https://developercertificate.org/): that you wrote the change
or otherwise have the right to submit it under the project's licence.

```bash
git commit -s -m "Explain what changed and why"
```

This adds a `Signed-off-by: Your Name <you@example.com>` line, matching your `git config user.name`
and `user.email`. Commits without it are rejected by the `commit-msg` hook (below), and by the hosted CI once the
repository is published.
Forgot it? `git commit --amend -s` fixes the last commit; `git rebase --signoff main` fixes a branch.

## Set up

```bash
cargo xtask install-hooks     # pre-commit secret scan, commit-msg DCO check, pre-push CI
memhouse up                   # Postgres + pgvector for the tests and the benchmark guard
```

The [developer guide](docs/development.md) covers the build, the crates and the extension points.

## Before you push

```bash
cargo xtask ci
```

It runs formatting, licence headers, the secret scan, the dependency licence and advisory policy,
clippy, the unit tests, the end-to-end script, and the benchmark guard (quality must not drop; see
[roadmap section 3](docs/roadmap.md#3-the-benchmark-guard)). `cargo xtask ci --fix` applies
formatting and adds missing licence headers.

## Rules for a change

- **Licence headers.** Every source and doc file starts with an `SPDX-License-Identifier` line:
  `Apache-2.0` for code, `CC-BY-4.0` under `docs/`. `cargo xtask spdx --fix` adds them.
- **Dependencies.** Permissive licences only (see `deny.toml`). A copyleft dependency needs the
  maintainers' approval first.
- **Secrets.** Never commit credentials, `.env` files or real customer data. Use names of
  environment variables in config and code. The pre-commit hook scans every commit; if it flags a
  fake test value, construct it at run time or mark the line `secret-scan: allow`. Read
  [docs/security/secrets.md](docs/security/secrets.md).
- **Governance.** The governance suite stays at 100%, and a change that adds a safety property
  adds a check for it.
- **Docs.** Update the guide your change affects in the same pull request.
- **Style.** Match the surrounding code: naming, comment density and error messages that say what
  to do next.

## Reporting a vulnerability

Don't open a public issue. Follow [SECURITY.md](SECURITY.md).

## Conduct

Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).
