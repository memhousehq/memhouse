<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Postgres spike results: intake queue, authorization store, connection pooler

Measured on 1 November 2026 on a laptop (Apple Silicon, Docker Desktop), Postgres 17.11 with
pgvector 0.8.7 in the `memhouse up` container, while other heavy processes were running.
Reproduce with `scripts/spike/run.sh` (queue and authorization) and the PgBouncer steps below.

## Intake queue: one Postgres table claimed with `FOR UPDATE SKIP LOCKED`

Schema and scripts: `scripts/spike/queue_*.sql` (the same pattern as `mh_enrich_job`).
300,000 jobs preloaded; synchronous commit on (every acknowledgement is durable).

| Workload | Clients | Throughput | Mean latency |
|---|---|---|---|
| enqueue (one insert per write) | 16 | 39,012 per second | 0.41 ms |
| claim + finish (one worker iteration) | 16 | 9,539 per second | 1.68 ms |
| claim + finish | 64 | 6,809 per second | 9.40 ms |

Throughput falls as workers are added: they contend on the head of the pending index and on dead
tuples. Plenty for Lite and Standard (one tenant: tens to hundreds of writes per second); not the
100,000 writes per second of the national profile (TD-04).

## Authorization store: relationship tuples in Postgres, uncached checks

Schema and check: `scripts/spike/authz_*.sql`. 100,000 patients, 5,000 clinicians, 500 teams,
50 wards; 1,111,000 tuples with validity windows (5% of treating relations already ended). A
check returns the granting chain or `deny`: direct `treating`, or clinician → team → ward ←
patient (three joins). Random clinician–patient pairs, so most checks are denials, which evaluate
both paths (the worst case).

| Clients | Checks per second | p50 | p95 | p99 |
|---|---|---|---|---|
| 1 | 3,409 | 0.28 ms | 0.32 ms | 0.40 ms |
| 16 | 17,575 | 0.55 ms | 2.75 ms | 5.86 ms |

TR-AZ-02 asks for p95 ≤ 5 ms uncached: met with room to spare at 16 concurrent clients, before any
decision cache (TR-GW-04).

## Connection pooler: PgBouncer 1.26.1 in transaction mode

`edoburu/pgbouncer` image, `pool_mode = transaction`, `default_pool_size = 10`, in front of the same
Postgres; full LoCoMo retrieval run (`memhouse bench run --dataset locomo --database-url
postgres://…@127.0.0.1:6432/…`, 1,540 recalls, 4 concurrent).

| `max_prepared_statements` | Result |
|---|---|
| 0 (protocol-level prepared statements off) | **fails at once**: `prepared statement "sqlx_s_1" already exists` — sqlx prepares named statements, and transaction pooling hands them to other server connections |
| 200 (PgBouncer ≥ 1.21) | **works**: session recall_all@5 78.8, round recall_all@10 59.2 — identical to the direct connection; search p50 16.8 ms, p95 38.0 ms through the pooler on a busy machine (direct baseline ≈ 9 ms p50) |

Setup notes: inside the PgBouncer container `host.docker.internal` resolved to an IPv6 address
that didn't reach Postgres; the host gateway's IPv4 address worked. Passwords were passed in a
temporary `userlist.txt` (mode 700 directory, deleted afterwards), never on the command line.
