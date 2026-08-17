<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Simplified-memory component retirement manifest

Status: no physical retirement approved.

This is the deletion decision record for issues #285 and #295. It applies the
component-retirement gate in ADR 0021 to the matched experiment harness and
deterministic comparison fixture registered by #287. The fixture proves the
artifact and gate contract; it is not benchmark evidence, held-out category
evidence, or a replacement for packaged-pg0, external-PostgreSQL,
restore/import, compatibility-window, or human architecture review.

The accepted implementation therefore simplifies the experimental execution
path without deleting the current rollback path. With the `minimal` profile,
ordinary recall executes independently bounded direct/derived semantic recall
and lexical retrieval only. The additional
stages below are not executed by that profile, but their code and rebuildable
state remain available to the current profiles during the compatibility
window.

## Evidence used

- `specs/eval/experiments/memory-profile-ablation.json`
  preregisters the executable smoke comparison and thresholds. It deliberately
  binds the real `balanced` and `minimal` defaults through the harness's closed
  executable-component map. Semantic evaluation must use the real configured
  embedder and may not substitute fake vectors; an offline run needs the pinned
  local artifacts already installed.
- `specs/eval/results/profile-experiment-fixture-manifest.json` pins the
  deterministic fixture environment and records PostgreSQL as the only
  supported engine.
- `specs/eval/results/profile-experiment-fixture-bundle.json` records equal
  synthetic contract values for accuracy, recall, citation hit rate,
  abstention accuracy, tokens, and recall latency, with zero unsupported
  claims, isolation leaks, dropped strategy runs, or dream replay effects. Its
  `reports: null` and fixture revision prevent it from being presented as an
  executed benchmark.
- The source, schema, authorization, replay, and budget contract tests named in
  the comparison bundle are deterministic safety evidence.

Together with the deterministic safety suites, this evidence supports an
opt-in implementation canary. It does **not** establish marginal value by
question category, a production latency/cost improvement, or safe schema
deletion.

## Decision manifest

| Component | Experimental replacement | Current decision | Missing retirement evidence |
| --- | --- | --- | --- |
| Temporal retrieval seed | Direct/derived semantic + lexical recall; bounded source fallback | Retain for current profiles; bypass in `minimal` | Held-out temporal/update category ablation |
| Salience-recency seed | Query-dependent dual-lane semantic + lexical rank | Retain; bypass in `minimal` | Preference/importance category ablation |
| Entity-match seed and mention refresh | Stable identity profile plus direct evidence | Retain; bypass in `minimal` | Entity-heavy category quality and projection-cost evidence |
| Relation expansion | Bounded source search and typed evidence lineage | Retain; bypass in `minimal` | Multi-hop marginal gain/loss and fan-out evidence |
| Model reranking | Deterministic fusion over the two minimal lanes | Retain for `thorough`; bypass in `minimal` | Matched rerank quality, token, cost, and p95 ablation |
| Context projections | Live bounded recall remains the miss fallback | Retain | Serving latency and queue-cost comparison plus rollback rehearsal |
| Multi-list fusion knobs | Two-lane reciprocal-rank fusion | Retain while current profiles remain public | Compatibility-window completion and contract-version decision |
| Dream synthesis operation | Update-only dream pass | Keep disabled by default | Matched deduction-quality gain after calls/tokens/cost |

Durable observations, governed Knowledge, source attribution, lifecycle,
consent, audit, and usage records are outside the deletion set. Vector,
full-text, mention, relation, and projection data are rebuildable, but that
does not make an unreviewed drop safe.

## Compatibility and cleanup gate

The previous profiles remain selectable for at least one released
compatibility window after a human approves any default change. During that
window rollback is a configuration change and never rewrites durable records.
After the window, a follow-up migration may drop a derived index/table only
when all of these artifacts are attached to the retirement decision:

1. held-out marginal ablation by registered category;
2. external-PostgreSQL and packaged-pg0 full gates;
3. backup/restore and logical export/import rehearsal;
4. rollback rehearsal from the candidate default to the compatibility profile;
5. dead-code/configuration/documentation search; and
6. human architecture, migration, and release approval.

SQLite is intentionally absent. ADR 0003 and ADR 0021 define backend parity as
external PostgreSQL and packaged pg0 running the same PostgreSQL schema.
