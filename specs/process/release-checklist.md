<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Release Checklist

This checklist is the evaluation, CI, and release-readiness gate for
`AD-EVAL-1` through `AD-EVAL-5`, `FR-PLAT-2`, `FR-PLAT-4`, `FR-PLAT-5`,
`NFR-1`, and `NFR-11`.

## Prepare

- [ ] Choose the SemVer bump under `versioning.md`.
- [ ] Update `mix.exs`, `CHANGELOG.md`, and any changed protocol identity.
- [ ] Confirm README, AGENTS, roadmap, architecture, operations, and eval docs
  describe the same release.
- [ ] Confirm every public quality number has dataset id/hash/split, date,
  profile/version, deadline, five model-role identities, judge method, and run
  limits.
- [ ] Confirm tuning used only the held-out split.

## Deterministic guardrails

- [ ] `mix deps.get`
- [ ] `mix ash.codegen --check`
- [ ] `mix format --check-formatted`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`
- [ ] `mix credo --strict`
- [ ] `mix dialyzer`
- [ ] `mix sobelow --config`
- [ ] `mix hex.audit`

## Evaluation and parity

```bash
mix memhouse.eval.release \
  --no-model \
  --assert-thresholds \
  --output /private/tmp/memhouse-release-eval.json

mix memhouse.release.check \
  --tag "v$(sed -n 's/.*version: \"\\([^\"]*\\)\".*/\\1/p' mix.exs)" \
  --eval-report /private/tmp/memhouse-release-eval.json
```

- [ ] External-Postgres deterministic gate passed.
- [ ] Packaged-pg0 readiness and full-suite lane passed.
- [ ] Mix release and production container builds passed.
- [ ] Frontier changes in quality, abstention, latency, token efficiency, and
  BEAM degradation have an explanation even when guardrail floors pass.
- [ ] Any unavailable lane or surface is explicitly present in the release
  evidence; do not describe it as shipped.
- [ ] A simplified-memory default or component-retirement decision links its
  matched experiment, compatibility window, external-PostgreSQL and
  packaged-pg0 evidence, rollback rehearsal, and human approval. A fixture-only
  result may enable a canary but may not authorize deletion.

## Publish

- [ ] Run **Prepare release PR** from `main`, entering the chosen version
  without `v`, then merge the generated release-preparation PR. The merge
  creates `v<version>`, publishes the GitHub Release, and starts the artifact
  workflow.
- [ ] Configure `MEMHOUSE_RELEASE_SIGNING_KEY` as the protected base64 Ed25519
  private key matching the updater's embedded public key; never place it in the
  repository or a release asset.
- [ ] Wait for the GitHub-Release-triggered workflow to run every gate, build
  and boot-test all packages, upload their SHA-256 files and the `f11-suite-1`
  report, and publish the versioned GHCR container. Stable releases also
  advance the container's `latest` tag.

GitHub rulesets should require:

- `Deterministic gate (external Postgres)`
- `Dialyzer`
- `Deterministic gate (packaged pg0)`
- `Release and container builds`

Rulesets and publishing permissions are repository settings and remain a human
maintainer action.
