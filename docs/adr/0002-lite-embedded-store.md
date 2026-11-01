<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ADR 0002 — Lite embedded store: SQLite with FTS5 and in-process vector scoring

| Field | Value |
|---|---|
| Status | Accepted (spike, G03); built in G16 |
| Date | 1 November 2026 |
| Requirements | TR-LT-02, TR-LT-03, TR-LT-04, TR-LT-05, PROF-04, PROF-06, PROF-07, TD-12 |
| Evidence | [evidence/storage-spike.md](evidence/storage-spike.md) (`crates/memhouse-bench/examples/spike_storage.rs`) |

## Decision

The Lite profile stores everything in **one SQLite file** (WAL mode), through `rusqlite` with
SQLite compiled in (`bundled`), so there is nothing to install and the logical schema is the same
as on Postgres (TR-CORE-04).

- **Keyword search: FTS5** with the `porter unicode61` tokenizer, BM25 ranking, external content
  on the memory table, and the **subject as an indexed token inside the `MATCH`**
  (`stok:"<subject token>" AND (…)`), so a query never ranks other subjects' rows.
- **Vectors: half-precision blobs** (2 bytes per dimension) scored in process by an **exact
  full scan of the subject** (ADR 0003). A binary-quantised copy is stored for an optional
  prefilter on very large subjects, off by default.
- **Jobs: a table in the same file** (the `IntakeQueue` and `JobRunner` seams of G10, ADR 0004),
  so a write is durable once the transaction commits (TR-LT-05).

## Evidence (LongMemEval_S, 50 subjects, 12,319 rounds, 46 questions)

| Check | Result |
|---|---|
| Vector exactness vs brute-force f32, real subjects (≈ 250 rounds) | half-precision full scan: identical top 10 for 46/46 questions; p50 0.56 ms, p95 0.69 ms in process (Postgres `vector`: 1.52 / 2.14 ms) |
| Subject grown to 10,000 memories (PROF-07) | full half-precision scan p50 6.9 ms, p95 8.6 ms |
| Keyword quality vs Postgres BM25 | gold session in the top 10 for 46/46 with both; 82% top-10 overlap |
| Keyword latency | subject-scoped `MATCH` p50 1.46 ms, p95 4.59 ms (a `MATCH` over all subjects joined to the subject afterwards: 12.1 / 18.9 ms, rejected) |
| File size | ≈ 4.7 KB per round with external-content FTS (text, FTS index, two half-precision vectors and two bit vectors) |
| Binary footprint (PROF-06 ≤ 100 MB without models) | `memhouse` release binary 45.9 MB including ONNX Runtime; SQLite adds about 1.5 MB |

PROF-07 budget at 10,000 memories per subject: vector scan ≈ 9 ms + FTS5 ≈ 5 ms + fusion, inside
the 50 ms p95 (query embedding excluded, as the requirement says).

## Alternatives considered

| Option | Why not |
|---|---|
| Bundled or embedded Postgres | tens of MB more, a server process to supervise, slower start; contradicts "no database to install" |
| DuckDB | strong analytics, but weaker for many small transactional writes and full-text search on rows |
| LanceDB / an embedded vector database | adds a second store for text and metadata; per-subject exact scoring doesn't need an ANN index |
| `sqlite-vec` / `sqlite-vss` extensions | an extension to ship and load per platform; the in-process scan is already fast enough and exact |

## Still to verify (G16)

- PROF-06 resident memory ≤ 256 MB with 100,000 memories (the spike process held every round in
  memory twice plus the model, 281 MB; the real store reads per subject).
- PROF-07 write acknowledgement p95 ≤ 20 ms and gated memories recallable within 2 s.
- Kill-and-restart durability of the job table (TR-LT-05), file encryption (TR-LT-08), and the
  conformance kits of G15.
- Concurrency: one writer at a time in WAL mode; Lite targets one process, and the profile
  advisor (G20) recommends Standard before contention matters.
