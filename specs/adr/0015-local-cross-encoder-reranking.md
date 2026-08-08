<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0015: Local Cross-Encoder Reranking

## Status

Accepted on 2026-08-09.

## Context

The `:thorough` profile runs reranking inside a 1500 ms request deadline. A
general-purpose listwise LLM cannot complete this stage within its remaining
budget, so retrieval degrades to fusion order.

## Decision

Add the `:reranker` Account model role. Its default is the local
`BAAI/bge-reranker-v2-m3` ONNX cross-encoder through Ortex. The role has its own
model, version, tokenizer, classifier artifact, and execution-provider options.
It never shares the embedder or `:dream_reasoner` session.

The local runtime scores query-document pairs in input order. It returns a
score for every pair and does not normalize model logits. The retrieval engine
keeps its existing complete-order validation and preserves fusion order on any
error or deadline miss.

`MEMHOUSE_RETRIEVAL_RERANK_TIMEOUT_MS` defaults to 120 ms. The remaining
profile deadline is still the hard upper bound. Native hosted rerank endpoints
remain supported. The structured-generation fallback is an expensive offline
analysis path and is refused inside a live retrieval deadline.

Artifacts remain operator-supplied and checksum-pinned. Runtime never downloads
or substitutes artifacts. This keeps the same release usable offline and in
both PostgreSQL deployment modes.

## Consequences

Readiness, durable configuration, usage records, and evaluation reports record
the fifth role. Existing `f7-1` retrieval response fields and profile identity
remain unchanged. A deployment without verified local artifacts reports a
reranker provider failure and returns fusion order.

## Evidence

- `lib/memhouse/model/reranking/ortex.ex`
- `lib/memhouse/model/providers/ortex.ex`
- `test/memhouse/f5_model_layer_structured_extraction_test.exs`
- `test/memhouse/f7_retrieval_entity_context_test.exs`
