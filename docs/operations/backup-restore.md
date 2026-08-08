<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Physical Backup And Restore

Back up the Postgres database and original blob store at the same recovery
point. Chunks, projections, DiskANN indexes, ETS counters, and
`persistent_term` caches are rebuildable.

## Embedded pg0

For a cold backup, stop `bin/server` cleanly and verify its pg0 instance has
stopped. Copy the complete `MEMHOUSE_PG0_DATA_DIR` and
`MEMHOUSE_BLOB_ROOT`, preserving ownership, permissions, and timestamps.
Record the MemHouse release version, pg0 version from `rel/pg0/VERSION`,
PostgreSQL version, paths, time, and a checksum inventory.

Restore only while MemHouse and pg0 are stopped:

1. Move the failed directories aside; do not merge file trees.
2. Restore the database and blob directories from the same snapshot epoch.
3. Restore their original owner and private permissions.
4. Start the same MemHouse release and require `/api/ready` to return 200.
5. Run a logical export validation and representative governed reads.
6. Upgrade only after the restored version is healthy.

Never copy a live Postgres data directory. For an online embedded backup, use
PostgreSQL `pg_basebackup` or an operator-managed filesystem snapshot with the
required PostgreSQL backup coordination.

## External Postgres

Use the platform's physical backup or PITR facilities, including WAL archiving,
retention, encryption, and restore tests. Snapshot the blob namespace at the
same recovery point. Restoring only one side can orphan document bytes or
references.

For a logical emergency copy, use `pg_dump`/`pg_restore` with the exact server
major version. Include extensions, schemas, functions, RLS policies, Oban, and
all MemHouse tables. Unlike a portable Account archive, this dump contains
credentials and deployment state.

## S3-compatible blobs

Enable bucket versioning and a retention policy appropriate to the user's
requirements. Back up object bytes and metadata under the configured prefix.
Validate restored objects against `document_versions.content_hash`; do not copy
object names, bytes, connector metadata, or credentials into logs or audit
metadata.

## Restore drill

At a regular cadence, restore into an isolated environment, then verify:

- migrations and `/api/ready`;
- Account, message, knowledge, usage, pipeline, and audit counts;
- audit-chain continuity through a portability validation;
- checksum retrieval for a sample of original document blobs;
- successful rebuild of document chunks, vectors, entities, and projections;
- authenticated Account isolation and one representative governed answer.

Record only ids, counts, timings, hashes, versions, and error classes in the
drill evidence.
