<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0010: Gate query-independent retrieval by intent

## Status

Accepted.

## Context

`Temporal` and `SalienceRecency` rank authorized memory without reading query
text. When they ran alongside a normal text search, their full candidate lists
could fill the visible fused head before exact lexical evidence. This violates
the retrieval intent of `FR-API-25` and weakens the abstention input required by
`FR-API-26` and `FR-API-29`.

## Decision

`Temporal.applicable?/1` requires a non-nil `as_of` and a knowledge-capable
target. `as_of` is already the public point-in-time intent defined by
`FR-API-23`; no natural-language date parser is added.

`SalienceRecency.applicable?/1` requires blank query text and a
knowledge-capable target. It therefore remains available to the intentional
blank-query/context-fallback path, but cannot generate a recency list for an
ordinary question. Text searches fuse only query-dependent seed evidence until
a future reviewed design adds a bounded prior over that pool.

The strategy registry, built-in profile memberships, weights, deadlines, and
response fields are unchanged. `f7-1` therefore remains the profile identity:
this corrects strategy applicability rather than changing the profile contract.
The fixed 40-distractor corpus in F7 evidence compares the pre-rule candidate
shape to the resulting query-dependent head without model or external data.

## Consequences

- Explicit historical searches retain interval recall through `Temporal`.
- Ordinary text searches cannot disguise a query-dependent miss with temporal
  or recency candidates; `query_dependent_empty` remains pre-fusion and true.
  Such a search now returns an empty candidate list rather than a recency page.
- Blank-query/context fallback retains a bounded, intentional
  salience-recency path. A nil query counts as blank there, because a caller
  that sends an explicit null still expects the fallback to answer.
- `:fast` now runs exactly one of its two members per request: `Semantic` for a
  text-bearing `get_context` miss, `SalienceRecency` for a blank one. Their
  applicability predicates are complements. A text-bearing fallback therefore
  has no embedding-free backstop, so an unavailable embedder yields empty
  context where the recency list previously answered. Restoring a backstop
  needs profile-aware applicability, which is deliberately left to a separate
  reviewed change rather than folded into this correction.
- `SalienceRecency` ablation variants in `specs/eval/release-suite.json` now
  measure a strategy that cannot run against a text query and score zero by
  construction. They are not release guardrails; retiring or reshaping them is
  an evaluation-suite decision, recorded here so the zero is not read as a
  quality regression.

## Anchors

`FR-API-23`, `FR-API-25`, `FR-API-26`, `FR-API-28`, `FR-API-29`, `AD-DATA-1`,
and `AD-SEAM-3`.
