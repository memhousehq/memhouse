# ADR 0004: Multi-strategy retrieval with deadline-bounded fusion

## Status

Accepted. One sub-question is left open for the maintainer: whether any
retrieval strategy may be enterprise-gated (see the Open question section).

**Amended by ADR 0006** (`specs/adr/0006-entity-resolution.md`): the strategy set
gains `EntityMatch`, `RelationExpand` gains shared-entity edges, and Stage 4 is
retargeted from the knowledge graph to the entity graph. Amendments are marked
in place below.

This ADR adds retrieval query parameters and a named-profile concept to the
public surface. Both are additive, so this is not a breaking API change under
ADR 0002. The licensing sub-question *is* an ADR 0002 human-only decision area
and is therefore recorded as open rather than decided here.

## Context

`AD-SEAM-3` combined candidate generation, ranked-list fusion, and reranking in
one `RetrievalStrategy`. That prevented independent extension, measurement, and
ablation.

Hindsight runs semantic, keyword/BM25, graph, and temporal retrieval
concurrently before cross-encoder reranking. Its reported 94.6% LongMemEval
score and 100–600ms band support the structural choice: different query shapes
benefit from different mechanisms, and concurrent cheap strategies cost about
as much as the slowest one.

MemHouse already indexes belief-time, valid-time, salience windows, and
`as_of(D)` (`FR-KN-17`, `FR-API-23`, `AD-DATA-1`), making temporal retrieval an
indexed range scan. Since ADR 0003, every strategy also uses one Postgres pool.
`Task.async_stream` with `on_timeout: :kill_task` bounds fan-out wall time.

Multi-strategy retrieval belongs on `ask` and `search`. It does not fit
`get_context`'s reasoning-free ~100ms target (`NFR-1`, `NFR-2`).

## Decision

### One seam becomes three

`AD-SEAM-3`'s retrieval seam splits into three named seams:

1. **Candidate generation** — N `MemHouse.Retrieval.Strategy` modules, each
   producing a ranked candidate list independently.
2. **Fusion** — merging N ranked lists into one.
3. **Rerank** — an optional, expensive precision pass over the fused head. This
   is the existing `Reranker` capability behaviour from `AD-MODEL-1`, not a new
   one; ADR 0004 only fixes where it sits in the pipeline.

The other three domain strategies named in `AD-SEAM-3` — the gate/auto-accept
matrix, chunking, and model-tiering — are unaffected.

### The strategy behaviour

```elixir
defmodule MemHouse.Retrieval.Strategy do
  @callback name() :: atom()
  @callback cost_class() :: :cheap | :moderate | :expensive
  @callback stage() :: :seed | :expand
  @callback applicable?(Query.t()) :: boolean()
  @callback candidates(Query.t(), Budget.t()) ::
              {:ok, [Candidate.t()]} | {:error, term()}
end
```

A `Candidate` carries `id`, `score`, `rank`, `strategy`, and `evidence`.
Scores are strategy-local and **not comparable across strategies**. A `Budget` carries
`deadline_ms`, `started_at` (from the injected clock, `AD-EVAL-4`), and
`max_candidates`.

`applicable?/1` keeps query gating inside each strategy; there is no central
planner to update when strategies change.

`stage/0` separates concurrent `:seed` strategies from `:expand` strategies
that consume the seed heads. Total wall time is the seed deadline plus the
expand deadline.

### The strategies

- **`Semantic`** — pgvector ANN over the embedding column. Seed.
- **`Lexical`** — PG-FTS/BM25. Seed. Carries exact tokens, identifiers, and
  proper nouns that embeddings blur.
- **`Temporal`** — indexed interval filter over belief-time, valid-time, and
  relevant-window, honouring `as_of`. Seed. Cheapest strategy we have and the
  one with the highest expected benchmark points per millisecond, because
  LongMemEval's temporal-reasoning and knowledge-update categories are exactly
  what it addresses.
- **`SalienceRecency`** — ranks on the precomputed salience × durability ×
  recency terms of the `FR-API-10` scoring function. Embedding-free, so it works
  when there is no query embedding yet. Seed.
- **`RelationExpand`** — hop-1 over `supersedes`, A-MEM upkeep links, and
  `ScopeRelation` edges from the seed head. Expand.
- **`Graph`** — deferred, over the dream-time knowledge graph. Seed or expand
  depending on the query; the seam is reserved, the module is not written.
  *Amended by ADR 0006:* no longer attached to a stage — stage 4 is retargeted
  to the entity graph.
- **`EntityMatch`** — *added by ADR 0006.* Statements mentioning the canonical
  entities a query's surface forms resolve to, ranked by mention confidence
  combined with the statement's own score. Cheap, seed, in `:balanced` and
  `:thorough`. `RelationExpand` gains shared-entity edges alongside its
  structural ones.

### Fusion is reciprocal rank fusion

`score(d) = Σ_s w_s / (k + rank_s(d))`, with `k = 60` and per-strategy weights
`w_s` from configuration.

Cosine similarity, BM25, and interval overlap use incompatible scales.
Score-based fusion would require recalibration after model, analyzer, or corpus
changes. RRF needs only meaningful within-strategy rank order.

RRF discards magnitude, so every strategy applies `min_score` and
`max_candidates` before fusion instead of returning weak noise.

### Deadline-bounded fan-out

Each phase uses `Task.async_stream` with `on_timeout: :kill_task` and
`ordered: false`. Fusion uses completed results; timeouts are dropped without
retry or request failure. The harness, not each strategy, enforces the budget.

Every response reports contributed and dropped strategies for operations and
ablation.

Because load can change the completed strategy set, evaluation disables
deadlines or uses a fixed deadline and fake clock (`AD-EVAL-4`).

### Named, versioned profiles

A profile is a strategy set plus weights plus rerank on/off.

- **`:fast`** — `Semantic` + `SalienceRecency`, no rerank. Live fallback for a
  `get_context` cache miss.
- **`:balanced`** — `Semantic` + `Lexical` + `Temporal`, RRF, no rerank. Default
  for `search`.
- **`:thorough`** — all seed strategies + `RelationExpand` + cross-encoder
  rerank. Default for `ask`.

Profiles are **versioned**. Published benchmarks must cite the profile version.

### Selection is layered in three places

This maps onto `AD-CFG-1`'s existing two-kinds split:

1. **`config/runtime.exs`** (infra) — which strategy modules are enabled at all
   on this deployment, and the deadline ceilings.
2. **DB policy config, scope-level nearest-wins inheritance** (policy) — default
   profile and fusion weights per scope, at the same grain as visibility and
   RBAC.
3. **Per-query** — `retrieval_profile: :fast | :balanced | :thorough`.

A raw `strategies: [...]` list is internal/eval-only so module names do not
become public contracts.

### `get_context` stays a projection read

`get_context` does **not** fan out. It reads materialized projections
(`AD-DATA-3`) from ETS/`persistent_term` as required by `NFR-2`.
Multi-strategy retrieval builds those projections at dream-time, moving
expensive retrieval and reranking off the serving path.

### Abstention gets a new input, not a new mechanism

`AD-MODEL-3` and `FR-API-26` still require in-loop citations, surface absent or
stale knowledge as unknown, and support a schema-valid "insufficient memory"
result.

What ADR 0004 adds is a signal and a warning.

**Cross-strategy disagreement** joins confidence-at-read (`AD-DATA-2`) as an
abstention input. Disjoint, low-scoring results from independent strategies are
evidence that the corpus lacks the answer.

Compute abstention **before fusion**. RRF always produces ranks, even from weak
inputs, so fused rank cannot indicate that nothing was found.

## Consequences

- Strategies can be ablated as benchmark × strategy set × profile, with
  deadlines disabled and per-category scores.
- A false-positive `applicable?/1` adds bounded latency and low-ranked
  candidates, not a correctness failure.
- More read-path components increase test and ablation coverage needs.
- Fusion weights can overfit. Tune only on held-out data; keep weights in
  configuration so deployments can retune without a release.
- Published scores must name the profile version and deadline setting.
- Thorough dream-time projection builds cost more, but budget shedding makes
  the failure mode stale projections rather than a stalled queue.

## Staging

- **Stage 0:** record LongMemEval and LoCoMo per-category baselines through the
  real API before strategy work.
- **Stage 1:** add `Temporal`, the cheapest strategy over existing indexes.
- **Stage 2:** add seed self-gating, `RelationExpand`, and the two-phase
  deadline.
- **Stage 3:** rerank the fused head for `ask` and `search` in `:thorough`.

**Stage 4 — ~~dream-time knowledge graph and the `Graph` strategy~~ entity graph
and `EntityMatch`.** *Retargeted by ADR 0006.* The stage is now entity
resolution and the `EntityMatch` seed strategy: canonical referents derived at
dream-time from already-validated statements, one entity per real-world thing
plus an annotation per mention. Same gating constraint as the original stage,
far less derived structure.

The knowledge-graph layer stays deferred with no stage attached (ARCH §18, FR
§12). The constraint that shaped it is unchanged and still worth recording:
MemHouse cannot do Hindsight's write-time KG construction, because `FR-KN-2`'s
natural-language-statement-only rule exists so a human can gate one statement
rather than forty triples, and the derived graph must stay a derived cache under
`AINV-5`. What changed is the evidence that the multi-hop gain this stage was
reaching for does not require the graph at all — Mem0 replaced external graph
databases with graph-style entity linking and kept the improvement. The `Graph`
seam stays reserved.

## Open question

**May any retrieval strategy be enterprise-gated?** Recommendation: **no**.
Gating rerank or graph quality conflicts with `AINV-1`; monetize scale,
operations, governance, and support instead. ADR 0002 makes this a maintainer
decision, so it remains open.

## Anchors

- `AINV-1` - identical guarantees; retrieval quality should not vary by edition.
- `AINV-5` - system of record vs derived cache; the dream-time KG is a cache.
- `AINV-8` - domain strategies vs infrastructure ports; strategies are domain.
- `AD-SEAM-3` - domain strategies; the retrieval seam splits into three.
- `AD-SEAM-4` - cross-port invariants.
- `AD-DATA-1` - tri-temporal model; the basis of the `Temporal` strategy.
- `AD-DATA-2` - confidence computed at read; an abstention input.
- `AD-DATA-3` - materialised projections; what dream-time retrieval builds.
- `AD-DATA-5` - vector + lexical co-located; why fan-out is one pool.
- `AD-MODEL-1` - capability behaviours; `Reranker` becomes the rerank seam.
- `AD-MODEL-3` - grounding & abstention; gains an input, keeps its mechanism.
- `AD-PIPE-2` - fast lane vs dream-time slow lane.
- `AD-CFG-1` - two kinds of config; profile selection layers onto both.
- `AD-EVAL-2` - testing pyramid; strategy-level contract tests.
- `AD-EVAL-4` - injected clock; required for deterministic eval runs.
- `AD-EVAL-5` - in-repo eval app; hosts the ablation harness.
- `NFR-1` - latency targets; `ask`/`search` band vs `get_context`.
- `NFR-2` - how `get_context` hits its target; unchanged, and that is the point.
- `FR-API-6` / `FR-API-7` - `ask` and `search` profile defaults.
- `FR-API-10` - context-assembly scoring; the `SalienceRecency` strategy.
- `FR-API-23` - `as_of`; the `Temporal` strategy.
- `FR-API-25` - hybrid retrieval; becomes multi-strategy with named profiles.
- `FR-API-26` - grounding & abstention.
- `FR-KN-2` - natural-language statements only; why the KG is dream-time.
- `FR-KN-17` - belief-time intervals.

## Related Documents

- `specs/adr/0002-l3-automation-boundary.md`
- `specs/adr/0003-embedded-postgres-pg0.md`
