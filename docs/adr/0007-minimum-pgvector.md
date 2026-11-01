<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ADR 0007 — Minimum pgvector 0.7.0 (0.8.x recommended), Postgres 16 or later

| Field | Value |
|---|---|
| Status | Accepted (spike, G03); enforced at start-up from G04 |
| Date | 1 November 2026 |
| Requirements | TR-DB-02, SCALE-05, SCALE-06, DEP-01, TD-02 |

## Decision

- **Postgres 16 or later; pgvector 0.7.0 or later.** 0.7.0 is the first version with everything
  ADR 0003 needs: the `halfvec` type, `bit` vectors, `binary_quantize()` and the Hamming operator
  `<~>`. **0.8.x is recommended.**
- No index type is required (per-subject scoring is exact), so pgvector's HNSW and IVFFlat
  improvements in 0.8 are not a dependency.
- From G04 the schema migration checks `extversion`: below 0.7.0 it warns and names the upgrade
  (`ALTER EXTENSION vector UPDATE`); from G30, when the `halfvec` columns arrive, it refuses to
  start below 0.7.0.

## Evidence

| Where | pgvector | Source |
|---|---|---|
| Local `pgvector/pgvector:pg17` image (`memhouse up`) | 0.8.7, all ADR 0003 queries run | spike run, [evidence/storage-spike.md](evidence/storage-spike.md) |
| Amazon RDS for PostgreSQL 17 | 0.8.0 at launch; 0.7.0 available on earlier majors since May 2024 | [AWS announcement](https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-rds-postgresql-supports-version-17), [extension versions](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-extensions.html), [0.7.0 on RDS](https://aws.amazon.com/about-aws/whats-new/2024/05/amazon-rds-postgresql-pgvector-0-7-0) |
| Azure Database for PostgreSQL Flexible Server | 0.7.0 GA July 2024, 0.8.0 later | [Azure release notes](https://docs.azure.cn/en-us/postgresql/flexible-server/release-notes), [Microsoft blog](https://techcommunity.microsoft.com/blog/adforpostgresql/-/4410710) |
| Google Cloud SQL / AlloyDB | **not confirmed** in this spike | to check on a live instance (`SELECT extversion FROM pg_extension WHERE extname = 'vector'`) |
| Supabase, other providers | 0.7.0 features documented since 2024 | [Supabase: what's new in pgvector 0.7.0](https://supabase.com/blog/pgvector-0-7-0) |

Today's code only uses `vector` and `<=>` (available since pgvector 0.5), so existing installs keep
working until the `halfvec` migration (G30). Until then the G04 check refuses only below 0.5.

## Still to verify

- Cloud SQL and AlloyDB versions on a live instance (on a test project), before the
  G30 migration ships.
- The compatibility matrix test (TR-DB-02) in CI against each supported image once hosted CI
  exists (G09).
