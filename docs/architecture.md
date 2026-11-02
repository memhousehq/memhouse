<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Architecture (local profile)

This is the first implemented slice of the design in [`docs/design/`](design/). It covers the
Standard-profile shape (one binary, customer's Postgres) running locally. Everything is built so
that the Scale profile can replace adapters, not rewrite the engine (TR-CORE-01).

## Components

| Component | Where | Notes |
|---|---|---|
| Engine | `memhouse-core::Engine` | One implementation of write gate, routing, ranking, supersession, deletion and audit events. Every transport (REST, MCP stdio, MCP HTTP, CLI, benchmark) calls it. |
| Store adapter | `memhouse-store-postgres` | Implements the `Store` trait. Sharded Postgres and an embedded store can be added behind the same trait. |
| Model adapters | `memhouse-models` | `Embedder` / `Reranker` traits: local ONNX (offline), any OpenAI-compatible endpoint. |
| Gateway | `memhouse-server` | axum REST and MCP-over-HTTP, bearer-key auth, Memory Browser page. |
| MCP stdio | `memhouse-server::mcp` | JSON-RPC 2.0, protocol 2025-06-18 (also accepts 2025-03-26 and 2024-11-05). |
| Validation tool | `memhouse-bench` | Public datasets, governance gates, statistics, reports. |

## Data model

One table, `mh_memory`, holds every kind of memory. Key columns:

- `tenant`, `subject`: the partition. Every query filters on both, so recall never leaves the subject.
- `kind`, `status` (`committed`, `superseded`, `quarantined`), `content` (already redacted).
- `tsv`: a generated `tsvector` for full-text search, with a GIN index.
- `embedding vector(D)`: exact per-subject scoring. There is deliberately no ANN index on subject data (SCALE-03), so top-k is exact.
- `occurred_at` (event time), `valid_from` / `valid_to` (validity window), `supersedes` / `superseded_by`.
- `labels`, `tags`, `source`, `confidence`, `metadata`, `content_hash` (for dedup).

Supporting tables:

- `mh_embed_cache`: content-addressed embedding cache. Re-ingesting text costs nothing; deleting a memory deletes its cached vector.
- `mh_audit`: append-only, hash-chained. Each event stores `prev_hash` and `hash = sha256(prev ‖ fields)`; `memhouse audit --verify` recomputes the chain.
- `mh_deletion_ledger`: what was deleted and when, to re-apply after a restore (TR-WF-03).
- `mh_meta`: schema version, embedding dimension, embedder id. A dimension mismatch is refused at start-up.

## Recall: one statement for all probes

0. **Query analysis** (`query.rs`, no LLM): time expressions are resolved against `reference_time` (or `as_of`, or now) into generous windows. If there are any, a second probe runs the same query restricted to them. All probes go to Postgres as one statement (their searches under `UNION ALL`), so a recall is exactly one round trip (PERF-02, checked from the trace by `recall_round_trip`).
1. **Filter:** tenant, subject, `status = committed`, kinds and tags, denied labels, validity at `as_of` (or now), event time ≤ `as_of`, and for the window probe, event time inside a window.
2. **Keyword candidates:** BM25 (k1 = 1.2, b = 0.75) computed in SQL from the stored `tsvector`: term frequencies from lexeme positions, document frequencies from the matched rows.
3. **Vector candidates:** exact cosine distance with pgvector, the better of the round vector and the user-only vector.
4. **Fusion:** weighted reciprocal rank fusion (`k = 60`) inside each statement, then across probes (window probe: 0.15 for every in-window hit, +1.0 for its top 3). Only the top `k` fused ids are then fetched, each by primary key and still filtered on tenant and subject, so no step of the statement reads another subject's rows.
5. **Engine side (optional):** cross-encoder reranking of the top candidates blended with the fused rank, a recency bonus, and token-budget packing.

The query embedding and the SQL statement are the whole hot path. On a laptop, p50 recall is a few milliseconds plus query embedding. The recall's explanation record (`mh_recall`) is written off that path, after the response.

## Write path

`remember`: screen (redact, then injection check) → exact dedup by content hash → embed through the cache → near-duplicate check (cosine ≥ 0.97 within the same kind) → insert → supersede the old record if `supersedes` is set → audit event.

`ingest`: messages grouped into rounds (a user message plus the replies to it; assistant text trimmed to `assistant_chars`), or one record per message for multi-party chats → batch dedup by hash → batch embedding of each round and, separately, of the user's words in it (`embedding_alt`, cache key in `alt_hash` so deletion purges it too) → one multi-row insert → one audit event.

## Enrichment: asynchronous LLM fact extraction (optional)

With `[enrich] enabled = true`, `ingest` also writes one row to `mh_enrich_job` per session and
returns at once; nothing on the write or read path waits for an LLM.

1. **Workers** (`[enrich] workers`, default 8, in `memhouse serve` and `memhouse bench`) claim
   jobs with `FOR UPDATE SKIP LOCKED` and a 5-minute lease, so several processes can share the
   queue and a crashed worker's job is picked up again. Failures back off (2^attempt seconds) and
   are marked `failed` after `max_attempts`.
2. **Extraction:** the session's committed rounds go to a small chat model (default
   `qwen/qwen3.7-flash` on OpenRouter, about $0.00007 per session; any OpenAI-compatible endpoint
   works, including a local Ollama). User text is sent in full and assistant replies are cut to
   `assistant_chars` (300). Sessions with less than `min_user_chars` of user text are skipped
   without a call. The model returns short, self-contained facts (events, facts, preferences,
   plans) with relative dates resolved to absolute ones and the rounds they came from.
3. **Cache:** answers are stored in `mh_llm_cache` under
   sha256(prompt version, model, endpoint, prompt), so a repeated session is never paid for twice.
4. **Same gate as every write:** each fact is redacted and screened for injection, deduplicated
   per session, embedded and inserted as a `semantic`, `preference` or `commitment` memory with
   `metadata.derived = true`, `source_ids` (the rounds it came from), `observed_at` (the session
   date) and `occurred_at` (the event date). Its `session_id` and `turn_ref` are the source
   rounds', so retrieval metrics and citations still point at the conversation.
5. **Recall** finds facts and rounds in the same hybrid search. Facts become searchable when
   their job finishes (p50 a few seconds); until then recall serves the raw rounds.

Deletion covers the derived path: forgetting a round deletes facts whose `source_ids` contain it,
their cached vectors, the jobs that read it and their cached extraction; erasing a subject
removes its jobs and cached extractions too. Two governance checks (`enrich_async_gate`,
`enrich_deletion`) verify this with a deterministic stub model. `max_cost_usd` stops LLM calls
once a process has spent that much; `GET /v1/enrich/status` shows the queue.

## Governance defaults

| Control | Default |
|---|---|
| Redaction | secrets/API keys, payment cards (Luhn-checked), SSNs, IBANs. Optional: email, phone, IP. |
| Injection screening | on; matches are stored as `quarantined` and never recalled. |
| Audit | every write, update, delete, subject erase and import; reads optional (`audit_reads`). |
| Retention | configurable episodic retention (`episodic_retention_days`), applied hourly by `memhouse serve` or on demand with `memhouse retention`; it cascades to derived facts, jobs and caches like a deletion. |
| Auth | REST and HTTP MCP need a bearer key (generated by `up`/`init`). There is no unauthenticated mode. stdio MCP runs as the local user. |

## Not built yet (from the plan)

- Relationship-based authorizer and access-policy decision register (ACC, D-01..D-07)
- Plain-language policy compiler
- Plugin system for context providers (HubSpot, Salesforce, Shopify, Zendesk)
- Embedded store for the Lite profile
- Sharded Scale profile and Temporal workflows

The adapter traits are where these attach.
