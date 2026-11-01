<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# ADR 0002 — Lite embedded store: SQLite with FTS5 and in-process vector scoring

| Field | Value |
|---|---|
| Status | **Accepted** by the user, 1 November 2026 (spike G03) ; built in G16 |
| Date | 1 November 2026 |
| Requirements | TR-LT-02, TR-LT-03, TR-LT-04, TR-LT-05, PROF-04, PROF-06, PROF-07, TD-12 |
| Evidence | [evidence/spike-acceptance.md](evidence/spike-acceptance.md) (section 6.10 coverage), [evidence/storage-spike.md](evidence/storage-spike.md) (`crates/memhouse-bench/examples/spike_storage.rs`) |

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

## Lite profile targets (measured, [evidence/lite-profile-spike.md](evidence/lite-profile-spike.md))

100,000 memories in one file (10,000 per subject), fresh process, all networking denied:

| Target | Result |
|---|---|
| PROF-07 recall p95 ≤ 50 ms | 25.9 ms with local query embedding (1 model session); 13.8 ms store only |
| PROF-07 write acknowledgement p95 ≤ 20 ms | 3.34 ms, durable against power loss (`synchronous = FULL`, `fullfsync`) |
| PROF-07 written memory recallable ≤ 2 s | 23 ms p95 |
| PROF-06 resident memory ≤ 256 MB | **store: 16 MB peak** ✓. The bundled local model is budgeted separately (decision below): 394 MB (1 session), 610 MB (4 sessions) |
| PROF-04 one process, no external service | yes, with the network denied |

**PROF-06 decision (the user, 1 November 2026): option (a).** The 256 MB limit applies to MemHouse
and its store; the optional local embedding model has its own budget, as PROF-06's binary-size
clause already excludes models. The store measured 16 MB. The local model measured 157 MB per
session at load and 379–394 MB at peak with one session, whatever the thread count, so Lite
defaults to one session. For machines where that is too much, `[embedding] provider = "openai"`
sends embedding to any OpenAI-compatible API (OpenAI, OpenRouter, Ollama on another host, vLLM)
and loads no model. It has a timeout, retries with backoff after rate limits and server errors,
an optional `dimensions` request for models that can shorten vectors, and the database refuses a
different embedder than the one that wrote it ([configuration](../configuration.md#embedding)).
The options not taken were (b), working on the runtime's memory to fit under 256 MB, and (c), a
smaller default model.

## Still to verify (G16)

- PROF-06 with the final Lite binary: the store within 256 MB, the local model reported separately, and a run with a remote embedding API.
- PROF-07 again through the real engine path (gate, audit, fusion), not the spike's direct SQL.
- Kill-and-restart durability of the job table (TR-LT-05), file encryption (TR-LT-08), and the
  conformance kits of G15.
- Concurrency: one writer at a time in WAL mode; Lite targets one process, and the profile
  advisor (G20) recommends Standard before contention matters.
