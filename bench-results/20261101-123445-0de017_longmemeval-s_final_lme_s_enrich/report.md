# MemHouse benchmark: longmemeval-s — final-lme-s-enrich

Run `20261101-123445-0de017` · 2026-11-01 12:34 UTC · 3575 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Answer model | `openai:openai/gpt-4o` (top 10 rounds + facts from `qwen/qwen3.7-flash`, answer prompt v2) |
| Judge model | `openai:openai/gpt-4o` |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

500 questions, 470 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 92.6 [90.0–94.9] | 32.6 [28.5–36.8] | 92.6 [90.0–94.9] |
| 3 | 97.2 [95.5–98.7] | 84.0 [80.6–87.2] | 92.6 [90.7–94.4] |
| 5 | 98.7 [97.7–99.6] | 92.3 [90.0–94.7] | 94.0 [92.4–95.6] |
| 10 | 99.6 [98.9–100.0] | 96.4 [94.7–97.9] | 95.0 [93.6–96.3] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 70.9 [66.8–75.1] | 27.2 [23.4–31.3] | 70.9 [66.8–75.1] |
| 3 | 87.7 [84.5–90.6] | 56.8 [52.3–61.3] | 75.2 [72.0–78.4] |
| 5 | 91.7 [89.1–94.3] | 73.2 [69.1–77.0] | 81.3 [78.4–84.2] |
| 10 | 96.0 [94.0–97.7] | 83.6 [80.2–86.8] | 87.4 [84.9–89.7] |
| 30 | 99.1 [98.3–99.8] | 95.7 [93.8–97.4] | 92.9 [91.1–94.5] |
| 50 | 99.8 [99.4–100.0] | 98.1 [96.8–99.1] | 94.1 [92.6–95.5] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 72 | 98.6 [95.8–100.0] | 100.0 [100.0–100.0] | 91.7 [84.7–97.2] |
| multi-session | 121 | 90.1 [84.3–95.0] | 95.9 [92.6–99.2] | 76.0 [68.6–82.6] |
| single-session-assistant | 56 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 89.3 [82.1–96.4] |
| single-session-preference | 30 | 93.3 [83.3–100.0] | 96.7 [90.0–100.0] | 80.0 [66.7–93.3] |
| single-session-user | 64 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 95.3 [89.1–100.0] |
| temporal-reasoning | 127 | 83.5 [76.4–89.8] | 91.3 [86.6–96.1] | 84.3 [78.0–90.6] |
| abstention | 30 | – | – | 53.3 [36.7–70.0] |

## Answer accuracy (LLM judge)

**83.2 [79.6–86.4]** over 500 questions, judged by `openai:openai/gpt-4o` with the benchmark's judging protocol.

## Background enrichment (async LLM fact extraction)

| Metric | Value |
|---|---|
| Model | `openai:qwen/qwen3.7-flash@openrouter.ai` |
| Jobs (one per ingested session) | 23828 (21002 LLM calls, 2652 from cache, 174 skipped as too short, 12 failed) |
| Facts stored | 110231 |
| Tokens | 21762163 prompt + 5607082 completion |
| **Cost** | **$1.5385** ($0.000073 per LLM call; 21002 of 21002 calls priced by the provider) |
| LLM call latency | p50 2341 · p95 5785 · p99 7435 ms |
| Lag, ingest to facts searchable | p50 18.1 s · p95 26.2 s |
| Recall while jobs were still pending (does not wait) | p50 42 · p95 77 ms over 500 recalls, 23768 jobs pending |

## LLM usage and cost

| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| answer | `openai:openai/gpt-4o` | 500 | 2617920 | 46153 | 7.0063 | reported by provider | 0 | 1316 / 2338 / 3032 ms |
| judge | `openai:openai/gpt-4o` | 500 | 113447 | 860 | 0.2922 | reported by provider | 0 | 712 / 1117 / 1327 ms |
| **total** | | 1000 | 2731367 | 47013 | **7.2985** | | | |

Per question: 5236 prompt + 92 completion tokens to the answer model, $0.01460 in all.

**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):

| | p50 | p95 | p99 |
|---|---|---|---|
| Memory recall only (local, no external call) | 46 ms | 84 ms | 115 ms |
| Answer-model call alone (network + provider) | 1316 ms | 2338 ms | 3032 ms |
| Recall + answer (what an agent waits for) | 1364 ms | 2375 ms | 3094 ms |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 45.6 ms · p95 84.5 ms · p99 115.1 ms · n=500 |
| — of which SQL hybrid search (Postgres) | p50 14.3 ms · p95 30.8 ms · p99 51.0 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 30.8 ms · p95 55.2 ms |
| Ingest | 124286 rounds, 764 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **92.3** | **94.0** | **96.4** | **95.0** |
| **MemHouse (this run, longmemeval-s)** | round | **73.2** | **81.3** | **83.6** | **87.4** |
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
| **MemHouse (this run)** | **83.2** | openai:openai/gpt-4o | this tool |
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

