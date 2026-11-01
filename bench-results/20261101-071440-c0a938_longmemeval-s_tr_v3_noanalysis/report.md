# MemHouse benchmark: longmemeval-s — tr-v3-noanalysis

Run `20261101-071440-c0a938` · 2026-11-01 07:14 UTC · 345 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | off |
| Selection | limit=all stride=1 offset=0 types=temporal-reasoning |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

133 questions, 127 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 71.7 [63.8–78.7] | 9.4 [4.7–15.0] | 71.7 [63.8–78.7] |
| 3 | 79.5 [72.4–86.6] | 48.0 [39.4–56.7] | 66.4 [59.9–73.1] |
| 5 | 81.9 [75.6–88.2] | 53.5 [44.9–62.2] | 68.0 [61.6–74.4] |
| 10 | 84.3 [78.0–90.6] | 59.8 [51.2–68.5] | 69.3 [63.0–75.4] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 40.9 [33.1–49.6] | 7.1 [3.1–11.8] | 40.9 [33.1–49.6] |
| 3 | 60.6 [52.0–68.5] | 29.9 [22.0–38.6] | 42.7 [36.1–49.7] |
| 5 | 72.4 [64.6–79.5] | 41.7 [33.1–50.4] | 48.2 [42.1–54.9] |
| 10 | 76.4 [69.3–83.5] | 51.2 [42.5–59.8] | 51.2 [45.0–57.5] |
| 30 | 82.7 [75.6–89.0] | 63.8 [55.1–71.7] | 53.9 [48.3–60.0] |
| 50 | 83.5 [77.2–89.8] | 65.4 [57.5–73.2] | 54.1 [48.6–60.3] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| temporal-reasoning | 127 | 53.5 [44.9–62.2] | 59.8 [51.2–68.5] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 45.6 ms · p95 58.0 ms · p99 69.5 ms · n=133 |
| — of which SQL hybrid search (Postgres) | p50 10.3 ms · p95 22.6 ms · p99 30.9 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 33.5 ms · p95 45.3 ms |
| Ingest | 33017 rounds, 97 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **53.5** | **68.0** | **59.8** | **69.3** |
| **MemHouse (this run, longmemeval-s)** | round | **41.7** | **48.2** | **51.2** | **51.2** |
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

