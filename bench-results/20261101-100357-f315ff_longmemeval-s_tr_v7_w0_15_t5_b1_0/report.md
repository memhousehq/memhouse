# MemHouse benchmark: longmemeval-s — tr-v7-w0.15-t5-b1.0

Run `20261101-100357-f315ff` · 2026-11-01 10:03 UTC · 18 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 5 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=temporal-reasoning |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

133 questions, 127 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 89.0 [83.5–94.5] | 10.2 [5.5–15.7] | 89.0 [83.5–94.5] |
| 3 | 93.7 [89.0–97.6] | 73.2 [65.4–81.1] | 86.2 [81.1–90.9] |
| 5 | 97.6 [94.5–100.0] | 83.5 [76.4–89.8] | 89.0 [84.6–92.9] |
| 10 | 99.2 [97.6–100.0] | 91.3 [85.8–96.1] | 90.7 [87.0–93.9] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 52.8 [44.9–61.4] | 8.7 [3.9–14.2] | 52.8 [44.9–61.4] |
| 3 | 80.3 [73.2–87.4] | 42.5 [33.9–50.4] | 57.4 [51.0–63.6] |
| 5 | 89.8 [84.3–94.5] | 66.1 [57.5–74.0] | 65.2 [59.5–70.6] |
| 10 | 94.5 [89.8–98.4] | 83.5 [77.2–89.8] | 69.8 [64.7–74.7] |
| 30 | 97.6 [94.5–100.0] | 94.5 [89.8–98.4] | 72.0 [67.5–76.2] |
| 50 | 98.4 [96.1–100.0] | 96.9 [93.7–99.2] | 72.4 [68.0–76.5] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| temporal-reasoning | 127 | 83.5 [76.4–89.8] | 91.3 [85.8–96.1] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 28.4 ms · p95 39.5 ms · p99 60.5 ms · n=133 |
| — of which SQL hybrid search (Postgres) | p50 7.8 ms · p95 12.6 ms · p99 15.9 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 19.9 ms · p95 27.7 ms |
| Ingest | 33017 rounds, 2077 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **83.5** | **89.0** | **91.3** | **90.7** |
| **MemHouse (this run, longmemeval-s)** | round | **66.1** | **65.2** | **83.5** | **69.8** |
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

