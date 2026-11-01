# MemHouse benchmark: longmemeval-s — s50-v2-noanalysis

Run `20261101-065618-47ead8` · 2026-11-01 06:56 UTC · 6 s wall time

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
| 1 | 89.1 [80.4–97.8] | 28.3 [15.2–41.3] | 89.1 [80.4–97.8] |
| 3 | 93.5 [84.8–100.0] | 76.1 [63.0–89.1] | 85.7 [77.4–93.2] |
| 5 | 95.7 [89.1–100.0] | 80.4 [67.4–91.3] | 87.4 [79.8–94.1] |
| 10 | 97.8 [93.5–100.0] | 80.4 [67.4–91.3] | 88.0 [80.9–94.2] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 54.3 [39.1–69.6] | 21.7 [10.9–34.8] | 54.3 [39.1–69.6] |
| 3 | 78.3 [67.4–89.1] | 45.7 [32.6–60.9] | 59.0 [48.5–69.7] |
| 5 | 87.0 [76.1–95.7] | 63.0 [50.0–78.3] | 65.5 [55.6–75.6] |
| 10 | 93.5 [84.8–100.0] | 73.9 [60.9–87.0] | 68.9 [59.9–78.2] |
| 30 | 97.8 [93.5–100.0] | 82.6 [71.7–93.5] | 70.8 [62.5–79.1] |
| 50 | 100.0 [100.0–100.0] | 84.8 [73.9–93.5] | 71.3 [63.2–79.3] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 7 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| multi-session | 12 | 91.7 [75.0–100.0] | 91.7 [75.0–100.0] | – |
| single-session-assistant | 5 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-preference | 3 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | – |
| single-session-user | 7 | 85.7 [57.1–100.0] | 85.7 [57.1–100.0] | – |
| temporal-reasoning | 12 | 41.7 [16.7–75.0] | 41.7 [16.7–75.0] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 27.8 ms · p95 34.5 ms · p99 48.8 ms · n=50 |
| — of which SQL hybrid search (Postgres) | p50 7.4 ms · p95 11.5 ms · p99 12.6 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 19.9 ms · p95 25.9 ms |
| Ingest | 12328 rounds, 2495 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **80.4** | **87.4** | **80.4** | **88.0** |
| **MemHouse (this run, longmemeval-s)** | round | **63.0** | **65.5** | **73.9** | **68.9** |
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

