# MemHouse benchmark: longmemeval-m — full-m-v7

Run `20261101-105128-f67362` · 2026-11-01 10:51 UTC · 8354 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

500 questions, 470 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 71.7 [67.7–76.0] | 23.8 [20.2–27.7] | 71.7 [67.7–76.0] |
| 3 | 88.5 [85.5–91.3] | 62.8 [58.3–67.2] | 73.7 [70.5–76.9] |
| 5 | 91.9 [89.4–94.3] | 74.5 [70.4–78.3] | 77.4 [74.5–80.2] |
| 10 | 94.3 [92.1–96.2] | 84.7 [81.3–87.9] | 80.2 [77.5–82.8] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 47.7 [43.2–52.3] | 18.7 [15.3–22.3] | 47.7 [43.2–52.3] |
| 3 | 72.1 [67.9–76.2] | 39.6 [35.1–44.0] | 52.1 [48.7–55.6] |
| 5 | 82.6 [78.9–85.7] | 55.1 [50.6–59.4] | 58.2 [55.0–61.4] |
| 10 | 88.5 [85.5–91.1] | 69.1 [64.7–73.2] | 62.4 [59.4–65.4] |
| 30 | 94.5 [92.3–96.4] | 83.4 [79.8–86.6] | 65.7 [63.1–68.4] |
| 50 | 95.5 [93.6–97.2] | 87.7 [84.5–90.6] | 66.4 [63.8–69.0] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 72 | 87.5 [79.2–94.4] | 98.6 [95.8–100.0] | – |
| multi-session | 121 | 58.7 [50.4–66.9] | 76.0 [68.6–83.5] | – |
| single-session-assistant | 56 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 30 | 56.7 [40.0–73.3] | 66.7 [50.0–83.3] | – |
| single-session-user | 64 | 95.3 [89.1–100.0] | 98.4 [93.8–100.0] | – |
| temporal-reasoning | 127 | 64.6 [55.9–73.2] | 75.6 [67.7–82.7] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 234.0 ms · p95 342.4 ms · p99 394.2 ms · n=500 |
| — of which SQL hybrid search (Postgres) | p50 196.3 ms · p95 297.9 ms · p99 357.6 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 38.2 ms · p95 62.6 ms |
| Ingest | 1227278 rounds, 148 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-m)** | session | **74.5** | **77.4** | **84.7** | **80.2** |
| **MemHouse (this run, longmemeval-m)** | round | **55.1** | **58.2** | **69.1** | **62.4** |
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

