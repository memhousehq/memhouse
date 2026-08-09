<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# MemHouse — Evaluation Framework

> **Status:** v1.0 — evaluation, CI, and release-readiness implementation
> contract.
>
> **Companions:** `memory-system-functional-requirements.md` defines what the
> product does; `memory-system-architecture-and-nfr.md` defines how it is built;
> this document defines how claims and release guardrails are validated.

## 1. Evaluation invariants

- **EV-INV-1 — Guardrails block.** A deterministic correctness, isolation,
  governance, privacy, migration, or surface-contract failure blocks a release.
- **EV-INV-2 — Frontier measures report.** Quality, latency, and token cost are
  measured and compared, but do not become hard gates without a reviewed
  threshold change tied to an architecture anchor.
- **EV-INV-3 — Real path.** Engine and product evaluations ingest, retrieve,
  answer, and cite through the shipped MemHouse path. A harness-only shortcut
  cannot support a public claim.
- **EV-INV-4 — Content safety.** CI logs, telemetry, release manifests, and
  benchmark metadata contain identities, hashes, counts, versions, metrics, and
  error classes—not customer content, prompts, answers, keys, or secrets.

## 2. Reproducibility

- **EV-REPRO-1 — Versioned evidence.** Every report records report schema,
  MemHouse semantic version, execution date, dataset id/SHA-256/split, retrieval
  profile and exact profile version, deadline setting, all five model-role
  identities, judge identity, run limits, and strategy override.
- **EV-REPRO-2 — Dataset immutability.** Dataset bytes are identified by
  SHA-256. A changed fixture is a new input even when its filename is unchanged.
- **EV-REPRO-3 — Deadline identity.** Reports say `enabled`, `disabled`, or
  `fixed`. Ablations and published comparisons use disabled or fixed deadlines.
- **EV-REPRO-4 — Semantic releases.** Application versions follow Semantic
  Versioning and have a dated `CHANGELOG.md` entry. A release tag is exactly
  `v<application-version>`.
- **EV-REPRO-5 — Dream-time accounting.** A report that enables dream-time
  records completed, throttled, and failed passes. Their sum equals attempted
  passes. It also records a replay with zero durable effects, reasoner usage,
  and content-safe relation, conflict, deduction, supersession, and
  corroboration counts.

## 3. Two tiers

### Deterministic PR and release guardrails

The blocking tier runs formatting, compilation with warnings as errors, Ash
snapshot drift, ExUnit tests and properties, Credo, Dialyzer, Sobelow, provider
cassettes, data-layer and retrieval-strategy contracts, Account isolation,
promotion/consent scenarios, surface contracts, and the no-public-entity rule.
It also runs the minimal release matrix with deterministic model roles and
checks the committed correctness/citation floors.

The same suite runs against external Postgres and packaged pg0. Both use the
same migrations, Ash actions, Oban engine, retrieval implementation, and tests.

### Nightly and release evaluation

The reported tier runs engine benchmarks, product evaluations, live or pinned
models where configured, deterministic scoring, optional model judging, token
efficiency, latency, and strategy ablations. A live provider credential is
never available to an untrusted pull request.

- **EV-GRADE-1 — Deterministic baseline.** Exact/contains/token-F1,
  abstention, citation hit/recall, lexical RAG-triad signals, token counts, and
  latency are always present.
- **EV-GRADE-2 — Judge separation.** A model judge is additional evidence and
  never replaces deterministic scoring.
- **EV-GRADE-3 — Independent judge.** When a model judge is used for a public
  number, its provider/model/version is recorded and differs from the answer
  model family.

## 4. Engine benchmarks

`EV-ENGINE` covers LoCoMo, LongMemEval, ConvoMem, and BEAM:

- LoCoMo reports overall and per-category recall/answer/citation measures.
- LongMemEval reports knowledge update, temporal reasoning, and abstention.
- ConvoMem reports preference, temporal/implicit connection, and abstention
  categories plus a full-context token baseline on the same corpus.
- BEAM reports a degradation curve by corpus-size bucket, never only a single
  headline score.

The adapters normalize source data, but all normalized cases use the same
runner and shipped memory surface.

## 5. Product evaluations

`EV-TASK` is the MemHouse-specific layer that public conversation benchmarks
cannot cover. Its blocking scenarios are mapped to existing deterministic
contracts:

- Account and scope isolation, including cross-link authorization;
- Gate A/B promotion, consent, and human/machine governance separation;
- correction, supersession, erasure, and audit continuity;
- reasoning-free context and stale/unknown abstention behavior;
- skill-readiness blockers, warnings, freshness, and elicitation return through
  ordinary ingest;
- portability integrity and pg0/external-Postgres parity.

Repeated-run error reduction, task outcomes, and behavior beyond 100K facts are
frontier-tracked product measures. They do not inherit credibility from an
engine benchmark score.

## 6. Metrics

- **EV-MET-1 — Correctness:** exact match, expected containment, token-F1, and
  benchmark/category accuracy.
- **EV-MET-2 — Grounding:** citation hit/recall and groundedness.
- **EV-MET-3 — Isolation:** cross-account and unauthorized-scope access remains
  impossible under generated operation sequences.
- **EV-MET-4 — RAG triad:** groundedness, context relevance, and answer
  relevance, with scoring method identified.
- **EV-MET-5 — Abstention:** correct abstention when relevant active/fresh
  knowledge is absent.
- **EV-MET-6 — Latency:** per-question latency plus mean, p50, p95, and max.
- **EV-MET-7 — Token efficiency:** context tokens and end-to-end ask tokens
  divided by full-context tokens on the same corpus (`NFR-11`).
- **EV-MET-8 — Degradation:** BEAM accuracy/grounding by corpus-size bucket.

Latency and token efficiency are frontier measures. Their raw values are not
release gates because corpus shape and machine load affect them.

## 7. Stage 0, tuning, and ablation

- **EV-STRAT-1 — Stage 0 first.** The checked-in 2026-07-27 `poc-0` minimal
  reports remain the pre-retrieval baseline; `poc-0` is a historical version tag
  rather than a roadmap phase. They are historical evidence, not current `f7-1`
  claims.
- **EV-STRAT-2 — Held-out tuning.** Fusion weights may be tuned only on the
  `held-out-tuning` split. The `release-evaluation` split never informs weights.
- **EV-STRAT-3 — Ablation matrix.** Each engine benchmark runs the named profile
  and independent lexical and salience-recency variants with deadlines disabled.
  Additional semantic/entity/relation variants are added when their pinned
  artifacts are present.
- **EV-STRAT-4 — Internal probes.** Strategy overrides and internal state probes
  remain eval/system-only and never become public request parameters.
- **EV-STRAT-5 — In-repository evidence.** Manifests, thresholds, fixtures,
  schemas, tasks, CI, and release rules live with the version they validate.

## 8. Release rule

A release is ready only when:

1. both database-mode CI lanes pass or an unavailable lane is explicitly
   recorded;
2. every deterministic guardrail passes;
3. the release matrix validates against `f11-1` provenance;
4. correctness/citation floors pass;
5. the semantic version, tag, changelog, README, AGENTS contract, and
   release-readiness roadmap evidence agree; and
6. the release and container builds complete from the gated commit.

Current transport coverage is recorded in
`specs/eval/surface-contract-inventory.json`. Generated OpenAPI and complete SDK
clients are explicitly unavailable in 0.2.0; they belong to the
integration-surfaces work (still to be implemented; tracked in
`specs/roadmap/beta-roadmap.md`). The release must not advertise them, and
release readiness requires that inventory to switch to gated evidence when those
surfaces land.
