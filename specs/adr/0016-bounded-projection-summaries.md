<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0016: Bounded projection summaries

Status: Accepted.

## Decision

A context projection is bounded, grounded compression of governed knowledge.
It is not a serialized query result.

Each scope card, peer profile, session summary, and entity card stores:

- concise summary prose from the `dream_reasoner` role, or a deterministic
  source extract for test and local mode;
- a bounded set of pinned facts with only a source id and a short statement
  excerpt; and
- model provenance when a model produced the summary.

The complete source set remains in the private `Projection.source_ids` field.
Projection JSON must not contain knowledge lifecycle state, confidence,
sensitivity copied from a source, scope id, model extraction metadata, pipeline
metadata, source-message ids, or a full list of knowledge rows. An entity card
continues to carry its aggregate sensitivity, scope-local label, and recomputed
kind as required by ADR 0011.

Generation input and stored output are bounded by projection kind. The builder
uses only a bounded prefix of ranked statements for a model call. The live
`get_context` path reads clean projections and never calls a model. It exposes
the deduplicated pinned facts as the `knowledge` member.

When a production model call fails, the projection stores no raw-source
fallback. Its summary is unavailable and the normal refresh retry can replace
it. The deterministic provider uses an explicit source extract so local and
test behavior remains useful without representing it as model output.

## Consequences

Projection rows remain rebuildable caches. Lifecycle changes still invalidate
them through their complete private source ids. Readers can inspect a small
grounding set but use `search` or a knowledge read when they need source detail.

This changes the contents of an existing `f7-1` projection from an invalid raw
dump to the summary semantics already required by `FR-KN-13` to `FR-KN-15`. It
does not change the HTTP member names or add a public write path.

## Anchors

- `FR-KN-1`, `FR-KN-13` to `FR-KN-16`, `FR-KN-23`
- `FR-API-4`, `FR-API-5`, `FR-API-10`
- `AINV-2`, `AINV-5`, `AINV-6`, `AINV-10`
- `AD-DATA-11`, `AD-PIPE-2`, `AD-PIPE-7`
