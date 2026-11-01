<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Section 6.10 acceptance coverage

Technical document section 6.10 asks every spike candidate to pass four things. This page says, for
each candidate, what was **measured** in G03, what is **extrapolated** from those measurements, and
what is **blocked** because it needs an environment this spike did not have. Nothing blocked is
marked as passed.

**25% of the reference national profile** (requirements 7.10): 12.5 million subjects, 6.25 billion
records, 500,000 concurrent sessions, **25,000 recalls per second and 25,000 write proposals per
second**. A laptop cannot carry that load; the spike measured per-node capacity on the laptop and
compares it with the share of that load each candidate must carry.

## Summary

| Criterion (6.10) | Lite store | Vector format | Intake queue/log | Authorization store | Connection pooler | pgvector |
|---|---|---|---|---|---|---|
| Acceptance tests at 25% of the national profile | n/a (Lite has its own targets) | extrapolated ✓ (sizes); load blocked | measured: Postgres queue ✗ for 25% → log required; log itself blocked | extrapolated ✓ with 2 nodes or a cache; load blocked | blocked | n/a |
| Customer's database: self-hosted and ≥ 1 managed service | self-hosted ✓ (file) | self-hosted ✓; managed **blocked** | self-hosted ✓; managed **blocked** | self-hosted ✓; managed **blocked** | self-hosted ✓; managed **blocked** | self-hosted ✓; managed from documentation only, Cloud SQL unconfirmed |
| Sovereign: no external dependencies | ✓ measured, network denied | ✓ (pgvector only) | ✓ Postgres; Apache Kafka self-hostable | ✓ in-database, no service | ✓ self-hosted PgBouncer | ✓ |
| Lite: PROF-04, PROF-06, PROF-07 on the reference laptop | PROF-04 ✓, PROF-07 ✓, PROF-06 ✓ store only; the bundled local model has its own budget (user decision) | — | — | — | — | — |

**Not run here, moved by the user's decision (1 November 2026):** the managed-service runs go to
G30 ("keep managed Postgres for later") and the 25% load tests to G27, G30 and G31, which have a
production-like cluster. They are listed in each ADR under "Still to verify" and in those goals'
deliverables, and are not claimed here.

## Lite store (ADR 0002) — measured

From [lite-profile-spike.md](lite-profile-spike.md), 100,000 memories, 10,000 per subject, fresh
process, all networking denied:

| Requirement | Target | Result |
|---|---|---|
| PROF-07 recall p95 | ≤ 50 ms | 25.9–28.5 ms with local query embedding; 13.8 ms store only ✓ |
| PROF-07 write acknowledgement p95 | ≤ 20 ms | 3.34 ms with power-loss-safe `fullfsync` ✓ |
| PROF-07 gated memory recallable | ≤ 2 s | 23–26 ms p95 ✓ |
| PROF-06 binary | ≤ 100 MB without models | 45.9 MB ✓ |
| PROF-06 resident memory with 100,000 memories | ≤ 256 MB | store only 16 MB ✓; the local model 394 MB (1 session) / 610 MB (4 sessions) is outside the budget by the user's decision; a remote embedding API loads no model |
| PROF-04 single process, embedded store, in-process jobs, no external service | — | ✓ (network denied for the whole run) |

## Vector format (ADR 0003) — extrapolated sizes at 25%

| Quantity at 25% | f32 (`vector`) | half precision + bit copy (decided) |
|---|---|---|
| Per vector | 1,540 B | 776 B + 53 B |
| Binary prefilter copy per record (SCALE-06: ≤ 128 B) | — | 53 B per vector; 106 B for a round with two vectors ✓ |
| 6.25 billion records, one vector each | ≈ 9.6 TB | ≈ 5.2 TB |

Per-subject exactness was measured (46/46 on real subjects). With 6.25 billion records over 12.5
million subjects, the average subject holds 500 records, a size at which the measured exact scan
took about 1 ms in Postgres. The load test itself (25,000 recalls per second across shards) is
blocked (G30).

## Intake queue (ADR 0004) — measured against 25%

| Need at 25% | Laptop Postgres queue | Verdict |
|---|---|---|
| 25,000 write proposals per second accepted durably | 39,012 enqueues per second (16 clients) | one node could accept them |
| 25,000 per second drained by workers | 9,539 per second at 16 workers, falling to 6,809 at 64 | ✗ on one node; throughput falls as workers are added |

So the measured result confirms the decision: the Postgres queue is for Lite and Standard, and the
Scale profile needs the partitioned log. The log itself at 25% is blocked (G31).

## Authorization store (ADR 0005) — measured, extrapolated to 25%

| Need at 25% | Laptop, 1.1 million tuples, uncached | Verdict |
|---|---|---|
| ≥ 25,000 checks per second (at least one per recall) | 17,575 per second at 16 clients, p95 2.75 ms | p95 well inside 5 ms; throughput needs two such nodes, or a decision cache with a hit rate of 30% or more (TR-GW-04 provides one) |
| p95 ≤ 5 ms uncached (TR-AZ-02) | 2.75 ms | ✓ at this size |

At 25% the tuple count is far larger (relationships for 12.5 million subjects); index lookups stay
logarithmic, but that is extrapolation. The test at size is blocked (G27, G30).

## Connection pooler (ADR 0006) — measured functionally

PgBouncer 1.26.1 in transaction mode works with `max_prepared_statements` and fails without it
(measured). Throughput at 25% (TR-GW-03, ≤ 200 server connections per shard) is blocked (G30).

## Minimum pgvector (ADR 0007)

Self-hosted 0.8.7 verified by running every query of the spike. Managed versions are from provider
documentation (RDS 0.8.0 on PostgreSQL 17, Azure 0.7–0.8); **Cloud SQL is unconfirmed**. Checking
them on live instances is blocked until an instance is available.
