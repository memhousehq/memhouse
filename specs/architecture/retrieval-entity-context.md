<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Retrieval, Entity Resolution, And Context

Status: implemented

Profile-selected, deadline-bounded strategies and projection-backed context
replace inline retrieval. This implements `FR-API-1` through `FR-API-5`, `FR-API-7`, `FR-API-10`,
`FR-API-23` through `FR-API-25`, `FR-API-27` through `FR-API-29`,
`FR-KN-18` through `FR-KN-22`, `AD-SEAM-3`, `AD-DATA-5`,
`AD-DATA-10`, `AD-PIPE-7`, `AINV-5`, `AINV-6`, and `NFR-2`.

## Retrieval boundary

`MemHouse.Retrieval.Strategy` defines `name/0`, `cost_class/0`, `stage/0`,
`applicable?/1`, and `candidates/2`. MemHouse ships:

| Stage | Strategies |
| --- | --- |
| Seed | Semantic, Lexical, Temporal, SalienceRecency, EntityMatch |
| Expand | RelationExpand |

Production seed strategies run concurrently; expansion then traverses knowledge
relations, permission-filtered scope relations, and shared-entity edges. SQL
sandbox tests run the same contracts serially on their shared connection.

Each source list has its own cutoff and cap. Score-aware fusion min-max
normalizes each strategy's returned scores, then combines 95% normalized score
with a 5% reciprocal-rank tie-break. The profile supplies weights and `rrf_k`;
the default is 15. The `:thorough` profile optionally reranks only the fused
head through `MemHouse.Model.Gateway`. Reranking and grounded answers hold no
transaction; the model layer scopes its own configuration read and usage write.
A hard remaining-time budget wraps strategies and reranking. Each strategy
receives a configured timeout clamped to the remaining strategy-phase budget;
rerank reservation may further reduce that budget. The reranker receives its
configured timeout clamped to the remaining hard deadline.
Timeouts are dropped, not retried, and every response preserves the compatible
dropped-name list while adding content-free component timings and deterministic
reason classes plus pre-fusion cross-strategy disagreement.

Fusion destroys the evidence of how a candidate arrived, which leaves an
operator unable to tell a candidate that no strategy generated from one that
fusion or reranking demoted. `MemHouse.Retrieval.Trace` reconstructs that for a
single run when a `DiagnosticGrant` asks for it: per-strategy local rank and
score, each list's normalized weighted contribution, the pre-rerank fused
rank, the final rank, and why a candidate was or was not reranked. It reports
only candidates the same response already returned, and the engine builds it
after ranking, so it changes no ordering. It is returned in the result and
nowhere else — the diagnostics ETS summary, telemetry metadata, audit rows, and
job arguments keep their existing allowlisted fields. Local scores stay beside
the strategy that produced them because they remain incomparable across
strategies.

Query-independent strategies are applicability-gated: `Temporal` runs only
when the request supplies `as_of`; `SalienceRecency` runs only for a blank-text
governed-memory request, where a nil query counts as blank. This keeps ordinary
text-search heads query-dependent, while explicit historical reads and context
fallback retain their intentional temporal and recency behavior. The profile
memberships, weights, response fields, and `f7-1` identity are unchanged; this
is an applicability correction recorded in ADR 0010.

The three strategy sets are disjoint and carry distinct facts: contributed
returned candidates, empty ran and matched nothing, dropped never produced a
result. Each strategy declares `query_dependent?/0` — true only for reading
`query.text`, so expansion inherits nothing from its seeds — and disagreement
reports `query_dependent_empty` when no such strategy contributed. That is the
FR-API-29 signal `strategy_count`, `disjoint`, and `low_score` cannot carry:
all three read only the lists that came back non-empty, so a strategy that
returned nothing leaves no trace in them, and a scope ranked by `temporal` and
`salience_recency` alone reports the same health as an answered query.

`candidates/2` returns candidates or `{:error, reason}`. The second means the
strategy never ran — an unavailable embedder, say — and the engine reports it
as dropped. An empty list keeps its own meaning: the strategy ran and matched
nothing. Collapsing the two would make a broken dependency indistinguishable
from an honest miss, which is the same confusion an unindexed corpus creates.

`MemHouse.Retrieval.Store` is the reviewed read-only data-layer helper for
the operations Ash does not express as ordinary resource reads: PG-FTS,
pgvector ANN order, hop-one expansion, content-free entity-cache aggregates,
and co-mention statement ids. Its static parameterized statements apply
Account, authorized scope, lifecycle, soft-delete, and caller-provisional
filters before returning content or a statement id. The aggregate query is
reachable only after the browser's account-admin gate and returns counts,
rates, and quantiles without entity identities. `MemHouse.Memory.Query` has
been removed. Durable writes remain Ash-action-only.

## Profiles and configuration

The built-in profile version is `f7-1`:

| Profile | Strategy posture | Rerank | Default surface |
| --- | --- | --- | --- |
| `:fast` | Semantic + SalienceRecency, one per request (ADR 0010) | No | `get_context` cache-miss fallback |
| `:balanced` | Semantic + Lexical + Temporal (`as_of` only) + EntityMatch | No | `search` |
| `:thorough` | All seeds + RelationExpand | Yes | `ask` and dream-time projection refresh |

An active `RetrievalProfile` on the nearest authorized scope overrides the
runtime profile. Its externally reported version combines the authored version
with a digest of strategies, weights, and rerank configuration. Deployment
configuration can constrain enabled strategy modules and the three deadline
ceilings through:

- `MEMHOUSE_RETRIEVAL_ENABLED_STRATEGIES`;
- `MEMHOUSE_RETRIEVAL_FAST_DEADLINE_MS`;
- `MEMHOUSE_RETRIEVAL_BALANCED_DEADLINE_MS`;
- `MEMHOUSE_RETRIEVAL_THOROUGH_DEADLINE_MS`;
- `MEMHOUSE_RETRIEVAL_STRATEGY_TIMEOUT_MS`; and
- `MEMHOUSE_RETRIEVAL_RERANK_TIMEOUT_MS`.

Raw strategy lists and rerank overrides remain restricted to internal/system and
eval callers. The one browser path into that seam is
`Memory.diagnostic_search/2`, which admits a password-authenticated account
administrator and passes a `Retrieval.DiagnosticGrant` struct through the
facade's filters; decoded JSON cannot produce a struct, so a request body
reaching the same facade cannot forge one. A grant selects strategies, the
deadline, the rerank stage, and a clamped candidate limit. It never relaxes
Account, scope, lifecycle, or subject filtering, and it opens no MCP tool or
HTTP field.

Source filters are applied before fusion. `search` keeps the baseline-contract
shape by returning governed knowledge and document chunks in one candidate
collection distinguished by `candidate_type`; `ask` restricts its retrieval to
knowledge.

## Vector and lexical storage

Knowledge and document chunk embeddings are real PostgreSQL `vector` values,
not float-array stand-ins. Every vector retains provider, model, version, and
dimensions. The retrieval migration adds:

- StreamingDiskANN cosine expression indexes for the pinned 1024-dimensional
  knowledge and chunk collections. Both collections also carry a private
  per-Account scope label. The index uses the `smallint[]` overlap
  filter during graph traversal for authorized scopes;
- a generated document-chunk `tsvector` and GIN index;
- the existing knowledge-statement GIN index as the lexical path; and
- expansion lookup indexes for mentions and knowledge relations.

The production 1024-dimensional semantic query uses the matching DiskANN
expression. The query applies transaction-local search-list and rescore
settings. Boot rejects an embedder width without a matching installed index;
the public readiness payload reports this content-safe configuration check.
Supporting another width requires a reviewed index migration and a full
re-embed before that width can be configured.
`MemHouse.Retrieval.Vector` provides the deterministic Nx cosine baseline for
tiny eval corpora and entity candidate comparison. A pinned-identity mismatch
still follows the model layer's explicit re-embed plan; vectors are never
silently reused. DiskANN post-filters Account, scope, lifecycle, and embedding
identity; it does not weaken those authorization filters. Scope labels are
rebuildable index data. They are allocated densely per Account, reused only
after a scope is released, and recreated by import/rebuild. They are never
exported, returned, audited, telemetered, or placed in job arguments. An
Account with more than 65,536 live scopes fails label allocation rather than
sharing a label.

`projection_refresh` is the replay-safe rebuild job. Ordinary governed writes
use one key per scope and ten-second time bucket. A five-second trailing delay
lets burst writes coalesce before the job backfills knowledge vectors, resolves
entities, and refreshes projections. The dependency-ordered job replaces the
redundant per-write entity job. Reconciliation, erasure, import, and explicit
maintenance retain corpus-derived full-rebuild keys. The coalesced path batches
only statements without vectors; it does not re-embed the unchanged corpus.
Document import already
re-enters ordinary document ingest, which rebuilds chunk vectors and causes
governed knowledge to enqueue the same derived-cache jobs.

Because vectors and mentions are written by that job alone and no longer ride
the knowledge-write transaction, they are eventually consistent: a refresh that
was cancelled or never enqueued leaves a scope holding every governed statement
with no vectors, while lexical search keeps answering from its generated
column. `MemHouse.Retrieval.Coverage` is the read that distinguishes the two —
per-scope statement, embedded, mention, and mentioned-statement counts plus the
embedding identities in use, under the same authorization and
provisional-subject rules as any other retrieval query. Mentions remain counts
so the entity cache stays internal. Every completed refresh emits
`[:memhouse, :retrieval, :projection_refresh]` with those counts and the
resulting ratio. The Account reconciler detects an active scope with no mention
rows and enqueues the same full refresh using a corpus-derived replay key.
Request-local diagnostics classify partial coverage and distinguish no resolved
entity from a resolved entity with no authorized statements without returning
cache identities or content.

An authenticated identity with a Peer reads as that Peer unless it names another
reader. A peerless identity reads public knowledge only. The response reports only
the resulting `peer`, `public_only`, or `internal` reader posture. When lexical
terms match active knowledge that reader visibility removes, a content-free outcome
reports only that the authorization stage filtered a match. It returns no hidden
ids, text, scores, or counts. Scope authorization and personal-subject filtering
still apply inside each strategy query.

Lexical search applies the versioned `lexical-question-v3` analyzer before its
static, parameterized FTS query. For plain English questions it removes a
reviewed interrogative set, retains the remaining query terms, names, and dates,
and adds a bounded phrase boost. It does not expand terms with a hand-written
synonym list. Quoted phrases and negation retain `websearch_to_tsquery`
semantics. The content-free retrieval diagnostic records the analyzer identity;
query text remains absent from diagnostics and telemetry.

The phrase boost is a second `tsquery`. It contains one ordered phrase clause
for each adjacent pair of the first four retained terms. The linear expression
is scored over a base-ranked shortlist of two times the caller's limit. A row
outside the shortlist cannot be promoted.

Entity name lookup uses a GIN index over the normalized lowercase alias and
canonical-name array. The index is rebuildable with the other entity cache data.

`Indexer.rebuild_scope/2` and `EntityResolver.rebuild_scope/2` use a short read
transaction, connection-free model calls, and one final write transaction. The
entity resolver matches surface forms against an in-memory set seeded by the
read, including entities created earlier in the same run. Stale-mention removal
and replacement are atomic; any failure leaves the previous index intact.

## Entity resolution

`Entity` and `EntityMention` remain pipeline-internal derived resources
declared by the Ash domain backbone. The dream-time resolver processes active
governed statements using:

1. exact normalized alias matching;
2. Nx cosine over pinned alias embeddings to select a candidate; and
3. `dream_reasoner` structured adjudication for every non-exact merge.

The mention spotter removes reviewed closed-class words, common sentence-start
artefacts, and timezone abbreviations. It does not join forms across sentence
or line boundaries. Ordinary title-cased names can produce the `person` kind;
calendar names remain concepts.

Unresolved mentions degrade retrieval coverage; they never block ingest.
Mentions inherit visibility exclusively from their knowledge statement.
EntityMatch returns statement candidates without entity rows, names, aliases,
surface forms, or entity ids. No Phoenix route, MCP resource, or public
resource action exposes the caches. One exception, ADR 0011: an entity card
carries a `label` chosen from that card's own in-scope surface forms, and a
`kind` recomputed from them. Neither reads the entity row.

The console graph may also join two named hubs whose entities were mentioned in
one statement. Both ends come from a single statement the reader is already
shown, so the edge discloses nothing further, and only named hubs take part:
joining an unnamed hub would let a reader count the entities a collapsed group
holds. The edge means co-occurrence. No entity-relation table exists. Erasure removes affected mentions,
recomputes/prunes entities, and rebuilds affected projections. Logical import
excludes the cache and recreates it from governed statements.

Three diagnostic projections preserve that rule. `/console/operations` reports
Account-wide counts, an observed-alias histogram, singleton-entity rate, and
mentions-per-entity p50/p95 to a password-authenticated account administrator.
`/console/knowledge/:id` asks the store only for the count and capped ids of
co-mentioned statements after applying the reader's authorized scope and
console lifecycle filters, then loads those statements through the ordinary
Ash read policy. `/console/graph` asks the store to group the statements it has
already authorized into shared-entity clusters, which returns member-id arrays
only: the entity id is a grouping key, singleton groups are dropped, and
identically-membered groups collapse so the number of resolved entities stays
private. No path returns an entity or mention row to the web layer.

## Context projections

`projection_refresh` runs `:thorough` retrieval at dream-time, then updates:

- one active-only scope card per scope;
- one entity card per scope/entity with at least two distinct active source
  statements, summarised only at three (ADR 0011);
- one peer profile slice per subject Peer/scope, containing active knowledge
  plus only that subject's provisional knowledge; and
- one active-only session summary per session.

Projection keys are Account-local and unique. Entity-card keys use a private
entity id only as a grouping coordinate; payloads expose no entity-cache field.
Cards carry the strictest source sensitivity, a bounded summary with model
provenance, and a bounded set of pinned source excerpts. Full source ids remain
private on the projection row. Updates carry a watermark, delta count, source
ids, dirty state, and a bounded full-compaction cadence.
Lifecycle changes mark affected projections dirty and enqueue one deterministic,
delayed projection job in the same transaction as the state change. That job
also refreshes entities and mentions before it writes projections.

Projection keys also carry a private audience-contract namespace. A stricter
stored-content rule advances that namespace, so nodes running the new code
cannot serve a clean projection written under the older rule while its rebuild
is pending. A miss uses the already subject-filtered `:fast` retrieval path.

`MemHouse.Context` reserves the caller's character budget in the required
order: session summary, peer profile, scope cards, entity cards, then
salience-ranked knowledge. Clean projections are cached in ETS. Invalidation is broadcast
through Phoenix PubSub so queue-mode nodes evict the same Account/scope key.
On a miss, and only on a miss, `get_context` uses the `:fast` retrieval profile.
It never invokes dialectic or dream reasoning on the live context path.

## Proposed simplification boundary

ADR 0021 defines an evidence-gated experiment toward a smaller default recall
path. It preserves all authorization, lifecycle, provenance, erasure, and
answer-grounding behavior described here. The current `f7-1` profiles, entity
cache, projections, fusion, and reranker remain authoritative until matched
evaluation, rollback rehearsal, and human review approve a new default and a
new contract identity. Experimental adaptive recall is read-only and cannot
write Knowledge or invoke governance.

See [ADR 0021](../adr/0021-clean-room-memory-simplification.md).

## Version and evidence

Message/extractor and health stay `f5-1`. Search, ask, and context advance from
`poc-0` to `f7-1`, with updated baseline HTTP evidence. These are historical
contract tags, not roadmap phases.

Implementation and regression evidence:

- retrieval and context code under `lib/memhouse/retrieval/` and
  `lib/memhouse/context/`;
- retrieval resource fields and actions in `lib/memhouse/knowledge.ex` and
  `lib/memhouse/documents.ex`;
- migration
  `priv/repo/migrations/20260728092147_f7_retrieval_entity_context.exs`;
- generated resource snapshots under `priv/resource_snapshots/repo/`;
- acceptance suite
  `test/memhouse/f7_retrieval_entity_context_test.exs`; and
- updated baseline-contract surface and document-vector regressions.
