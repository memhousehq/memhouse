# MemHouse benchmark: longmemeval-s — final-lme-s-v3

Run `20261101-133925-c042e1` · 2026-11-01 13:39 UTC · 365 s wall time

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
| 1 | 92.6 [90.2–94.9] | 32.6 [28.5–36.8] | 92.6 [90.2–94.9] |
| 3 | 97.2 [95.5–98.7] | 84.0 [80.6–87.2] | 92.6 [90.7–94.4] |
| 5 | 98.7 [97.7–99.6] | 92.3 [89.8–94.7] | 94.0 [92.3–95.5] |
| 10 | 99.6 [98.9–100.0] | 96.4 [94.7–97.9] | 95.0 [93.6–96.3] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 70.9 [66.6–75.1] | 27.2 [23.4–31.3] | 70.9 [66.6–75.1] |
| 3 | 87.7 [84.5–90.4] | 56.8 [52.3–61.3] | 75.2 [71.9–78.2] |
| 5 | 91.7 [88.9–94.3] | 73.2 [68.9–77.2] | 81.3 [78.3–84.2] |
| 10 | 96.0 [94.0–97.7] | 83.6 [80.2–87.0] | 87.4 [84.9–89.8] |
| 30 | 99.1 [98.1–99.8] | 95.7 [93.8–97.4] | 92.9 [91.1–94.6] |
| 50 | 99.8 [99.4–100.0] | 98.1 [96.8–99.1] | 94.1 [92.6–95.6] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 72 | 98.6 [95.8–100.0] | 100.0 [100.0–100.0] | 90.3 [83.3–95.8] |
| multi-session | 121 | 90.1 [84.3–95.0] | 95.9 [91.7–99.2] | 78.5 [71.1–86.0] |
| single-session-assistant | 56 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 89.3 [80.4–96.4] |
| single-session-preference | 30 | 93.3 [83.3–100.0] | 96.7 [90.0–100.0] | 66.7 [50.0–83.3] |
| single-session-user | 64 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 96.9 [92.2–100.0] |
| temporal-reasoning | 127 | 83.5 [76.4–89.8] | 91.3 [85.8–96.1] | 89.0 [82.7–93.7] |
| abstention | 30 | – | – | 83.3 [66.7–96.7] |

## Answer accuracy (LLM judge)

**86.0 [83.0–88.8]** over 500 questions, judged by `openai:openai/gpt-4o` with the benchmark's judging protocol.

## Background enrichment (async LLM fact extraction)

| Metric | Value |
|---|---|
| Model | `openai:qwen/qwen3.7-flash@openrouter.ai` |
| Jobs (one per ingested session) | 23839 (9 LLM calls, 23656 from cache, 174 skipped as too short, 1 failed) |
| Facts stored | 110447 |
| Tokens | 13168 prompt + 7595 completion |
| **Cost** | **$0.0012** ($0.000129 per LLM call; 9 of 9 calls priced by the provider) |
| LLM call latency | p50 4578 · p95 16054 · p99 16054 ms |
| Lag, ingest to facts searchable | p50 0.1 s · p95 0.1 s |
| Recall while jobs were still pending (does not wait) | p50 26 · p95 38 ms over 494 recalls, 3621 jobs pending |

## LLM usage and cost

| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| answer | `openai:openai/gpt-4o` | 500 | 2671591 | 47910 | 7.0357 | reported by provider | 0 | 1260 / 2317 / 2976 ms |
| judge | `openai:openai/gpt-4o` | 500 | 115242 | 827 | 0.2964 | reported by provider | 0 | 679 / 1018 / 1149 ms |
| **total** | | 1000 | 2786833 | 48737 | **7.3321** | | | |

Per question: 5343 prompt + 96 completion tokens to the answer model, $0.01466 in all.

**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):

| | p50 | p95 | p99 |
|---|---|---|---|
| Memory recall only (local, no external call) | 27 ms | 40 ms | 51 ms |
| Answer-model call alone (network + provider) | 1260 ms | 2317 ms | 2976 ms |
| Recall + answer (what an agent waits for) | 1289 ms | 2345 ms | 3004 ms |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 27.5 ms · p95 40.5 ms · p99 50.5 ms · n=500 |
| — of which SQL hybrid search (Postgres) | p50 8.1 ms · p95 12.2 ms · p99 14.6 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 19.2 ms · p95 28.9 ms |
| Ingest | 124286 rounds, 2207 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

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
| **MemHouse (this run)** | **86.0** | openai:openai/gpt-4o | this tool |
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

