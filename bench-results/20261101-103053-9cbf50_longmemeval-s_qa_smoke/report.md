# MemHouse benchmark: longmemeval-s — qa-smoke

Run `20261101-103053-9cbf50` · 2026-11-01 10:30 UTC · 5 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=100 offset=0 types=all |
| Answer model | `openai:openai/gpt-4o-mini` (top 10 memories) |
| Judge model | `openai:openai/gpt-4o-mini` |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

5 questions, 5 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 100.0 [100.0–100.0] | 20.0 [0.0–60.0] | 100.0 [100.0–100.0] |
| 3 | 100.0 [100.0–100.0] | 80.0 [40.0–100.0] | 92.3 [76.8–100.0] |
| 5 | 100.0 [100.0–100.0] | 80.0 [40.0–100.0] | 92.3 [76.8–100.0] |
| 10 | 100.0 [100.0–100.0] | 80.0 [40.0–100.0] | 92.3 [76.8–100.0] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 60.0 [20.0–100.0] | 20.0 [0.0–60.0] | 60.0 [20.0–100.0] |
| 3 | 80.0 [40.0–100.0] | 40.0 [0.0–80.0] | 50.7 [24.5–78.4] |
| 5 | 100.0 [100.0–100.0] | 80.0 [40.0–100.0] | 64.0 [41.8–86.3] |
| 10 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 68.4 [50.5–86.3] |
| 30 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 68.4 [50.5–86.3] |
| 50 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 68.4 [50.5–86.3] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 1 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |
| multi-session | 2 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |
| single-session-user | 1 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |
| temporal-reasoning | 1 | 0.0 [0.0–0.0] | 0.0 [0.0–0.0] | 100.0 [100.0–100.0] |

## Answer accuracy (LLM judge)

**100.0 [100.0–100.0]** over 5 questions, judged by `openai:openai/gpt-4o-mini` with the benchmark's judging protocol.

## LLM usage and cost

| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| answer | `openai:openai/gpt-4o-mini` | 5 | 15680 | 188 | 0.0025 | reported by provider | 0 | 930 / 1910 / 1910 ms |
| judge | `openai:openai/gpt-4o-mini` | 5 | 796 | 5 | 0.0001 | reported by provider | 0 | 652 / 1340 / 1340 ms |
| **total** | | 10 | 16476 | 193 | **0.0026** | | | |

Per question: 3136 prompt + 38 completion tokens to the answer model, $0.00052 in all.

**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):

| | p50 | p95 | p99 |
|---|---|---|---|
| Memory recall only (local, no external call) | 32 ms | 38 ms | 38 ms |
| Answer-model call alone (network + provider) | 930 ms | 1910 ms | 1910 ms |
| Recall + answer (what an agent waits for) | 959 ms | 1942 ms | 1942 ms |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 31.7 ms · p95 37.6 ms · p99 37.6 ms · n=5 |
| — of which SQL hybrid search (Postgres) | p50 9.4 ms · p95 11.6 ms · p99 11.6 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 21.4 ms · p95 26.6 ms |
| Ingest | 1232 rounds, 2643 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **80.0** | **92.3** | **80.0** | **92.3** |
| **MemHouse (this run, longmemeval-s)** | round | **80.0** | **64.0** | **100.0** | **68.4** |
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
| **MemHouse (this run)** | **100.0** | openai:openai/gpt-4o-mini | this tool |
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

