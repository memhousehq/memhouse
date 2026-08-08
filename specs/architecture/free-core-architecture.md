<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Free Core Architecture

Status: durable architecture reference.
Date: 2026-07-28.

This is the target architecture for the complete free self-host core: one
Account, one Mix release, one BEAM node by default, pg0 or external Postgres,
governed memory, local model options, public surfaces, RBAC, portability, and
release evaluation. See `specs/roadmap/beta-roadmap.md` for delivery and
`specs/implementation-status.md` for current behavior.

This document is subordinate to the blueprint specs and ADRs. The stable
anchors remain in:

- `specs/memory-system-functional-requirements.md`
- `specs/memory-system-architecture-and-nfr.md`
- `specs/memory-system-product-blueprint.md`
- `specs/adr/0003-embedded-postgres-pg0.md`
- `specs/adr/0004-multi-strategy-retrieval.md`
- `specs/adr/0005-peer-inline-validation-over-mcp.md`
- `specs/adr/0006-entity-resolution.md`

## Scope

The free core includes everything required to run MemHouse as a complete,
single-Account, self-hosted memory system:

- Full memory topology: Account, Peers, Scopes, scope tree, scope relations,
  sessions, raw observations, documents, knowledge, provenance, lifecycle,
  attributions, relations, projections, entities, and skill requirement cards
  (`FR-TOP-*`, `FR-KN-*`, `FR-SK-*`).
- The governed write path: agents submit raw observations only; the pipeline is
  the sole writer of knowledge; Gate A and Gate B decide retention, attribution,
  sensitivity, consent, and blast radius (`FR-FORM-*`, `FR-GOV-*`,
  `FR-API-12`).
- The read path: `get_context`, `ask`, `search`, `query_knowledge`, and
  `check_readiness`, with scope-anchored reads, downward inheritance,
  point-in-time filters, provenance filters, grounded answers, and abstention
  (`FR-API-*`).
- Multi-strategy retrieval: semantic, lexical, temporal, salience-recency,
  entity-match, relation expansion, reciprocal-rank fusion, optional rerank,
  named versioned profiles, deadlines, and strategy self-reporting
  (`FR-API-25` to `FR-API-29`, `AD-SEAM-3`).
- Single-node packaging: one Mix release, embedded pinned pg0 by default,
  external Postgres as a connection-string change, stock Postgres in containers,
  no Redis, no second engine runtime (`FR-PLAT-2`, `FR-PLAT-4`,
  `FR-PLAT-5`, `AD-CFG-2`).
- Provider-neutral models: four account-level model roles over ReqLLM,
  OpenAI-compatible and self-hosted endpoints, Ortex/ONNX default embeddings,
  pinned embedding versions, and usage metering by role (`FR-API-17` to
  `FR-API-20`, `AD-MODEL-*`, `FR-PLAT-8`).
- Free integration surfaces: AshJsonApi/OpenAPI, MCP over `ash_ai`, the
  OpenAI/Anthropic-compatible gateway proxy, Phoenix LiveView governance, and
  generated TypeScript/Python SDKs (`FR-API-11`, `FR-API-14` to `FR-API-22`,
  `AD-API-*`).
- Basic governance and transparency: validation queue, peer self-view, contest
  and redact, revalidation, immutable audit, history/diff view, local auth,
  API keys, magic links, per-scope roles, and RLS keyed on Account
  (`FR-GOV-*`, `FR-PLAT-6`, `AD-SEC-*`).
- Free portability: logical account export/import, audit hash-chain continuity,
  rebuild of derived caches on import, and documented backup/restore paths
  (`FR-PLAT-11`, `FR-PLAT-14`, `AD-PORT-*`).

The free core excludes enterprise-only scale and compliance features:

- Multiple Accounts, queue mode, clustered nodes, SSO/SAML/SCIM, schema/db per
  Account, granular enterprise RBAC, CMK, audit SIEM streaming, advanced
  retention controls, managed SaaS operations, and support/compliance packaging
  (`FR-PLAT-3`, `FR-PLAT-7`, `FR-PLAT-13`, `FR-PLAT-15`).
- The deferred graph/triple layer, AshGraphql, live streaming migration,
  carry-vectors import fast path, per-scope model-role overrides, far-scale
  sharding, and peer merge/aliasing unless a later blueprint change promotes
  them into scope.

## Prime structure

MemHouse is one Elixir/Ash/Phoenix/Oban codebase and one Mix release
(`AINV-1`, `AD-LANG-1`, `AD-LANG-2`):

```text
Surfaces
  Phoenix HTTP / AshJsonApi / MCP / gateway proxy / LiveView governance
    call
Ash Actions
  one typed operation set for ingest, reads, governance, skills, export/import
    coordinate
Domains
  Accounts, Topology, Observations, Knowledge, Governance, Pipeline,
  Retrieval, Context, Skills, Documents, Models, Operations, Portability
    use
Behaviours and Strategies
  Retrieval.Strategy, Fusion, Reranker, GatePolicy, Chunker,
  ModelTiering, Embedder, Generator, BlobStore, SecretStore
    run over
Infrastructure
  AshPostgres + pgvector + PG-FTS, Oban through AshOban, ReqLLM,
  local FS or S3-compatible blob, runtime config, telemetry
```

Surfaces call Ash actions; actions coordinate domains; domains use behaviours
and Ash data layers; only infrastructure knows `Repo`, ReqLLM providers, pg0,
or blob adapters. Core never imports enterprise modules.

## Domain decomposition

The free core is a modular monolith; boundaries are extraction points, not
services.

| Domain | Owns | Main anchors |
| --- | --- | --- |
| `MemHouse.Accounts` | Account, local identities, API keys, peer identity links, single-Account enforcement | `FR-TOP-1`, `FR-TOP-2`, `AINV-6`, `AD-SEC-*` |
| `MemHouse.Topology` | Scopes, materialized paths, scope relations, role grants, inheritance resolution | `FR-TOP-3` to `FR-TOP-11`, `FR-GOV-18`, `FR-GOV-19`, `AD-DATA-4` |
| `MemHouse.Observations` | Sessions, session scopes, participants, raw messages, documents, document versions | `FR-FORM-1` to `FR-FORM-13` |
| `MemHouse.Knowledge` | Knowledge items, attributions, provenance, lifecycle ledger, relations, current-state materialization | `FR-KN-*`, `FR-FORM-19` to `FR-FORM-23`, `AD-DATA-1` to `AD-DATA-3` |
| `MemHouse.Governance` | Gate A/B policy, validation queue, consent, peer self-view, contest/redact, audit, history/diff | `FR-GOV-*`, `AD-GOV-*`, `AD-DATA-8` |
| `MemHouse.Pipeline` | Ingest-time extraction, dream-time reasoning, revalidation/expiry sweeps, connector sync orchestration | `FR-FORM-14` to `FR-FORM-18`, `AD-PIPE-*` |
| `MemHouse.Retrieval` | Strategy behaviour, seed and expansion strategies, RRF fusion, rerank, profile versions, deadlines | `FR-API-25` to `FR-API-29`, `AD-SEAM-3` |
| `MemHouse.Context` | Reasoning-free `get_context`, projection reads, context budget assembly, salience-ranked knowledge slices | `FR-API-4`, `FR-API-5`, `FR-API-10`, `NFR-2` |
| `MemHouse.Query` | `ask`, `search`, `query_knowledge`, point-in-time and provenance filters, grounding and abstention | `FR-API-1` to `FR-API-8`, `FR-API-23`, `FR-API-24`, `FR-API-26` |
| `MemHouse.Skills` | Skill requirement cards, inherited requirements, readiness checks, gap reports, elicitation hooks | `FR-SK-*`, `FR-API-9` |
| `MemHouse.Documents` | Native extraction, chunking, document embeddings, content-hash sync hooks | `FR-FORM-9` to `FR-FORM-12` |
| `MemHouse.Model` | ReqLLM provider layer, model roles, structured generation, embedding role, usage emission | `FR-API-17` to `FR-API-20`, `AD-MODEL-*` |
| `MemHouse.Operations` | Health, readiness, telemetry, usage ledger, budget counters, local observability | `FR-PLAT-8` to `FR-PLAT-10`, `AD-OBS-*` |
| `MemHouse.Portability` | Logical export/import, import validation, cache rebuild scheduling, backup/restore runbooks | `FR-PLAT-11`, `FR-PLAT-14`, `AD-PORT-*` |
| `MemHouse.Release` | Runtime config validation, pg0 supervision, migration on boot, packaging modes | `FR-PLAT-2`, `FR-PLAT-4`, `FR-PLAT-5`, `AD-CFG-2` |

## Abstraction layers

Ash is the primary ports-and-adapters mechanism:

- Ash Resources are the durable type system and policy boundary.
- Ash Actions are the operation boundary. All public operations, background
  steps, and governance decisions resolve to actions instead of direct SQL
  helpers.
- Ash policies and Postgres RLS jointly enforce Account isolation. The edge
  derives Account from identity and sets Ash actor/tenant; request bodies never
  select an Account (`AINV-6`).
- AshOban owns background enqueue inside the same transaction as the state
  change that requires it (`AD-SEAM-4`, `AD-PIPE-1`).
- Ash.Reactor owns multi-step pipeline orchestration where steps need retries,
  compensation, idempotency, or human-signal continuation.
- Elixir behaviours own product strategy variability: retrieval strategies,
  gates, chunking, model tiering, embeddings, generators, rerankers, blob store,
  and secrets.
- Runtime config selects infrastructure location and enabled modules; DB-stored
  policy config selects behavior at Account/scope grain; per-query config can
  select a named retrieval profile only (`AD-CFG-1`).

## Durable stores and derived caches

The system of record is:

- raw sessions, messages, documents, and document versions;
- validated knowledge statements with attributions, provenance, lifecycle
  ledger, relations, sensitivity, confidence, valid-time, salience, and
  system-derived belief-time;
- immutable audit log entries and usage/metering events;
- policy/configuration records such as roles, model roles, budgets, gate
  matrix, channel allowlist, and skill cards.

Derived and rebuildable data is:

- peer profiles, scope cards, entity cards, session summaries, context projection fragments;
- entity and entity-mention caches;
- document chunks when they can be regenerated from durable document versions;
- vector and lexical indices;
- ETS and `persistent_term` hot caches.

Anything that writes a derived cache must have a rebuild path, dirty marking,
and erasure recomputation evidence (`AINV-5`, `FR-GOV-15`, `FR-GOV-16`,
`FR-KN-22`).

## Public operation set

The complete free core exposes these operations once as Ash actions and adapts
them to each surface:

- Agent-facing writes: `ingest`, `add_message`, document ingest, connector sync
  submit. These persist raw observations only and return before model work.
- Observation progress: the Account- and scope-authorised ingest-status read;
  operators can enqueue an Account reconciliation sweep independently.
- Reads: `get_context`, `ask`, `search`, `query_knowledge`, `check_readiness`.
- Peer inline validation over MCP: `resolve_validation` and
  `set_ask_preference`, restricted to the calling peer's own pending questions
  and clamp-only preference changes.
- Human governance: validation queue actions, scope proposal confirmation,
  consent, peer self-view, contest/redact, history/diff, export/import, local
  admin policy changes.
- Internal/eval probes behind explicit config: run dream-time now, inspect
  queue state, inspect lifecycle intervals, disable/fix retrieval deadlines,
  and run benchmark/report tasks.

## Contract version identities

These public contract versions are independent of application SemVer. The
`f`-prefixed values are historical tags, not roadmap phases:

| Identity | Covers |
| --- | --- |
| `poc-0` | The original frozen behaviour baseline and the pre-retrieval-rework evaluation reports. Historical evidence only. |
| `f4-1` | Governed lifecycle behaviour: proposals enter `proposed`/`provisional` or are held instead of auto-activating. |
| `f5-1` | Extractor and pipeline identity, reported by `GET /api/health`. |
| `f7-1` | Retrieval and context profile identity for `search`, `ask`, and `get_context`. |
| `f9-1` | Skill selector language and gap-report schema. |
| `f10-1` | Readiness payload shape. |
| `f11-1` | Evaluation report schema; `f11-suite-1` for the release report bundle. |
| `f11-surface-contracts-1` | Surface contract inventory schema. |
| `memhouse-account-1` | Logical Account archive schema. |

Changing any of these is a deliberate contract transition: it needs a changelog
entry, updated contract evidence, and a note in the closest architecture
document.

## Feature coverage

Free-core completion requires every row below to be implemented, tested, and
documented.

| Capability | Required in free core | Enterprise-only or deferred |
| --- | --- | --- |
| Single-node self-host | pg0-supervised release, external Postgres option, stock Postgres container | Queue mode and clustered HA |
| Data layer | AshPostgres, pgvector, PG-FTS, Oban-Postgres everywhere | Schema/db per Account |
| Accounts | One Account, identity-derived, RLS available | Multiple Accounts |
| Auth | Local auth, magic-link, API keys | SSO/SAML/SCIM |
| RBAC | Basic account-admin, curator, member, reader by scope with inheritance | Granular enterprise RBAC and ReBAC adapter |
| Memory model | Natural-language knowledge atom, provenance, lifecycle, relations, tri-temporal fields | Structured triples/knowledge graph |
| Pipeline | Ingest-time and dream-time lanes, AshOban, Reactor, gates, audit | Multi-node scale lanes |
| Governance | Validation queue, peer self-view, contest/redact, consent, revalidation, history/diff | SIEM streaming, extended retention controls |
| Retrieval | Full strategy set, profiles, deadlines, rerank where profile enables it | No retrieval-quality gate unless a human changes the licensing decision |
| Entities | Derived internal entity cache and entity-match retrieval | Public entity surface is prohibited |
| Documents | Native extraction, chunking, embeddings, sync behavior | Enterprise connector fleet operations |
| Surfaces | HTTP/OpenAPI, MCP, gateway proxy, LiveView governance | Enterprise admin/compliance dashboards |
| SDKs | Generated TypeScript and Python clients | None |
| Models | ReqLLM roles, OpenAI-compatible, self-hosted endpoints, Ortex embeddings | Multi-provider in-engine fallback |
| Observability | Health, metrics emission, redacted logs, usage ledger, local cost visibility | Prebuilt enterprise dashboards and SIEM export |
| Portability | Logical export/import, backup/restore docs | Scheduled enterprise backup service |
| Evaluation | Deterministic guardrails and release/nightly eval | None |

## Implementation notes

Implemented capability notes:

- `ash-domain-backbone.md`
- `transactional-writes-audit-jobs.md`
- `identity-tenancy-rbac.md`
- `gate-a-b-governance.md`
- `model-layer-structured-extraction.md`
- `documents-connectors-sync.md`
- `retrieval-entity-context.md`
- `skill-readiness-procedural-memory.md`
- `portability-packaging-operations.md`
- `evaluation-ci-release-readiness.md`

Integration surfaces, gateway, and generated SDKs remain unimplemented in
`specs/roadmap/beta-roadmap.md`.
