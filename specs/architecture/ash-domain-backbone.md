<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Ash Domain Backbone

Status: implemented

Ash Resources, Actions, tenancy, and policies are the durable-data boundary.
The migration from direct writes preserved the frozen `poc-0` public contract;
`poc-0` is a historical contract tag, not a roadmap phase.

## Domain ownership

| Ash domain | Resources |
| --- | --- |
| `MemHouse.Accounts` | Account, Peer, ExternalIdentity, ApiKey (added by identity, tenancy, and RBAC) |
| `MemHouse.Topology` | Scope, ScopeRelation, RoleGrant |
| `MemHouse.Observations` | Session, SessionScope, SessionParticipant, Message, Document, DocumentVersion |
| `MemHouse.Knowledge` | KnowledgeItem, Attribution, Provenance, KnowledgeRelation, LifecycleEvent, Projection, Entity, EntityMention |
| `MemHouse.Governance` | AuditEvent, PolicyConfig |
| `MemHouse.Model` | ModelRoleConfig |
| `MemHouse.Retrieval` | RetrievalProfile |
| `MemHouse.Skills` | SkillRequirementCard |
| `MemHouse.Operations` | UsageEvent |

This map implements `FR-TOP-*`, `FR-KN-*`, `FR-FORM-*`, `FR-GOV-*`,
`AD-DATA-*`, and `AD-SEC-*`; the target map is in
`specs/architecture/free-core-architecture.md`.

## Action rules

- Account, scope, peer, session, and session membership metadata have explicit
  create/read/update actions where mutation is legal.
- Message content and document-version content are create-only.
- Knowledge statements are immutable. Only a pipeline actor may call
  `create_from_pipeline` or `merge_from_pipeline`; merge cannot change the
  statement.
- Provenance and audit events are durable. Lifecycle, gate, usage, and terminal pipeline history
  are immutable while retained and are removed only by the internal retention worker.
- Policy, model-role, retrieval-profile, role-grant, and skill-card mutations
  require a governance or system role.
- Entity and entity-mention actions are pipeline-internal and have no public
  route, preserving `FR-KN-21`.
- Projection writes are pipeline-only. Entity cards may store a private entity
  id as a cache coordinate, but their public context payload contains only a
  summary, sensitivity, provenance, and governed statement fields.

`MemHouse.Memory` remains a compatibility facade for the HTTP and eval
surfaces, but its durable reads and writes call Ash actions. Retrieval, entity
resolution, and context removed `MemHouse.Memory.Query`; database-native
retrieval reads now live in the reviewed read-only
`MemHouse.Retrieval.Store` data-layer helper.

## Isolation

The Account wall has three in-process/database layers:

1. `MemHouse.DataLayer` installs one identity-derived Account as the Ash actor
   and tenant for an Account-scoped transaction.
2. Ash attribute multitenancy and policies filter every Account resource;
   scoped reads additionally use the actor's resolved scope ids.
3. PostgreSQL RLS is enabled and forced on `accounts` and every table carrying
   `account_id`. Policies use transaction-local `memhouse.account_id` (and
   `memhouse.account_key` only while bootstrapping the initial Account). This
   layer only enforces when the connection itself is neither a superuser nor
   holds `BYPASSRLS` — PostgreSQL exempts both unconditionally, and `FORCE ROW
   LEVEL SECURITY` does not change that. `MemHouse.Database.AppRole`
   provisions a `NOSUPERUSER NOBYPASSRLS` role and switches every pooled
   connection to it at boot; `MemHouse.Database.RoleGuard` refuses to serve
   traffic if that switch did not take (`ADR-0008`).

Password/JWT and API-key identities replaced the HTTP Account header. Free mode
enforces one Account and inherited RBAC; legacy account-key adapters remain
internal to evaluation and migration compatibility paths.

## Migration and evidence

`priv/resource_snapshots/` contains the AshPostgres resource snapshots.
`priv/repo/migrations/20260727142300_f1_ash_domain_backbone.exs` is the
Ash-generated additive migration, manually reviewed and extended with
pgcrypto/pgvector setup, PostgreSQL FTS, indexes, foreign keys, and RLS.

Deterministic evidence is in:

- `test/memhouse/f1_ash_domain_backbone_test.exs`;
- the frozen baseline contract tests listed in `AGENTS.md`; and
- `mix ash.codegen --check`, which detects resource/snapshot drift.

Related implementation notes:

- `transactional-writes-audit-jobs.md` — transactional state, audit,
  `PipelineRun`, and AshOban coupling.
- `retrieval-entity-context.md` — retrieval SQL, entity resolution, and context.
- `identity-tenancy-rbac.md` — `MemHouse.Accounts.ApiKey` and authenticated
  RBAC resolution; domain ownership is unchanged.
- `skill-readiness-procedural-memory.md` — the existing
  `SkillRequirementCard`, versioned selectors, inheritance, and readiness.
