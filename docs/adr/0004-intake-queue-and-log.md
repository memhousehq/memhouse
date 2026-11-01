<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ADR 0004 — Intake queue and log: a store-backed queue now, a Kafka-protocol log for Scale

| Field | Value |
|---|---|
| Status | Accepted for Lite and Standard (G10); Scale candidate to confirm at load (G31) |
| Date | 1 November 2026 |
| Requirements | TD-04, TD-05, PR-6, SCALE-09, TR-IN-01 to TR-IN-07, TR-LT-05, PERF-03, PERF-04 |
| Evidence | [evidence/postgres-spike.md](evidence/postgres-spike.md) (`scripts/spike/run.sh`) |

## Decision

All write intake goes through one **`IntakeQueue` trait** (and background work through a
**`JobRunner` trait**), introduced in G10. Implementations:

| Profile | Intake queue | Why |
|---|---|---|
| Lite | a table in the SQLite file | one file, durable on commit, no extra process |
| Standard | a Postgres table claimed with `FOR UPDATE SKIP LOCKED` (today's `mh_enrich_job` pattern), partitioned by status and pruned | the customer's database is the only dependency |
| Scale | a partitioned, replicated **log speaking the Kafka protocol**, partitioned by subject bucket | per-subject ordering, replay, 100,000 writes per second (TD-04) |

For Scale the adapter targets the **Kafka protocol, not a product**: Apache Kafka (KRaft, Apache-2.0)
is the reference for self-hosted and sovereign deployments; managed services that speak the
protocol (Amazon MSK, Confluent, Aiven, Azure Event Hubs' Kafka endpoint) and Redpanda (check its
licence terms for redistribution) work through the same adapter. Long-running compliance work uses
a workflow engine (TD-05) chosen in G31; it is not used for intake.

## Evidence (laptop, Docker, synchronous commit on)

| Workload | Throughput |
|---|---|
| enqueue, 16 clients | 39,012 per second (0.41 ms) |
| claim + finish, 16 workers | 9,539 per second (1.68 ms) |
| claim + finish, 64 workers | 6,809 per second (9.40 ms) — contention grows with workers |

A Postgres queue covers Lite and Standard by two orders of magnitude, but not the national
profile's 100,000 writes per second, and adding workers reduces its throughput. That is where the
log takes over.

## Alternatives considered

| Option | Why not (for Scale intake) |
|---|---|
| Postgres queue at Scale | throughput falls with workers; no replay; one hot table per shard |
| NATS JetStream | good and Apache-2.0, but fewer managed offerings in regulated clouds and less tooling for exactly-once consumers |
| RabbitMQ streams | weaker per-key ordering and replay story |
| Temporal for intake | volume mismatch (TD-05 keeps it for compliance workflows) |

## Still to verify (G31)

- At 25% of the national profile: acknowledgement p95 ≤ 50 ms after replication to two replicas
  (TR-IN-02, PERF-03), ordering per subject (TR-IN-01), exactly-once effects (TR-IN-03),
  poison-message quarantine (TR-IN-07), back-pressure (TR-IN-06).
- On one managed service and self-hosted with no external dependencies (section 6.10).
