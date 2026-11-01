# MemHouse benchmark: longmemeval-s — s50-q-keyword

Run `20261101-011945-4312ce` · 2026-11-01 01:19 UTC · 673 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | keyword (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Selection | limit=all stride=10 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

50 questions, 46 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 65.2 [50.0–78.3] | 15.2 [6.5–26.1] | 65.2 [50.0–78.3] |
| 3 | 80.4 [67.4–91.3] | 52.2 [37.0–67.4] | 63.7 [52.8–74.0] |
| 5 | 95.7 [89.1–100.0] | 63.0 [47.8–76.1] | 70.1 [60.9–78.3] |
| 10 | 100.0 [100.0–100.0] | 82.6 [71.7–93.5] | 75.3 [68.2–82.2] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 41.3 [26.1–56.5] | 15.2 [6.5–26.1] | 41.3 [26.1–56.5] |
| 3 | 63.0 [50.0–76.1] | 28.3 [15.2–41.3] | 40.8 [30.7–51.8] |
| 5 | 76.1 [65.2–87.0] | 39.1 [26.1–54.3] | 46.3 [36.5–57.0] |
| 10 | 87.0 [76.1–95.7] | 63.0 [50.0–76.1] | 53.4 [44.0–63.4] |
| 30 | 100.0 [100.0–100.0] | 80.4 [67.4–91.3] | 58.2 [50.3–66.6] |
| 50 | 100.0 [100.0–100.0] | 80.4 [67.4–91.3] | 58.4 [50.3–66.7] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 7 | 85.7 [57.1–100.0] | 100.0 [100.0–100.0] | – |
| multi-session | 12 | 50.0 [25.0–75.0] | 91.7 [75.0–100.0] | – |
| single-session-assistant | 5 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 3 | 66.7 [0.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-user | 7 | 85.7 [57.1–100.0] | 100.0 [100.0–100.0] | – |
| temporal-reasoning | 12 | 33.3 [8.3–58.3] | 41.7 [16.7–66.7] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 8.7 ms · p95 19.4 ms · p99 28.6 ms · n=50 |
| — of which SQL hybrid search (Postgres) | p50 8.7 ms · p95 19.4 ms · p99 28.6 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 0.0 ms · p95 0.0 ms |
| Ingest | 12328 rounds, 19 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **63.0** | **70.1** | **82.6** | **75.3** |
| **MemHouse (this run, longmemeval-s)** | round | **39.1** | **46.3** | **63.0** | **53.4** |
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

