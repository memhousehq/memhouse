<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ADR 0003 — Vector storage format: half precision, exact scan; binary prefilter only as an option

| Field | Value |
|---|---|
| Status | **Accepted** by the user, 1 November 2026 (spike G03) ; Lite from G16, Postgres migration in G30 |
| Date | 1 November 2026 |
| Requirements | SCALE-03, SCALE-06, TR-DB-02, TR-DB-07, TR-LT-03, TR-RQ-02 |
| Evidence | [evidence/spike-acceptance.md](evidence/spike-acceptance.md) (section 6.10 coverage), [evidence/storage-spike.md](evidence/storage-spike.md) |

## Decision

1. **Half precision is the scoring format** in every profile: `halfvec(D)` on Postgres, f16 blobs
   in Lite. It halves storage and I/O (776 vs 1,540 bytes per 384-dimension vector) with no loss
   of top-10 exactness on real data.
2. **Recall scores every vector of the subject exactly** (no approximate index, SCALE-03). On
   Postgres this stays one statement per probe; in Lite it is an in-process loop.
3. **A binary-quantised copy** (`bit(D)`, 48 bytes) is stored for a **prefilter that is off by
   default**. It may be enabled per tenant for subjects above about 20,000 memories, with
   oversampling, only if the exactness check below still passes on that tenant's data.
4. **"Exact" means the same top K as brute force over the stored half-precision vectors.** The
   `exact_topk` governance check measures exactly that. Differences against f32 only appear at
   near-ties (score differences below f16 resolution), which carry no retrieval meaning.
5. Postgres keeps today's `vector` (f32) column until G30, where `halfvec` and `bit` columns are
   added by an expand-then-contract migration and the switch is gated by the benchmark guard.

## Evidence

Real LongMemEval_S subjects (≈ 250 rounds each), top 10 vs brute-force f32, 46 questions:

| Method | identical top 10 | p50 / p95 |
|---|---|---|
| Postgres `vector` f32, exact scan | 46/46 | 1.52 / 2.14 ms |
| Postgres `halfvec`, exact scan | 46/46 | 0.84 / 1.04 ms |
| Postgres `bit` top 100 → `halfvec` rescoring | 46/46 | 0.88 / 1.59 ms |
| In-process f16, full scan | 46/46 | 0.56 / 0.69 ms |
| In-process bit top 100 → f16 rescoring | 46/46 | 0.22 / 0.30 ms |

One subject grown to 10,000 memories (about 40 near-identical copies of each round, a deliberately
hard case for ties), against f32 brute force:

| Method | identical top 10 | p50 / p95 |
|---|---|---|
| f16 full scan | 41/46 (mean top-10 overlap 0.998) | 6.9 / 8.6 ms |
| bit top 1,000 → f16 | 37/46 | 0.9 / 1.2 ms |
| bit top 2,000 → f16 | 41/46 | 1.7 / 2.7 ms |
| bit top 4,000 → f16 | 41/46 | 3.3 / 4.5 ms |

The binary prefilter alone loses exactness as subjects grow, which is why it is not the default;
the full half-precision scan stays well inside the latency budget at 10,000 memories.

## Alternatives considered

| Option | Why not |
|---|---|
| Keep f32 everywhere | twice the storage and I/O for no measured quality gain; TR-DB-07 sizes the hot tier on smaller vectors |
| Binary prefilter by default (technical document 4.5 step 3) | measurably not exact at 10,000 memories per subject (37/46 at depth 1,000) |
| ANN index (HNSW / IVFFlat) per subject | approximate by design; per-subject partitions are small enough to scan |
| int8 scalar quantisation | no native Postgres type; half precision already meets the budgets |

## Still to verify

- G30: the Postgres `halfvec` migration on a 10-million-record reference database, with T3 and T4
  of the guard before the `vector` column is dropped.
- G30: hot-tier sizing (TR-DB-07) with half-precision and bit columns.
