<!-- SPDX-License-Identifier: Apache-2.0 -->
# Changelog

All notable changes to MemHouse. Versions follow [Semantic Versioning](https://semver.org/); the
REST and MCP API has its own version and stability policy ([docs/api-stability.md](docs/api-stability.md)).

## 2.0.0 (unreleased)

A new implementation in Rust on Postgres + pgvector. It replaces the Elixir implementation
(0.x), which is archived, with its history, releases and issues, at
[memhousehq/archive-memhouse](https://github.com/memhousehq/archive-memhouse); there is no upgrade
path from 0.x data other than export and import.

- Write gate with redaction and injection quarantine, deduplication, supersession, validity
  windows and `as_of` recall.
- Hybrid recall (BM25 and vectors, weighted RRF, optional cross-encoder, token budget) with a
  stored explanation for every recall.
- Public API v1 over REST and MCP: remember, recall, revise, forget, ingest; idempotency keys,
  scopes, structured and rendered output; OpenAPI 3.1 document (API version 1.2.0).
- Principals, per-principal API keys, short-lived agent tokens, propose-only agents, labels and an
  authorizer checked on every operation.
- Hash-chained audit log, deletion ledger, retention; Memory Format v2 export and import.
- OpenTelemetry traces and a Prometheus metrics endpoint. Logs and traces carry identifiers and
  timings, never memory content or query text; errors from embedding and LLM providers keep only
  the status and the provider's error type and code.
- Policy engine v1: behaviour policy as a structured spec (memory types, write gate, retention,
  redaction, denied labels, ranking weights), compiled under governance so it can only tighten it;
  only approved, versioned specs run; diff, approve with a named approver, roll back, without a
  restart; every record and trace carries the policy version (`memhouse policy`, `/v1/policies`,
  API 1.3.0, schema version 5).
- Write pipeline v2: every write is authorized, redacted and durably queued, then answered
  `candidate` at once (`wait: true` to answer after the gate); a statement gate commits facts,
  holds plans and speculation as candidates (recalled only with `include_candidates`), and
  supersedes what a correction or a changed value updates; structured records are answered by
  exact query; workers resume proposals after a crash and set poison ones aside; failed
  retrieval answers empty and flagged, a write that can't be queued is refused as retryable
  (`503 unavailable`). API 1.4.0, schema version 6 (`mh_intake`), `[intake]` settings.
- Memory types: each type has its own write gate, retention, retrieval method and access rules,
  set per type in the compiled policy (`[types.<kind>]` sections tighten them). Working memory is
  a session's scratchpad, served first from a per-session cache; scopes inherit from tenant to
  session and a keyed preference resolves user over team over org
  (`GET /v1/subjects/{subject}/preferences`); `POST /v1/promote` writes an audited, linked record
  of another type; agents read each other's agent-scoped memory only with a grant
  (`/v1/grants`, `memhouse grant`); procedural memory waits for confirmation and the new
  `taxonomic` kind for an administrator's approval. API 1.5.0, schema version 7 (`mh_grant`),
  `[memory] working_cache_*` and `[intake] preference_signals` settings. Behaviour changes for
  1.4 clients are listed in [docs/api-stability.md](docs/api-stability.md).
- Ranking and packing v2: the final score combines relevance, recency, confidence and validity
  with weights from the compiled policy (`[ranking] relevance_weight`, `confidence_weight`,
  `validity_weight`); recall leaves out near-duplicates by vector cosine and text shingles and
  fills the freed places (`dedup`, `dedup_cosine`, `dedup_overlap`); `token_budget` is a hard cap
  on the hits and on the rendered block; `render_format` picks the block's form (`plain`,
  `markdown`, `xml`). API 1.6.0; `[memory] relevance_weight`, `confidence_weight`,
  `validity_weight` and `recall_dedup*` settings. The budget change for 1.5 clients is recorded in
  [docs/api-stability.md](docs/api-stability.md).
- `memhouse bench`: LongMemEval, LoCoMo, LLM-judged QA with cost caps, and the governance suite.
- The CLI stops quietly, with status 141, when the program reading its output exits early
  (`memhouse recall ... | head`).
