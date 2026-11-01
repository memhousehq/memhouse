# MemHouse benchmark: longmemeval-s — s50-q-dense

Run `20261101-010831-31cc02` · 2026-11-01 01:08 UTC · 674 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | dense (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Selection | limit=all stride=10 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

50 questions, 46 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 87.0 [76.1–95.7] | 26.1 [13.0–39.1] | 87.0 [76.1–95.7] |
| 3 | 93.5 [84.8–100.0] | 69.6 [56.5–82.6] | 83.9 [75.3–91.6] |
| 5 | 95.7 [89.1–100.0] | 80.4 [69.6–91.3] | 85.6 [77.8–92.7] |
| 10 | 95.7 [89.1–100.0] | 82.6 [69.6–93.5] | 85.9 [78.2–93.1] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 50.0 [34.8–65.2] | 15.2 [6.5–26.1] | 50.0 [34.8–65.2] |
| 3 | 71.7 [58.7–84.8] | 41.3 [28.3–56.5] | 52.7 [41.6–64.0] |
| 5 | 80.4 [69.6–91.3] | 45.7 [30.4–60.9] | 56.1 [45.6–66.9] |
| 10 | 89.1 [80.4–97.8] | 65.2 [52.2–78.3] | 62.0 [52.5–71.7] |
| 30 | 93.5 [87.0–100.0] | 78.3 [65.2–89.1] | 64.3 [55.0–73.3] |
| 50 | 95.7 [89.1–100.0] | 82.6 [69.6–93.5] | 64.9 [56.1–73.6] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 7 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| multi-session | 12 | 91.7 [75.0–100.0] | 91.7 [75.0–100.0] | – |
| single-session-assistant | 5 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 3 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-user | 7 | 85.7 [57.1–100.0] | 85.7 [57.1–100.0] | – |
| temporal-reasoning | 12 | 41.7 [16.7–66.7] | 50.0 [25.0–83.3] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 56.9 ms · p95 82.5 ms · p99 105.2 ms · n=50 |
| — of which SQL hybrid search (Postgres) | p50 12.9 ms · p95 22.0 ms · p99 22.9 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 42.5 ms · p95 63.8 ms |
| Ingest | 12328 rounds, 19 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **80.4** | **85.6** | **82.6** | **85.9** |
| **MemHouse (this run, longmemeval-s)** | round | **45.7** | **56.1** | **65.2** | **62.0** |
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

