<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ADR 0006 — Connection pooling: in-process pools; PgBouncer ≥ 1.21 in transaction mode when needed

| Field | Value |
|---|---|
| Status | **Accepted** by the user, 1 November 2026 (spike G03) ; load-tested in G30 |
| Date | 1 November 2026 |
| Requirements | TR-GW-03, TR-GW-05, PERF-08, SCALE-01 |
| Evidence | [evidence/spike-acceptance.md](evidence/spike-acceptance.md) (section 6.10 coverage), [evidence/postgres-spike.md](evidence/postgres-spike.md) |

## Decision

- **Standard** connects directly with sqlx's in-process pool (`[database] max_connections`). Keep
  `instances × max_connections` below the database's limit.
- When many instances share a database, or at **Scale** (one pool per shard, at most 200 server
  connections per shard, TR-GW-03), put **PgBouncer 1.21 or later in transaction mode** in front
  of each shard **with `max_prepared_statements` set** (200 is a good start). Statements stay
  prepared and pinned (TR-GW-05).
- Managed equivalents that support protocol-level prepared statements in transaction mode are fine
  (for example a managed PgBouncer); poolers that don't are not supported.
- `memhouse doctor` will detect a pooler in transaction mode without prepared-statement support
  and say so (G30), instead of failing with a cryptic error.

## Evidence (PgBouncer 1.26.1, transaction mode, full LoCoMo retrieval run)

| `max_prepared_statements` | Result |
|---|---|
| 0 | fails at once: `prepared statement "sqlx_s_1" already exists` |
| 200 | works; retrieval identical to a direct connection (session recall_all@5 78.8, round recall_all@10 59.2) |

## Alternatives considered

| Option | Why not |
|---|---|
| Disable prepared statements in the client | gives up plan stability and adds parse cost on every recall; TR-GW-05 asks for prepared statements |
| Session pooling | no connection multiplexing, so it doesn't solve the connection limit |
| Odyssey, PgCat, Supavisor | viable; PgBouncer is the most widely available on managed services and in customers' estates. Any of them that supports prepared statements in transaction mode can pass the same test |

## Still to verify (G30)

- Overhead at reference load (1,000 concurrent agents): the laptop run showed search p50 rising
  from about 9 to 17 ms through the pooler on a busy machine, to be measured properly on dedicated
  hardware.
