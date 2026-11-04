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
- `memhouse bench`: LongMemEval, LoCoMo, LLM-judged QA with cost caps, and the governance suite.
- The CLI stops quietly, with status 141, when the program reading its output exits early
  (`memhouse recall ... | head`).
