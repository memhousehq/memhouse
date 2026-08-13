<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0017: Entity-match selectivity is measured per request, not cached

## Status

Accepted. Amends the `EntityMatch` scoring introduced by ADR 0006; the
strategy, its resources, and its public-surface boundary are unchanged.

## Context

`EntityMatch` matched an entity name by set membership and then ranked the
resulting statements by `mention.confidence * knowledge.confidence`. Neither
term reads the query. Every statement mentioning a matched entity was equally
matched, so ordering fell to the extractor's confidence, which is near `1.0`
for anything it is sure was said.

In a conversation scope about two or three people, nearly every statement
mentions one of them. The strategy therefore returned a confidence-ordered dump
of the scope on almost every query, and — because `query_dependent?/0` is true
for it — `disagreement.query_dependent_empty` read `false`, asserting the run
had understood a question it had not. `Fusion.disagreement/2` exists to stop
exactly that.

Weighting each entity by inverse frequency fixes the ranking. Where the
frequency figure lives is the decision.

## Decision

Compute entity frequency inside the retrieval query, per request, from
`entity_mentions` restricted to the request's authorized scopes.

Three settings bound the strategy, all in `:retrieval_profiles`:
`entity_match_frequency_ceiling`, `entity_match_ceiling_min_statements`, and
`entity_match_per_entity_cap`.

A statement's score is the share of the query's total entity weight that its
own mentions carry, times its confidence. The result stays in `0..1` because
`min_score` filtering and the `low_score` disagreement hint both read the raw
strategy score; an unbounded sum would silently redefine both.

Inverse frequency is smoothed as `ln(1 + N/n)` rather than `ln(N/n)`. The
unsmoothed form is zero when an entity covers the whole corpus, which erases
recall in any scope small enough that every entity is ubiquitous — a
single-statement scope being the limiting case. The frequency ceiling, applied
only once a scope is large enough for the ratio to mean anything, is what drops
a hub entity.

## Rejected: a frequency column on the entity row

The obvious alternative, and the one the originating issue proposed: store the
mention fraction on `MemHouse.Knowledge.Entity` and refresh it in the existing
rebuild path. It is rejected on correctness, not cost.

`Entity` is Account-global — its identity is `canonical_name_kind`, with no
scope. One column can hold one Account-wide figure. Retrieval authorizes a
subset of scopes, so the figure a request needs is per scope, and the schema
has nowhere to put it short of a new `(entity, scope)` table.

Rebuilds compound this. `MemHouse.Retrieval.Rebuild.scope/2` rebuilds one
scope. An Account-wide count written during one scope's rebuild is stale the
moment a second scope's mentions change, so the column would be correct only
for whichever scope was rebuilt last. Keeping it honest means recounting every
entity in the Account on every scope rebuild — more work than the aggregate it
was meant to avoid.

The per-request aggregate is served by the existing
`entity_mentions (account_id, scope_id, entity_id)` index and is bounded by the
matched entities, of which a query names few. No migration, no snapshot change,
and no rebuildable-cache staleness to reason about.

## Consequences

- A query naming only entities above the ceiling contributes no candidates.
  That is a finding: `query_dependent_empty` then reports truthfully that no
  strategy resolved the question.
- Small scopes are unaffected. Below
  `entity_match_ceiling_min_statements` the ceiling does not apply, and the
  smoothed weight keeps every matched statement eligible.
- Profile weights are unchanged. `entity_match` stays at `0.9` in `balanced`
  and `thorough`; lowering it is a fusion-tuning change and needs held-out
  data, which this record does not supply.
- Nothing new crosses the retrieval boundary. Entity ids, canonical names,
  aliases, and the frequency figure stay inside the query.

## Where this lives

- `MemHouse.Retrieval.Store.entity_match/2` — the scoring query.
- `config/config.exs`, `config/runtime.exs` — the three settings.
- `test/memhouse/f7_retrieval_entity_context_test.exs` — selective-over-hub
  ranking, the empty-on-saturation case, and the per-entity cap.

## Related documents

- `specs/adr/0004-multi-strategy-retrieval.md`
- `specs/adr/0006-entity-resolution.md`
