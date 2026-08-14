<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Portability, Packaging, And Operations

Status: implemented on 2026-07-28.

The community core is installable, movable, observable, and recoverable without
changing its 38-Resource durable boundary. This implements FR-PLAT-2, FR-PLAT-5, FR-PLAT-8 through
FR-PLAT-11, FR-PLAT-14, AD-CFG-2, AD-PORT-1 through AD-PORT-4, AD-OBS-1
through AD-OBS-7, NFR-7 through NFR-9, and ADR-0003. The ARCH prime directive
remains intact: pg0 and external Postgres wrap the same release, Repo, Ash
actions, migrations, queues, and behavior.

## Deployment boundary

`MEMHOUSE_DATABASE_MODE` is exactly `pg0` or `external`. Runtime validation
rejects an unsupported mode, a missing external `DATABASE_URL`, a conflicting
pg0 `DATABASE_URL`, an invalid port, a missing or non-executable pg0 binary, a
relative data/blob path, incomplete S3 configuration, and structurally invalid
model roles before the durable services start.

The no-container release stages pg0 v0.14.2, PostgreSQL 18.1.0, pgvector 0.8.1,
and pgvectorscale 0.9.0. Packaging builds pgvectorscale against pg0's extracted
`pg_config`, verifies the pinned source digest, and records a package-local
manifest for every staged file. At boot, pg0 verifies and copies those files
into its versioned installation before Repo starts. The release
supervisor starts pg0 before `MemHouse.Repo`, runs migrations before serving,
detects a conflicting port, moves a dead `postmaster.pid` aside instead of
deleting it, attaches to a live data directory, and stops its named instance on
orderly shutdown. The Unix launcher creates a private, persistent local data
root and signing secret on first run. Packaged pg0 supports glibc Linux
x86_64/ARM64 and Apple Silicon.

The container image deliberately contains no pg0. `compose.yml` runs the same
release against the digest-pinned `timescale/timescaledb-ha:pg18-all-oss`, uses durable database
and blob volumes, and offers an `observability` profile for the OpenTelemetry
Collector, Jaeger, and Prometheus. Redis and a second worker runtime remain
absent.

## Logical portability

The archive schema is `memhouse-account-1`. A gzip tar contains:

- `manifest.json` with Account identity, embedder provenance, resource counts
  and checksums, blob checksums, audit head/count, and explicit exclusions;
- one streaming, keyset-paginated JSONL file for each portable durable
  Resources;
- checksum-addressed original document blobs.

Export runs in one Account-scoped database transaction. Import rejects unsafe
tar paths, unknown schemas/resources, checksum or count mismatches, blob hash
mismatches, and any branched, cyclic, disconnected, or content-tampered audit
chain before opening its write transaction. All durable restoration uses
private Ash actions under the system/pipeline actor, preserving ids, valid
times, belief times, and content-safe audit hashes. Retained lifecycle history,
usage events, and pipeline replay keys stay local to the source installation.
Deferred self-links are restored only after their
rows exist.

Credentials, password hashes, secret values, vectors, document chunks,
projections, entities, entity mentions, extracted-text caches, and extraction
metadata are not portable. Import targets a fresh Account, stores verified
blobs through the configured blob adapter, commits resource restoration once,
then enqueues replay-keyed scope and document rebuild work. Independent
provenance and immutable document history remain intact.

## Operational surfaces

`GET /api/health` remains the frozen baseline liveness contract.
`GET /api/ready` adds the versioned `f10-1` operator contract (a historical
version tag, not a roadmap phase) and returns 200 only when the app,
database, Oban supervisor, queue query, and five model-role configurations are
healthy; failures return content-safe error classes with 503. Its informational
model-call check reports a prior-24-hour attempt count, failure rate,
unmetered-failure count, and error-class counts. Provider failures do not make
the process unready because durable jobs retry them.

Every authenticated HTTP request emits an exact `UsageEvent`; ingest requests
are identified separately. Model usage continues to have one durable emission
point in `MemHouse.Model.Usage`. Rebuildable ETS counters provide inexpensive
daily admission checks, with dream-time throttled before user-facing ingest or
governed reads. Account administrators can inspect exact API, ingest, token,
role, logical-storage, and model-call-health totals plus operator-configured USD estimates at
`GET /api/v1/operations/costs`.

Production logs use a JSON formatter with an explicit metadata allowlist and
credential redaction. Queue depth and portability duration telemetry join the
existing HTTP, model, pipeline, governance, document, retrieval, and context
spans. Payloads, prompts, keys, document text, connector cursors, and knowledge
content remain excluded.

## Evidence

The focused contract is
`test/memhouse/f10_portability_packaging_operations_test.exs`. It covers
archive composition/exclusions, audit tamper rejection, readiness, exact edge
metering/cost visibility, and packaging invariants.

Real-system evidence:

- A two-database round trip matched 33 resource counts, six audit events, and
  the final audit hash; the target enqueued two rebuilds and imported no vectors.
- The package initialized pg0, migrated, became ready, and stopped cleanly.
- The external lane uses the same contracts against `compose.yml` Postgres.
- The production container ran as UID 10001, contained neither Rust nor pg0,
  and returned `f10-1` readiness.

Operator procedures live in:

- `docs/operations/README.md`
- `docs/operations/portability.md`
- `docs/operations/backup-restore.md`
