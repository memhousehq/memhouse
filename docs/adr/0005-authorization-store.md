<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ADR 0005 — Authorization store: relationship tuples in the profile's own store, an in-process evaluator

| Field | Value |
|---|---|
| Status | **Accepted** by the user, 1 November 2026 (spike G03) ; seam in G06, ReBAC in G27 |
| Date | 1 November 2026 |
| Requirements | TD-07, ACC-01 to ACC-04, ACC-09, TR-AZ-01 to TR-AZ-05, TR-GW-04, GOV-14 |
| Evidence | [evidence/spike-acceptance.md](evidence/spike-acceptance.md) (section 6.10 coverage), [evidence/postgres-spike.md](evidence/postgres-spike.md) (`scripts/spike/authz_*.sql`) |

## Decision

- Relationship tuples (principal, relation, object, valid from/to, purpose, consent reference)
  live in a **table of the profile's own store**: Postgres for Standard and Scale, the SQLite file
  for Lite. There is no separate authorization database to run.
- Checks are made by a **Rust evaluator inside MemHouse** behind the `Authorizer` trait (G06). It
  returns the decision *and* the chain of tuples that granted or denied it (TR-AZ-04).
- An **in-process decision cache** keyed by principal, object, relation and purpose, invalidated by
  a change stream (Postgres `LISTEN/NOTIFY`, or logical replication at Scale), with a 5-second
  maximum lifetime (TR-GW-04), and a consistency token for callers that need fresher answers
  (TR-AZ-03).
- At Scale the same evaluator can run as the `authz-service` of the packaging plan, next to the
  shards, if a shared cache across gateways is needed.

## Evidence (1,111,000 tuples, uncached, mostly denials)

| Clients | p50 | p95 | p99 |
|---|---|---|---|
| 1 | 0.28 ms | 0.32 ms | 0.40 ms |
| 16 | 0.55 ms | 2.75 ms | 5.86 ms |

TR-AZ-02 (p95 ≤ 5 ms uncached) is met at 16 concurrent clients on a laptop without any cache.

## Alternatives considered

| Option | Why not (now) |
|---|---|
| SpiceDB | mature Zanzibar implementation (Apache-2.0), but a separate service and its own datastore; can't run inside the Lite file; adds an operational dependency for every Standard customer |
| OpenFGA | same trade-off as SpiceDB (Apache-2.0, CNCF); kept as the fallback if G27's register scenarios need deeper or more dynamic rewrites than SQL handles well |
| Access lists on memory records | rejected by TD-07: churn and slow revocation |

Both services remain reachable later through the `Authorizer` seam, without touching the engine.

## Still to verify (G27)

- Nested groups (teams within teams, organisations) with recursive resolution, and the D-01 to
  D-07 register rules, within p95 ≤ 5 ms uncached.
- Change stream within 1 second of a committed change (TR-AZ-02) and revocation within 5 seconds
  p99 end to end (ACC-03).
- Differential test against a brute-force reference on 10 million generated cases.
