# Architecture notes

Module boundaries and contracts that span more code than any one module can
show. The source and its tests are authoritative for behavior; these notes say
where the seams are and why they sit there.

A note must not restate what a module already says. If it does, delete it.

Older notes cite `FR-*`, `AD-*`, `AINV-*`, and `NFR-*` anchors from the retired
blueprint documents. Those anchors no longer resolve. Read them as history.

## The notes

| Note | Covers |
| --- | --- |
| `free-core-architecture.md` | Target abstraction layers, module decomposition, durable-versus-derived rules, the public operation set, and the contract version identities. |
| `ash-domain-backbone.md` | The Ash resource, action, and policy boundary, and its remaining transition tickets. |
| `transactional-writes-audit-jobs.md` | One-transaction ingest, the hash-chain audit log, idempotency, and the Oban job lanes. |
| `identity-tenancy-rbac.md` | Password and API-key identities, identity-derived Account selection, and deny-wins role inheritance. |
| `gate-a-b-governance.md` | The gate matrix, validation and consent lifecycle, human and MCP adapters, erasure semantics, and the `f4-1` contract transition. |
| `model-layer-structured-extraction.md` | Provider roles, structured validate-and-repair, the local Ortex/ONNX embedder, model provenance, the usage ledger, and the `f5-1` extraction transition. |
| `documents-connectors-sync.md` | The document and blob boundary, native extraction, chunking, dual ingest, incremental connector sync, immutable supersession, tombstones, erasure, and the portability seam. |
| `retrieval-entity-context.md` | Seed strategies, fusion, profiles, entity-resolution privacy, projections, and the reasoning-free context boundary. |
| `skill-readiness-procedural-memory.md` | Skill requirement cards, the selector language, and the gap report. |
| `portability-packaging-operations.md` | Packaging, logical Account archives, runtime validation, readiness, metering, and operations. |
| `evaluation-ci-release-readiness.md` | Deterministic evaluation gates, report provenance, database-mode CI parity, semantic versioning, changelog, and release controls. |

## Related

- `specs/adr/` — decisions with alternatives weighed and a chosen outcome.
- `specs/roadmap/beta-roadmap.md` — the only roadmap: outstanding work with
  acceptance criteria.
- `specs/observability/README.md` — local OpenTelemetry collection, Langfuse
  forwarding, trace and log safety defaults, and measurement discipline.
- `docs/concepts/` — user-facing explanations. Update the matching page with
  every observable behavior change.
