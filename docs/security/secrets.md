<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Secrets

How credentials are handled in development and in CI.

## Rules

1. **No secret values in any repository**, private ones included. Repositories and configuration
   hold the *names* of secrets (`api_key_env = "OPENAI_API_KEY"`), never the values.
2. **Prefer no long-lived secrets.** CI reaches cloud providers and package registries through
   OIDC federation (trusted publishing on crates.io, PyPI and npm); community release artefacts are
   signed keylessly with Sigstore. Stored keys only where a requirement demands one (release signing for deployments that need a stored key, SC-02, in an HSM).
3. **One credential per environment and purpose**, with least privilege. Paid LLM keys carry a
   spend cap set at the provider.
4. **Fork safety.** Workflows triggered from forks never receive secrets. Paid benchmark tiers
   (T2–T4) run only on protected branches or by manual dispatch with a required reviewer.
5. **Detection.** `cargo xtask secrets` runs before every commit (pre-commit hook), in
   `cargo xtask ci`, and over the whole history before publication. The forge's secret scanning
   and push protection are on from the first public push.
6. **Rotation and revocation** follow the inventory below; any key that may have leaked is revoked
   first and investigated after.

## Inventory

| Secret | Used by | Lives in | Rotation | Introduced |
|---|---|---|---|---|
| LLM key (OpenRouter) for paid benchmarks and dev enrichment | developers; CI tiers T2–T4 | dev: `.env` (ignored) or a password manager; CI: forge environment `benchmarks` with a required reviewer; provider spend cap | 90 days; on staff change | now (dev), G09 (CI) |
| Local Postgres passwords | `memhouse up` | generated into the config file (mode 0600) | on demand (`memhouse down`, remove the volume, `memhouse up`) | exists |
| MemHouse API keys | deployments, agents | config file 0600 or `MEMHOUSE_API_KEY`; hashed per principal from G06; cloud: secret manager | per key; on staff or client change | exists, G06 |
| Community release signing | release pipeline | keyless Sigstore through CI OIDC; nothing stored | n/a | G21 |
| Package publishing (crates.io, PyPI, npm, container registry) | release pipeline | trusted publishing (OIDC); registry token scoped to the run | n/a | G21 |
| Homebrew tap and website pushes | release pipeline | GitHub App or fine-grained token limited to that repository, in environment `release` | 90 days | G21 |
| Stored release signing keys | release pipeline | HSM or cloud KMS, two-person approval | yearly | G29 |
| Customer-managed keys | deployments that require them | the customer's KMS | the customer's policy | G29 |

## In development

- Copy [`.env.example`](../../.env.example) to `.env` and fill it in. `.env` is ignored and the
  scanner refuses to let it be committed.
- Load it only for the command that needs it: `set -a; . ./.env; set +a`, or keep values in a
  password manager and use `op run --env-file=.env.example -- <command>` with `op://` references.
- Benchmarks read the key from the variable named by `--llm-key-env` (default `OPENAI_API_KEY`);
  nothing prints its value.

## The secret scanner

```bash
cargo xtask secrets              # working tree: tracked and untracked, not ignored
cargo xtask secrets --staged     # what the pre-commit hook runs
cargo xtask secrets --history    # every commit, before publication
cargo xtask secrets --repo ../other-repo   # another repository
cargo xtask install-hooks --repo ../other-repo   # its pre-commit and commit-msg hooks
```

It flags provider keys (OpenRouter, Anthropic, OpenAI-style, Stripe, AWS, GitHub, Slack, Google),
private keys, JWTs, URLs with a password, high-entropy values assigned to `*_KEY`, `*SECRET*`,
`*TOKEN*` or `*PASSWORD*`, and credential files (`.env`, `*.pem`, `*.key`, `*.tfstate`, SSH keys).
Placeholders (`memhouse:memhouse`, `***`, `${VAR}`, `<password>`, variable names) are ignored.

False positives:

- a fake value in a test: build it at run time, or end the line with `// secret-scan: allow`;
- a fake value already in the history: add its fingerprint (printed by the scanner) and the
  reason to [`.secret-scan-allow`](../../.secret-scan-allow). Changes to that file need an
  owner's review (`CODEOWNERS`). Never add a real credential to it.

## If a secret is committed

1. **Revoke or rotate it at the provider immediately**, even if the commit was never pushed.
   Removing it from git does not make it safe again.
2. Check the provider's usage logs for misuse since the commit.
3. Remove it from the working tree and, if it was committed, from history before any push
   (`git commit --amend`, or `git filter-repo` for older commits). Once pushed to a public forge,
   assume it is compromised regardless.
4. Record what happened and what changed in the private incident log.
