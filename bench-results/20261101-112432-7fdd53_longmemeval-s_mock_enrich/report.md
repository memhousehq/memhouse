# MemHouse benchmark: longmemeval-s — mock-enrich

Run `20261101-112432-7fdd53` · 2026-11-01 11:24 UTC · 7 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=2 stride=1 offset=0 types=all |
| Answer model | `openai:gpt-4o-mini` (top 10 memories) |
| Judge model | `openai:gpt-4o` |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

2 questions, 2 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |
| 3 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |
| 5 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |
| 10 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |
| 3 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 80.7 [61.3–100.0] |
| 5 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 80.7 [61.3–100.0] |
| 10 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 80.7 [61.3–100.0] |
| 30 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 80.7 [61.3–100.0] |
| 50 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 80.7 [61.3–100.0] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| single-session-user | 2 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] |

## Answer accuracy (LLM judge)

**100.0 [100.0–100.0]** over 2 questions, judged by `openai:gpt-4o` with the benchmark's judging protocol.

## Background enrichment (async LLM fact extraction)

| Metric | Value |
|---|---|
| Model | `openai:qwen/qwen3.7-flash` |
| Jobs (one per ingested session) | 98 (97 LLM calls, 0 from cache, 1 skipped as too short, 0 failed) |
| Facts stored | 194 |
| Tokens | 99982 prompt + 5820 completion |
| **Cost** | **$0.0019** ($0.000020 per LLM call; 97 of 97 calls priced by the provider) |
| LLM call latency | p50 306 · p95 316 · p99 322 ms |
| Lag, ingest to facts searchable | p50 2.0 s · p95 2.6 s |
| Recall while jobs were still pending (does not wait) | p50 122 · p95 122 ms over 2 recalls, 46 jobs pending |

## LLM usage and cost

| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| answer | `openai:gpt-4o-mini` | 2 | 200 | 10 | 0.0002 | reported by provider | 0 | 6 / 6 / 6 ms |
| judge | `openai:gpt-4o` | 2 | 200 | 10 | 0.0002 | reported by provider | 0 | 2 / 2 / 2 ms |
| **total** | | 4 | 400 | 20 | **0.0004** | | | |

Per question: 100 prompt + 5 completion tokens to the answer model, $0.00020 in all.

**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):

| | p50 | p95 | p99 |
|---|---|---|---|
| Memory recall only (local, no external call) | 75 ms | 75 ms | 75 ms |
| Answer-model call alone (network + provider) | 6 ms | 6 ms | 6 ms |
| Recall + answer (what an agent waits for) | 77 ms | 77 ms | 77 ms |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 75.1 ms · p95 75.1 ms · p99 75.1 ms · n=2 |
| — of which SQL hybrid search (Postgres) | p50 26.7 ms · p95 26.7 ms · p99 26.7 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 48.4 ms · p95 48.4 ms |
| Ingest | 521 rounds, 239 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **100.0** | **100.0** | **100.0** | **100.0** |
| **MemHouse (this run, longmemeval-s)** | round | **100.0** | **80.7** | **100.0** | **80.7** |
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
| **MemHouse (this run)** | **100.0** | openai:gpt-4o-mini | this tool |
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

