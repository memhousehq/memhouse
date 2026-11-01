# MemHouse benchmark: longmemeval-s — full-v5

Run `20261101-072953-ce4211` · 2026-11-01 07:29 UTC · 4124 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.3, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

500 questions, 470 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 91.1 [88.5–93.6] | 31.1 [27.0–35.3] | 91.1 [88.5–93.6] |
| 3 | 96.6 [94.9–98.1] | 81.7 [78.3–85.1] | 90.9 [88.9–93.0] |
| 5 | 98.9 [97.9–99.8] | 90.4 [87.9–93.0] | 92.7 [90.9–94.3] |
| 10 | 99.8 [99.4–100.0] | 95.7 [93.8–97.4] | 93.8 [92.4–95.2] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 58.3 [53.8–62.8] | 22.6 [18.9–26.4] | 58.3 [53.8–62.8] |
| 3 | 85.1 [81.9–88.3] | 51.5 [47.0–56.2] | 63.9 [60.6–67.0] |
| 5 | 91.9 [89.6–94.3] | 70.4 [66.2–74.5] | 70.1 [67.3–73.0] |
| 10 | 96.6 [94.9–98.3] | 84.5 [81.1–87.7] | 74.2 [71.7–76.6] |
| 30 | 99.1 [98.3–99.8] | 95.3 [93.4–97.0] | 76.3 [74.1–78.5] |
| 50 | 99.6 [98.9–100.0] | 96.6 [94.9–98.1] | 76.5 [74.4–78.7] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 72 | 97.2 [93.1–100.0] | 100.0 [100.0–100.0] | – |
| multi-session | 121 | 85.1 [78.5–90.9] | 94.2 [90.1–97.5] | – |
| single-session-assistant | 56 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 30 | 93.3 [83.3–100.0] | 100.0 [100.0–100.0] | – |
| single-session-user | 64 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| temporal-reasoning | 127 | 81.9 [74.8–88.2] | 89.8 [84.3–94.5] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 64.5 ms · p95 90.8 ms · p99 102.4 ms · n=500 |
| — of which SQL hybrid search (Postgres) | p50 25.6 ms · p95 37.4 ms · p99 44.8 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 38.1 ms · p95 58.6 ms |
| Ingest | 124286 rounds, 30 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **90.4** | **92.7** | **95.7** | **93.8** |
| **MemHouse (this run, longmemeval-s)** | round | **70.4** | **70.1** | **84.5** | **74.2** |
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

