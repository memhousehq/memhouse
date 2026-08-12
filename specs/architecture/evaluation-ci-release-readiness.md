<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Evaluation, CI, And Release Readiness

Status: implemented on 2026-07-28.

Blocking automation and reproducible reports cover the frozen API baseline
through portability without changing the 38-Resource boundary. This implements
`AD-EVAL-1` through `AD-EVAL-5`, `NFR-1`,
`NFR-11`, and the evaluation framework's `EV-*` contracts. Retrieval remains
`f7-1`; evaluation evidence is versioned `f11-1`, and the application advances
to semantic version `0.2.0`.

## Deterministic gate

The external-Postgres CI lane runs Ash snapshot drift, formatting,
warnings-as-errors compilation, the complete ExUnit/property suite, Credo,
Sobelow, Hex retirement audit, and the deterministic release matrix. Dialyzer
has a cached dedicated lane. Existing tests from the Ash domain backbone
through portability, packaging, and operations supply the data-layer,
strategy, Account isolation, consent/promotion, cassette, MCP/HTTP/readiness
helper, and no-public-entity guardrails; the focused evaluation and release
test prevents the CI, version, surface inventory, and release contracts from
drifting.

The packaged-pg0 lane assembles the checksum-pinned pg0 and ABI-matched
pgvectorscale release, boots it from an
empty temporary data root, waits for `f10-1` readiness, and runs the same
complete source test suite against a separate database in that pg0 instance.
The build job runs only after external Postgres, pg0, and Dialyzer pass, then
builds both the Mix release and production container.

AshJsonApi OpenAPI and complete generated TypeScript/Python clients remain
unimplemented in `specs/roadmap/beta-roadmap.md`. The surface inventory marks them
`unavailable`, gates the shipped Phoenix/MCP and skill-readiness helper
contracts, and prevents any release's documentation or packaging from
presenting the skill-readiness helpers as complete SDKs.

## Evaluation boundary

`MemHouse.Eval.Adapter` now supports MemHouse, LoCoMo, LongMemEval, ConvoMem,
and BEAM source shapes. Every input carries a SHA-256. `Runner` records the
application version, date, dataset id/hash/split, profile and exact version,
strategy override, deadline setting, five model-role identities, judge method,
limits, and per-question evidence.

An opt-in dream-time evaluation runs the Account reasoning pass after ingest,
then replays it. Its report contains only durable counts: terminal pass states,
knowledge before and after, relation kinds, conflict reviews, supersession,
corroboration, and dream-reasoner usage. Validation rejects an unbalanced pass
total or any replay that creates a durable effect.

`Scorer` retains deterministic correctness, abstention, and citation measures
and adds lexical `f11-1` groundedness/context-relevance/answer-relevance plus
context, answer, end-to-end, full-context, and efficiency-ratio token measures.
Those lexical scores are reproducible baseline signals, not a claim of parity
with an upstream model judge.

The benchmark runner can also audit extracted-statement durability after the
ordinary pipeline writes them. Its report records only sample provenance,
category counts, and zero/one/multiple statement yield per source message.
The optional model judge must use a different provider/model family from the
ingest extractor. This audit is frontier evidence; it is not a release gate.

`specs/eval/release-suite.json` defines the release matrix and distinct
`held-out-tuning`/`release-evaluation` policy. Named-profile runs are release
guardrails; lexical and salience-recency variants are reported ablations.
`deterministic-thresholds.json` gates only correctness and citations. Quality,
latency, RAG-triad, token efficiency, and BEAM degradation remain
frontier-tracked as required by `AD-EVAL-3`, `NFR-1`, and `NFR-11`.

The 2026-07-27 minimal `poc-0` reports remain immutable pre-retrieval evidence,
not current `f7-1` results. `poc-0` is a historical contract tag.

## Release controls

MemHouse follows Semantic Versioning with a Keep-a-Changelog-style
`CHANGELOG.md`. `mix memhouse.release.check` fails unless:

- `mix.exs` contains valid SemVer and a matching dated changelog entry;
- the tag, when supplied, is exactly `v<version>`;
- the roadmap, README, AGENTS, and architecture evidence agree;
- a non-empty `f11-suite-1` report matches the application version; and
- every deterministic release threshold still passes.

CI builds on every pull request and `main` push. The nightly workflow retains
eval artifacts for comparison. Publishing a GitHub Release for an existing
semantic tag triggers the release workflow. A maintainer can also manually
retry an existing release tag after repairing release automation. Both paths
repeat deterministic guardrails, validate the tag/eval/changelog tuple, build
the checksum-pinned Linux x86_64 pg0 plus pgvectorscale package and container,
then build and boot-test native Linux ARM64 and Apple Silicon macOS packages.
Windows and Intel macOS use external PostgreSQL or a container.

A fan-in job attaches all three packages, their checksums, and the evaluation
report to that GitHub Release. The container is published to the repository's
GHCR package. Repository branch protection and
required-check selection remain GitHub settings performed by a maintainer; the
required job names are documented in the release checklist.

## Evidence

- `test/memhouse/f11_evaluation_ci_release_readiness_test.exs`
- `test/memhouse/eval/adapter_test.exs`
- `test/memhouse/eval/scorer_test.exs`
- `.github/workflows/ci.yml`
- `.github/workflows/eval.yml`
- `.github/workflows/release.yml`
- `specs/eval/release-suite.json`
- `specs/eval/deterministic-thresholds.json`
- `specs/eval/surface-contract-inventory.json`
- `specs/process/release-checklist.md`
- `specs/process/versioning.md`
