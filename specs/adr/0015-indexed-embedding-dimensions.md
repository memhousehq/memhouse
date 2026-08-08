<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0015: Indexed embedding dimensions

## Status

Accepted

## Context

The shipped semantic-retrieval indexes are 1024-dimensional DiskANN expression
indexes. The runtime previously allowed another embedder width. Retrieval stayed
correct but PostgreSQL used a sequential scan, which made a valid configuration
create an unbounded performance failure.

## Decision

The configured embedder dimensions must match an installed vector index before
supervision starts. This release installs 1024-dimensional indexes only.

`GET /api/ready` includes an `embedding_index` component. It reports status,
provider, model, version, configured dimensions, and installed dimensions. It
does not report vectors, stored content, credentials, index definitions, or
database metadata. A mismatch makes the process not ready.

Supporting another width requires a reviewed index migration, a full re-embed,
readiness evidence, and a configuration-contract update.

## Consequences

Operators cannot start an instance that would silently use an unindexed
semantic-retrieval path. Account, scope, lifecycle, provisional-subject, and
embedding-identity filters in the existing 1024-dimensional query are
unchanged.

## Anchors

- `FR-PLAT-4`
- `AD-DATA-5`
- `AINV-8`, `AINV-10`
- `NFR-2`

## Related Documents

- `specs/architecture/retrieval-entity-context.md`
- `docs/reference/configuration.md`
- `docs/operations/health-and-costs.md`
