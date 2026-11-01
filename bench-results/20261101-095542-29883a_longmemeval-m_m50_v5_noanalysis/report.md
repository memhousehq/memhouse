# MemHouse benchmark: longmemeval-m — m50-v5-noanalysis

Run `20261101-095542-29883a` · 2026-11-01 09:55 UTC · 64 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | off |
| Selection | limit=all stride=10 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

50 questions, 48 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 72.9 [60.4–85.4] | 18.8 [8.3–31.2] | 72.9 [60.4–85.4] |
| 3 | 93.8 [85.4–100.0] | 72.9 [60.4–85.4] | 79.8 [71.9–87.1] |
| 5 | 93.8 [85.4–100.0] | 81.2 [70.8–91.7] | 81.2 [73.6–88.1] |
| 10 | 95.8 [89.6–100.0] | 89.6 [81.2–97.9] | 82.9 [75.8–89.2] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 45.8 [33.3–60.4] | 14.6 [4.2–25.0] | 45.8 [33.3–60.4] |
| 3 | 75.0 [62.5–85.4] | 37.5 [22.9–52.1] | 52.3 [41.9–62.8] |
| 5 | 89.6 [81.2–97.9] | 64.6 [50.0–77.1] | 61.0 [52.1–69.9] |
| 10 | 91.7 [83.3–97.9] | 77.1 [64.6–87.5] | 64.5 [55.9–73.0] |
| 30 | 93.8 [85.4–100.0] | 81.2 [70.8–91.7] | 65.8 [57.6–73.9] |
| 50 | 93.8 [85.4–100.0] | 83.3 [72.9–93.8] | 66.0 [58.0–74.0] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 7 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| multi-session | 13 | 61.5 [38.5–92.3] | 84.6 [61.5–100.0] | – |
| single-session-assistant | 6 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 3 | 66.7 [0.0–100.0] | 66.7 [0.0–100.0] | – |
| single-session-user | 6 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| temporal-reasoning | 13 | 76.9 [53.8–100.0] | 84.6 [61.5–100.0] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 68.5 ms · p95 100.0 ms · p99 124.1 ms · n=50 |
| — of which SQL hybrid search (Postgres) | p50 46.1 ms · p95 72.6 ms · p99 98.0 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 20.4 ms · p95 28.6 ms |
| Ingest | 122503 rounds, 2004 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-m)** | session | **81.2** | **81.2** | **89.6** | **82.9** |
| **MemHouse (this run, longmemeval-m)** | round | **64.6** | **61.0** | **77.1** | **64.5** |
| BM25 | session | 63.4 | 51.6 | 71.0 | 54.0 |
| Contriever | session | 72.3 | 63.4 | 82.3 | 66.3 |
| Stella V5 1.5B | session | 72.0 | 59.4 | 79.4 | 61.5 |
| Contriever + fact keys (LLM-extracted) | session | 76.2 | 63.2 | 86.2 | 65.8 |
| Stella V5 1.5B + fact keys (LLM-extracted) | session | 73.2 | 52.0 | 86.2 | 55.2 |
| BM25 | round | 47.2 | 35.2 | 53.8 | 37.2 |
| Contriever | round | 58.9 | 45.4 | 74.7 | 49.5 |
| Stella V5 1.5B | round | 66.0 | 49.8 | 78.4 | 52.8 |
| Stella V5 1.5B + fact keys (LLM-extracted) | round | 64.4 | 49.8 | 78.4 | 53.6 |

Published search latencies (Mem0 paper, LoCoMo, hosted services incl. network): Mem0 p50 148 / p95 200 ms; Mem0 graph p50 476 / p95 657 ms; Zep (measured by Mem0) p50 513 / p95 778 ms; A-Mem p50 668 / p95 1485 ms; LangMem p50 17990 / p95 59820 ms.

