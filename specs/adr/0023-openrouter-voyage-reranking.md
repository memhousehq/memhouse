<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0023: OpenRouter Voyage Reranking

## Status

Accepted on 2026-08-24. Supersedes ADR 0015.

## Context

The local BAAI cross-encoder added several gigabytes of classifier artifacts,
an independent tokenizer and ONNX session, runtime memory pressure, and
deployment-specific provisioning. The local Qwen embedder still requires Ortex,
but reranker artifacts duplicated that operational burden for a bounded stage.

OpenRouter exposes a native rerank API and serves Voyage `rerank-2.5`. Its
request and response retain the index-and-score contract the retrieval engine
already validates.

## Decision

The default `:reranker` role uses provider `openrouter`, model
`voyageai/rerank-2.5`, and credential reference `env:OPENROUTER_API_KEY`.
MemHouse calls `POST /api/v1/rerank` with the bounded candidate head and sets
`top_n` to its size. It maps returned indexes to the original documents and
records provider-reported total tokens as reranker input tokens.

The engine keeps the `f7-1` role, ordering validation, usage metering, and
`retrieval_outcomes` shape. A credential, transport, HTTP, or response failure
preserves fusion order and records the existing provider-error outcome. The
local Qwen embedding path and its Ortex dependency remain.

## Consequences

Deployments no longer provision, mount, or load BAAI reranker artifacts. They
must provide network access and `OPENROUTER_API_KEY`; hosted text and token cost
replace local memory and CPU cost. The hosted round trip receives 750 ms within
the unchanged 1500 ms thorough deadline. Operators still use dropped reranker
outcomes to detect latency or provider failures.

## Evidence

- `lib/memhouse/model/providers/req_llm.ex`
- `test/memhouse/model/providers/req_llm_test.exs`
- `test/memhouse/f7_retrieval_entity_context_test.exs`
