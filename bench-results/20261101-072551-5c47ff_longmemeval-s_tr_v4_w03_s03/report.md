# MemHouse benchmark: longmemeval-s — tr-v4-w03-s03

Run `20261101-072551-5c47ff` · 2026-11-01 07:25 UTC · 19 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.3, sub-query w=0.3 |
| Selection | limit=all stride=1 offset=0 types=temporal-reasoning |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

133 questions, 127 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 87.4 [81.9–92.9] | 10.2 [5.5–15.7] | 87.4 [81.9–92.9] |
| 3 | 92.9 [88.2–96.9] | 72.4 [64.6–80.3] | 84.6 [79.4–89.4] |
| 5 | 98.4 [96.1–100.0] | 81.1 [74.0–87.4] | 87.4 [83.1–91.3] |
| 10 | 99.2 [97.6–100.0] | 90.6 [85.0–95.3] | 89.2 [85.4–92.4] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 48.0 [39.4–56.7] | 7.9 [3.1–13.4] | 48.0 [39.4–56.7] |
| 3 | 77.2 [70.1–84.3] | 35.4 [26.8–44.1] | 52.4 [46.4–58.4] |
| 5 | 87.4 [81.9–92.9] | 56.7 [48.0–65.4] | 60.0 [54.6–65.5] |
| 10 | 94.5 [90.6–97.6] | 76.4 [69.3–83.5] | 65.8 [60.9–70.6] |
| 30 | 97.6 [94.5–100.0] | 93.7 [89.0–97.6] | 68.9 [64.6–73.1] |
| 50 | 98.4 [96.1–100.0] | 96.9 [93.7–99.2] | 69.4 [65.2–73.5] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| temporal-reasoning | 127 | 81.1 [74.0–87.4] | 90.6 [85.0–95.3] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 46.3 ms · p95 78.7 ms · p99 98.8 ms · n=133 |
| — of which SQL hybrid search (Postgres) | p50 9.3 ms · p95 17.0 ms · p99 21.2 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 36.3 ms · p95 65.7 ms |
| Ingest | 33017 rounds, 2038 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **81.1** | **87.4** | **90.6** | **89.2** |
| **MemHouse (this run, longmemeval-s)** | round | **56.7** | **60.0** | **76.4** | **65.8** |
| BM25 | session | 63.4 | 51.6 | 71.0 | 54.0 |
| Contriever | session | 72.3 | 63.4 | 82.3 | 66.3 |
| Stella V5 1.5B | session | 72.0 | 59.4 | 79.4 | 61.5 |
| Contriever + fact keys (LLM-extracted) | session | 76.2 | 63.2 | 86.2 | 65.8 |
| Stella V5 1.5B + fact keys (LLM-extracted) | session | 73.2 | 52.0 | 86.2 | 55.2 |
| BM25 | round | 47.2 | 35.2 | 53.8 | 37.2 |
| Contriever | round | 58.9 | 45.4 | 74.7 | 49.5 |
| Stella V5 1.5B | round | 66.0 | 49.8 | 78.4 | 52.8 |
| Stella V5 1.5B + fact keys (LLM-extracted) | round | 64.4 | 49.8 | 78.4 | 53.6 |

## Reference: published answer accuracy on longmemeval-s

Mostly vendor-reported, with different answer and judge models; use for orientation only.

| System | Accuracy % | Models | Reported by |
|---|---|---|---|
| Full context (no memory system) | 60.2 | GPT-4o | [Zep paper](https://arxiv.org/abs/2501.13956) |
| Zep | 71.2 | GPT-4o | [vendor](https://arxiv.org/abs/2501.13956) |
| Bedrock AgentCore memory | 77.0 | GPT-4o | [Redis re-run](https://redis.io/resources/agent-memory-benchmark-report/) |
| MemOS | 77.8 | GPT-4o-mini | [vendor](https://huggingface.co/datasets/MemTensor/MemOS_eval_result) |
| Emergence (fast) | 81.3 | GPT-4o | [Redis re-run](https://redis.io/resources/agent-memory-benchmark-report/) |
| Supermemory | 81.6 | GPT-4o | [vendor](https://supermemory.ai/research) |
| Hindsight | 83.6 | GPT-OSS-20B answer, GPT-OSS-120B judge | [vendor](https://arxiv.org/abs/2512.12818) |
| Mastra Observational Memory | 84.2 | GPT-4o | [vendor; Redis reproduced 84.2](https://mastra.ai/research/observational-memory) |
| Mem0 (2026 algorithm) | 94.4 | not fully disclosed | [vendor](https://github.com/mem0ai/memory-benchmarks) |

Published search latencies (Mem0 paper, LoCoMo, hosted services incl. network): Mem0 p50 148 / p95 200 ms; Mem0 graph p50 476 / p95 657 ms; Zep (measured by Mem0) p50 513 / p95 778 ms; A-Mem p50 668 / p95 1485 ms; LangMem p50 17990 / p95 59820 ms.

