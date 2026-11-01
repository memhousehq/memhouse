# MemHouse benchmark: locomo — final-locomo-enrich

Run `20261101-121631-b200d6` · 2026-11-01 12:16 UTC · 1094 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Answer model | `openai:openai/gpt-4o-mini` (top 10 rounds + facts from `qwen/qwen3.7-flash`, answer prompt v2) |
| Judge model | `openai:openai/gpt-4o-mini` |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

1540 questions, 1536 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 66.9 [64.6–69.3] | 55.0 [52.7–57.5] | 66.9 [64.6–69.3] |
| 3 | 85.1 [83.3–86.9] | 73.6 [71.4–75.7] | 73.9 [72.2–75.9] |
| 5 | 90.6 [89.1–92.0] | 79.7 [77.7–81.8] | 76.6 [74.9–78.3] |
| 10 | 96.6 [95.7–97.5] | 87.9 [86.3–89.6] | 79.4 [78.0–80.9] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 46.5 [44.1–49.0] | 36.3 [33.9–38.7] | 46.5 [44.1–49.0] |
| 3 | 64.5 [62.0–66.9] | 51.5 [49.0–54.0] | 54.4 [52.2–56.6] |
| 5 | 71.4 [69.1–73.7] | 58.1 [55.7–60.7] | 58.4 [56.3–60.6] |
| 10 | 78.9 [77.0–80.9] | 66.0 [63.5–68.2] | 63.0 [61.0–65.0] |
| 30 | 88.9 [87.2–90.4] | 76.1 [74.0–78.2] | 68.8 [67.0–70.7] |
| 50 | 92.7 [91.3–93.9] | 81.9 [79.9–83.8] | 71.4 [69.6–73.1] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| multi-hop | 282 | 37.6 [31.9–42.9] | 57.1 [51.1–63.1] | 80.9 [75.9–85.1] |
| open-domain | 92 | 48.9 [38.0–58.7] | 63.0 [53.3–72.8] | 69.8 [60.4–79.2] |
| single-hop | 841 | 93.3 [91.7–95.0] | 97.9 [96.8–98.8] | 90.7 [88.8–92.7] |
| temporal | 321 | 89.7 [86.3–92.8] | 96.0 [93.5–97.8] | 76.0 [71.3–80.7] |

## Answer accuracy (LLM judge)

**84.5 [82.7–86.4]** over 1540 questions, judged by `openai:openai/gpt-4o-mini` with the benchmark's judging protocol.

## Background enrichment (async LLM fact extraction)

| Metric | Value |
|---|---|
| Model | `openai:qwen/qwen3.7-flash@openrouter.ai` |
| Jobs (one per ingested session) | 271 (0 LLM calls, 271 from cache, 0 skipped as too short, 1 failed) |
| Facts stored | 2558 |
| Tokens | 0 prompt + 0 completion |
| **Cost** | **$0.0000** ($0.000000 per LLM call; 0 of 0 calls priced by the provider) |
| LLM call latency | p50 0 · p95 0 · p99 0 ms |
| Lag, ingest to facts searchable | p50 0.1 s · p95 0.3 s |
| Recall while jobs were still pending (does not wait) | p50 90 · p95 201 ms over 10 recalls, 17 jobs pending |

## LLM usage and cost

| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| answer | `openai:openai/gpt-4o-mini` | 1540 | 3600711 | 106910 | 0.6038 | reported by provider | 0 | 1348 / 2180 / 3225 ms |
| judge | `openai:openai/gpt-4o-mini` | 1540 | 314429 | 3080 | 0.0490 | reported by provider | 0 | 777 / 1222 / 1510 ms |
| **total** | | 3080 | 3915140 | 109990 | **0.6528** | | | |

Per question: 2338 prompt + 69 completion tokens to the answer model, $0.00042 in all.

**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):

| | p50 | p95 | p99 |
|---|---|---|---|
| Memory recall only (local, no external call) | 114 ms | 183 ms | 340 ms |
| Answer-model call alone (network + provider) | 1348 ms | 2180 ms | 3225 ms |
| Recall + answer (what an agent waits for) | 1462 ms | 2317 ms | 3329 ms |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 113.7 ms · p95 183.4 ms · p99 339.5 ms · n=1540 |
| — of which SQL hybrid search (Postgres) | p50 69.4 ms · p95 117.9 ms · p99 172.0 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 43.6 ms · p95 74.1 ms |
| Ingest | 5882 rounds, 1113 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published answer accuracy on locomo

Mostly vendor-reported, with different answer and judge models; use for orientation only.

| System | Accuracy % | Models | Reported by |
|---|---|---|---|
| **MemHouse (this run)** | **84.5** | openai:openai/gpt-4o-mini | this tool |
| OpenAI memory | 52.9 | GPT-4o-mini | [Mem0 paper](https://arxiv.org/abs/2504.19413) |
| LangMem | 58.1 | GPT-4o-mini | [Mem0 paper](https://arxiv.org/abs/2504.19413) |
| Best plain RAG | 61.0 | GPT-4o-mini | [Mem0 paper](https://arxiv.org/abs/2504.19413) |
| Mem0 (2025 paper) | 66.9 | GPT-4o-mini | [vendor](https://arxiv.org/abs/2504.19413) |
| Full context | 72.9 | GPT-4o-mini | [Mem0 paper](https://arxiv.org/abs/2504.19413) |
| Letta (filesystem) | 74.0 | GPT-4o-mini | [vendor](https://www.letta.com/blog/benchmarking-ai-agent-memory) |
| Zep (disputed: Mem0 measured 66.0) | 75.1 | GPT-4o-mini | [vendor](https://www.getzep.com/blog/lies-damn-lies-statistics-is-mem0-really-sota-in-agent-memory/) |
| MemOS | 75.8 | GPT-4o-mini | [vendor](https://huggingface.co/datasets/MemTensor/MemOS_eval_result) |
| Hindsight | 83.2 | GPT-OSS-20B answer, GPT-OSS-120B judge | [vendor](https://arxiv.org/abs/2512.12818) |
| EverMemOS | 92.3 | GPT-4.1-mini | [vendor](https://www.evermind.ai/blogs/everos-hits-sota-performance-on-locomo) |

Published search latencies (Mem0 paper, LoCoMo, hosted services incl. network): Mem0 p50 148 / p95 200 ms; Mem0 graph p50 476 / p95 657 ms; Zep (measured by Mem0) p50 513 / p95 778 ms; A-Mem p50 668 / p95 1485 ms; LangMem p50 17990 / p95 59820 ms.

