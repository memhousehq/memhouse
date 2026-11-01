<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Architecture decision records

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-licence.md) | Apache-2.0 for code, CC BY 4.0 for docs | accepted for development; counsel confirms before G09 |
| [0002](0002-lite-embedded-store.md) | Lite store: SQLite + FTS5, in-process vector scoring | proposed, pending review |
| [0003](0003-vector-storage-format.md) | Half-precision vectors, exact scan; binary prefilter optional | proposed, pending review |
| [0004](0004-intake-queue-and-log.md) | Store-backed intake queue; Kafka-protocol log for Scale | proposed, pending review; Scale confirmed at load in G31 |
| [0005](0005-authorization-store.md) | Relationship tuples in the profile's store, in-process evaluator | proposed, pending review |
| [0006](0006-connection-pooler.md) | In-process pools; PgBouncer ≥ 1.21 transaction mode with prepared statements | proposed, pending review |
| [0007](0007-minimum-pgvector.md) | Postgres 16+, pgvector 0.7.0+ (0.8.x recommended) | proposed, pending review |
| [0008](0008-grpc.md) | gRPC as a second binding of API v1, same binary, built in G30 | proposed, pending review (analysis) |

Evidence from the G03 technology spike is in [evidence/](evidence/); [spike-acceptance.md](evidence/spike-acceptance.md) maps it to the four acceptance criteria of section 6.10, including what is blocked. Each ADR lists what is still to
verify and in which roadmap goal. A new ADR copies the structure: decision, evidence, alternatives,
still to verify.
