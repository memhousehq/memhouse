<!-- SPDX-License-Identifier: Apache-2.0 -->
# Changelog

All notable changes to MemHouse. Versions follow [Semantic Versioning](https://semver.org/); the
REST and MCP API has its own version and stability policy ([docs/api-stability.md](docs/api-stability.md)).

## 2.0.0 (unreleased)

A new implementation in Rust on Postgres + pgvector. It replaces the Elixir implementation
(0.x), whose code, history and tags remain on the `legacy/elixir` branch; there is no upgrade path
from 0.x data other than export and import.

- Write gate with redaction and injection quarantine, deduplication, supersession, validity
  windows and `as_of` recall.
- Hybrid recall (BM25 and vectors, weighted RRF, optional cross-encoder, token budget) with a
  stored explanation for every recall.
- Public API v1 over REST and MCP: remember, recall, revise, forget, ingest; idempotency keys,
  scopes, structured and rendered output; OpenAPI 3.1 document (API version 1.2.0).
- Principals, per-principal API keys, short-lived agent tokens, propose-only agents, labels and an
  authorizer checked on every operation.
- Hash-chained audit log, deletion ledger, retention; Memory Format v2 export and import.
- OpenTelemetry traces and a Prometheus metrics endpoint.
- `memhouse bench`: LongMemEval, LoCoMo, LLM-judged QA with cost caps, and the governance suite.
