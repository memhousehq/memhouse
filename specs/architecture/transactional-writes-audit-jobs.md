<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Transactional Writes, Audit, And Jobs

Status: implemented

An accepted raw observation, its immutable audit event, durable processing
identity, and AshOban job share one PostgreSQL transaction. This implements
`AD-DATA-8`, `AD-PIPE-1`,
`AD-PIPE-3`, `AD-PIPE-4`, `AD-SEAM-4.2`, `AD-SEAM-4.3`, `FR-KN-9`,
`FR-FORM-8`, `FR-GOV-17`, `FR-GOV-20`, and `NFR-8`. `poc-0` is a historical
version tag for the frozen baseline, not a roadmap phase.

## Transaction boundary

`MemHouse.Observations.Message.create` and
`MemHouse.Observations.DocumentVersion.create` use Ash changes that:

1. compute a SHA-256 content hash without copying content into operational
   metadata;
2. append an Account-local audit event;
3. create or reuse a unique `MemHouse.Operations.PipelineRun`; and
4. insert its AshOban trigger job.

All four writes use the caller's `MemHouse.Repo` transaction; any error rolls
back all four. Message ingest is always asynchronous: HTTP and MCP acknowledge
with the message id after commit and never run a model in the caller. The
Account- and scope-authorised HTTP status read exposes pending, failed, or
completed processing and only knowledge visible to that actor.

`PipelineRun` is durable processing state, not a second queue. Its unique
`{account_id, idempotency_key}` identity lets the reconciler and event sources
request the same work repeatedly. Oban remains the single execution engine in
both deployment modes.

The account-admin reconciliation operation enqueues the Account sweep directly,
so recovery does not depend on another ingest request arriving.

Expiry and revalidation have no request-side event. The sole Oban Cron entry
therefore starts `LifecycleScheduler` hourly. It opens the provisioned
community Account and creates the two normal `PipelineRun` rows through Ash.
The Account, sweep kind, and Cron `scheduled_at` slot form each replay key, so
late execution and retry reuse work. See `ADR-0013`.

## A background job declares its own Account

Background jobs begin without request-installed Account settings. Under
`AD-DATA-1` RLS, an undeclared connection cannot see or update its
`pipeline_runs` row. AshOban would therefore cancel the worker read as
`trigger_no_longer_applies` and report its failure update as stale, incorrectly
making outstanding work look complete.

The declaration therefore belongs to the actions themselves, not to their
callers:

- `PipelineRun.for_trigger` is a transactional read used by every trigger's
  `worker_read_action`. `MemHouse.Pipeline.Preparations.DeclareAccount`
  installs the query's tenant before the statement runs.
- `PipelineRun.execute` and `PipelineRun.mark_failed` carry
  `MemHouse.Pipeline.Changes.DeclareAccount`, which installs the updated row's
  own Account inside the action's transaction.
- `MemHouse.DataLayer.declare_account!/1` performs the installation and never
  overwrites a declaration already in force, so an enclosing Account-scoped
  transaction still wins and the change can never switch or widen tenancy.

`execute` is transactional only for its status write. A `before_transaction`
hook keeps the long Reactor outside that transaction.

## No external call inside an Account transaction

A transaction holds one pooled connection. `MemHouse.Repo` keeps
DBConnection's 15,000 ms ownership timeout, while a model call may take 120,000
ms (`MEMHOUSE_MODEL_RECEIVE_TIMEOUT_MS`) and structured generation permits two
repairs. Keeping that call in a transaction can close the connection, discard
the post-call write, retry billed work, and charge the Account twice.

Such work has three phases: a short read transaction, the external call without
a connection, and a short result transaction. `MemHouse.Memory.extract_message/2`,
`MemHouse.Memory.extract_message_for_account/2`, and
`MemHouse.Documents.Service.process_version_for_account/2` all have this
shape. The document external phase also fetches the blob, parses, and embeds.

Two database operations remain inside a provider call: resolving the Account's
`ModelRoleConfig` and appending its `UsageEvent`. Both use
`MemHouse.DataLayer.in_account_transaction/2`, which installs the Account
setting the row-level-security policies read without resolving an Account row
or building an actor. Nesting is deliberate: it always opens a transaction
rather than branching on `Repo.in_transaction?/0`, because under the SQL
sandbox already wraps every test in a transaction; branching would leave the
production path untested.

Usage commits independently because the call remains billable even if the
caller's later write fails.

The write phase retains the duplicate check and transaction-scoped advisory
lock. Observations and versions are marked processed only on commit, so the
reconciler finds interrupted extraction.

## Job and Reactor map

| Lane | Queue | Orchestration |
| --- | --- | --- |
| message/document extraction | `ingest` | `IngestExtraction` Reactor |
| dream-time, entity resolution, projection refresh | `dream` / `projection` | `DreamTimeReasoning` Reactor |
| revalidation and expiry | `lifecycle` | maintenance Reactor continuation |
| validation and answer correlation | `governance` | dedicated continuation Reactors |
| connector sync | `connector` | maintenance Reactor continuation |
| import-derived-cache rebuild | `portability` | maintenance Reactor continuation |
| unprocessed-record reconciliation | `reconciler` | Account-scoped reconciler |

This capability owns durable execution, retries, uniqueness, and continuation.
Governance owns gate/lifecycle semantics; the model layer owns extraction and
reasoning; document sync owns connectors; retrieval owns projections; and
portability owns logical import/export.

## Idempotency and reconciliation

`MemHouse.Pipeline.Idempotency` defines deterministic keys for:

- message id plus content hash;
- document-version id plus content hash;
- scope plus dream-time watermark;
- scope plus projection watermark;
- scope plus entity-resolution watermark;
- import id plus manifest hash;
- validation decision plus knowledge id; and
- validation question plus session id.

Knowledge merges take a transaction-scoped, Account/key advisory lock before
the exact-statement check. Replay reuses the knowledge item, attribution, and
provenance rows and does not append a second creation lifecycle event. The
Account-scoped reconciler scans raw messages without
`extraction_completed_at` and re-enqueues the deterministic extraction key.

`MemHouse.Pipeline.Lock` is the transactional-writes infrastructure exception
that uses a parameterized PostgreSQL advisory-lock query. It performs no
durable write; all durable state still goes through Ash actions.

## Audit chain

`MemHouse.Governance.AuditEvent` remains append-only and now carries:

- event category and action;
- resource id/type;
- optional content hash, never raw content;
- content-safe metadata;
- the previous Account event hash; and
- the deterministic SHA-256 event hash.

An Account-scoped advisory lock serializes only that Account's chain tip. The
audit action reads the prior tip and inserts the event with the domain change.
Reserved categories cover lifecycle, gate, attribution, observation, deletion,
configuration, and governance; all emit through the same append API.

## Evidence

`test/memhouse/f2_transactional_writes_audit_jobs_test.exs` proves:

- commit coupling for raw observation, audit, pipeline run, and Oban job;
- rollback coupling after audit and enqueue;
- actual AshOban execution through the ingest Reactor;
- replay-safe knowledge/provenance/lifecycle behavior;
- raw persistence while a configured model provider is unavailable;
- deterministic audit-chain recomputation with no raw content in metadata;
- trigger execution and failure recording on a connection with no Account
  declared, which is the state every background job actually starts from; and
- registration of every transactional trigger, Reactor, category, and key
  family.

The frozen API baseline contract tests and the Ash domain backbone action/RLS
suite remain regression gates.
