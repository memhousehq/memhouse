# MemHouse benchmark: longmemeval-s — s50-v3-noanalysis

Run `20261101-072043-9694b5` · 2026-11-01 07:20 UTC · 91 s wall time

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

50 questions, 46 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 89.1 [78.3–97.8] | 28.3 [15.2–41.3] | 89.1 [78.3–97.8] |
| 3 | 100.0 [100.0–100.0] | 78.3 [67.4–89.1] | 90.1 [84.7–94.9] |
| 5 | 100.0 [100.0–100.0] | 82.6 [71.7–93.5] | 90.3 [85.3–95.1] |
| 10 | 100.0 [100.0–100.0] | 82.6 [71.7–93.5] | 90.6 [85.5–95.2] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 58.7 [43.5–73.9] | 19.6 [8.7–32.6] | 58.7 [43.5–73.9] |
| 3 | 84.8 [73.9–93.5] | 52.2 [37.0–67.4] | 63.4 [53.0–73.4] |
| 5 | 87.0 [76.1–95.7] | 67.4 [54.3–80.4] | 67.8 [57.7–77.7] |
| 10 | 93.5 [84.8–100.0] | 76.1 [63.0–89.1] | 71.2 [62.1–80.0] |
| 30 | 100.0 [100.0–100.0] | 84.8 [73.9–95.7] | 73.1 [65.3–81.0] |
| 50 | 100.0 [100.0–100.0] | 84.8 [73.9–95.7] | 73.1 [65.3–81.0] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 7 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| multi-session | 12 | 91.7 [75.0–100.0] | 91.7 [75.0–100.0] | – |
| single-session-assistant | 5 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 3 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-user | 7 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| temporal-reasoning | 12 | 41.7 [16.7–66.7] | 41.7 [16.7–66.7] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 41.6 ms · p95 56.8 ms · p99 88.4 ms · n=50 |
| — of which SQL hybrid search (Postgres) | p50 10.1 ms · p95 19.4 ms · p99 40.7 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 31.7 ms · p95 42.3 ms |
| Ingest | 12328 rounds, 142 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **82.6** | **90.3** | **82.6** | **90.6** |
| **MemHouse (this run, longmemeval-s)** | round | **67.4** | **67.8** | **76.1** | **71.2** |
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

