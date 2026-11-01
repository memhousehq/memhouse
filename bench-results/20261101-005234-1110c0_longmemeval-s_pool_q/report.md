# MemHouse benchmark: longmemeval-s — pool-q

Run `20261101-005234-1110c0` · 2026-11-01 00:52 UTC · 267 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Selection | limit=all stride=25 offset=1 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

20 questions, 19 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 84.2 [68.4–100.0] | 31.6 [10.5–52.6] | 84.2 [68.4–100.0] |
| 3 | 89.5 [73.7–100.0] | 73.7 [52.6–89.5] | 86.0 [70.2–98.1] |
| 5 | 89.5 [73.7–100.0] | 78.9 [57.9–94.7] | 86.0 [70.2–98.1] |
| 10 | 89.5 [73.7–100.0] | 84.2 [63.2–100.0] | 86.0 [70.2–98.1] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 31.6 [10.5–52.6] | 21.1 [5.3–42.1] | 31.6 [10.5–52.6] |
| 3 | 68.4 [47.4–89.5] | 42.1 [21.1–63.2] | 46.1 [28.3–64.3] |
| 5 | 78.9 [57.9–94.7] | 57.9 [36.8–78.9] | 52.3 [35.5–68.7] |
| 10 | 84.2 [63.2–100.0] | 68.4 [47.4–89.5] | 55.2 [38.7–71.1] |
| 30 | 84.2 [63.2–100.0] | 84.2 [63.2–100.0] | 58.2 [42.7–73.1] |
| 50 | 84.2 [63.2–100.0] | 84.2 [63.2–100.0] | 58.2 [42.7–73.1] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 3 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| multi-session | 5 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-assistant | 2 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 1 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-user | 3 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| temporal-reasoning | 5 | 20.0 [0.0–60.0] | 40.0 [0.0–80.0] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 52.2 ms · p95 68.5 ms · p99 73.5 ms · n=20 |
| — of which SQL hybrid search (Postgres) | p50 11.0 ms · p95 19.1 ms · p99 33.2 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 36.5 ms · p95 53.0 ms |
| Ingest | 4955 rounds, 19 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **78.9** | **86.0** | **84.2** | **86.0** |
| **MemHouse (this run, longmemeval-s)** | round | **57.9** | **52.3** | **68.4** | **55.2** |
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

