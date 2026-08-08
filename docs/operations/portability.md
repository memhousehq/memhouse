<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Logical Export And Import

Logical archives move one community Account between deployments and blob
adapters. They do not replace point-in-time backups.

Export from a running unpacked release:

```bash
bin/memhouse rpc \
  'MemHouse.Release.export!("/secure/path/memhouse-account.tar.gz")'
```

From source, the equivalent command is
`mix memhouse.portability.export --output /secure/path/memhouse-account.tar.gz`.
Keep the archive as sensitive user data even though credentials and secrets are
excluded.

Validate before transfer and again at the destination:

```bash
bin/memhouse rpc \
  'MemHouse.Release.validate_archive!("/secure/path/memhouse-account.tar.gz")'
```

Import requires a migrated database with no Account occupying the archived id
or community slot:

```bash
bin/memhouse rpc \
  'MemHouse.Release.import!("/secure/path/memhouse-account.tar.gz")'
```

From source, use
`mix memhouse.portability.import --input /secure/path/memhouse-account.tar.gz`
and add `--validate-only` for validation.

Before writing, import verifies all manifest, resource, and blob SHA-256 values
and the full audit graph. It writes in one Account-scoped transaction, then
enqueues replay-keyed document and scope rebuilds.

After import:

1. Require `GET /api/ready` to return 200.
2. Wait until portability jobs leave the available, scheduled, retryable, and
   executing states.
3. Confirm expected governed search/context behavior.
4. Recreate human passwords and API keys; credentials are intentionally not
   exported.
5. Confirm the configured embedder identity. Derived vectors are rebuilt in
   the destination vector space and are never silently reused.
6. Retain the source until resource counts, audit head/count, blobs, and
   representative reads have been checked.

The archive excludes password hashes, API keys, all secret values, knowledge
vectors, chunks, projections, entities, entity mentions, and extracted-text
caches. Original document blobs and durable document-version metadata are
included and checksum verified.
