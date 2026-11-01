# MemHouse benchmark: longmemeval-m — m50-v7

Run `20261101-100622-148fbe` · 2026-11-01 10:06 UTC · 63 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=10 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

50 questions, 48 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 72.9 [60.4–85.4] | 18.8 [8.3–31.2] | 72.9 [60.4–85.4] |
| 3 | 91.7 [83.3–97.9] | 70.8 [58.3–83.3] | 78.7 [69.8–86.7] |
| 5 | 93.8 [85.4–100.0] | 79.2 [66.7–89.6] | 80.5 [72.5–87.7] |
| 10 | 95.8 [89.6–100.0] | 89.6 [81.2–97.9] | 82.6 [75.0–89.3] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 45.8 [31.2–60.4] | 14.6 [6.2–25.0] | 45.8 [31.2–60.4] |
| 3 | 75.0 [62.5–87.5] | 37.5 [22.9–52.1] | 52.3 [41.6–63.3] |
| 5 | 87.5 [77.1–95.8] | 62.5 [47.9–75.0] | 60.2 [51.0–69.8] |
| 10 | 91.7 [83.3–97.9] | 77.1 [64.6–89.6] | 64.5 [55.6–73.3] |
| 30 | 93.8 [85.4–100.0] | 81.2 [68.8–91.7] | 65.7 [57.4–74.1] |
| 50 | 93.8 [85.4–100.0] | 83.3 [72.9–93.8] | 65.9 [57.6–74.2] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 7 | 85.7 [57.1–100.0] | 100.0 [100.0–100.0] | – |
| multi-session | 13 | 61.5 [38.5–84.6] | 84.6 [61.5–100.0] | – |
| single-session-assistant | 6 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 3 | 66.7 [0.0–100.0] | 66.7 [0.0–100.0] | – |
| single-session-user | 6 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| temporal-reasoning | 13 | 76.9 [46.2–100.0] | 84.6 [61.5–100.0] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 65.6 ms · p95 96.4 ms · p99 128.6 ms · n=50 |
| — of which SQL hybrid search (Postgres) | p50 46.3 ms · p95 71.1 ms · p99 101.4 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 19.5 ms · p95 28.0 ms |
| Ingest | 122503 rounds, 2046 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-m)** | session | **79.2** | **80.5** | **89.6** | **82.6** |
| **MemHouse (this run, longmemeval-m)** | round | **62.5** | **60.2** | **77.1** | **64.5** |
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

