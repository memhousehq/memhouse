# MemHouse benchmark: locomo — final-locomo-v3

Run `20261101-134543-abf8f9` · 2026-11-01 13:45 UTC · 1122 s wall time

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
| 1 | 66.8 [64.5–69.2] | 54.9 [52.3–57.4] | 66.8 [64.5–69.2] |
| 3 | 85.2 [83.3–87.0] | 73.7 [71.5–75.8] | 74.0 [72.2–75.8] |
| 5 | 90.6 [89.1–92.0] | 79.6 [77.5–81.6] | 76.5 [74.9–78.2] |
| 10 | 96.7 [95.8–97.5] | 87.9 [86.3–89.5] | 79.4 [78.0–80.9] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 46.5 [44.1–49.0] | 36.3 [34.0–38.7] | 46.5 [44.1–49.0] |
| 3 | 64.5 [62.1–67.0] | 51.5 [49.0–54.0] | 54.4 [52.2–56.6] |
| 5 | 71.4 [69.0–73.6] | 58.1 [55.7–60.6] | 58.4 [56.3–60.6] |
| 10 | 79.0 [76.8–81.0] | 66.0 [63.5–68.3] | 63.0 [61.0–65.1] |
| 30 | 88.9 [87.2–90.4] | 76.2 [74.0–78.2] | 68.8 [67.0–70.7] |
| 50 | 92.8 [91.5–93.9] | 81.9 [79.9–83.8] | 71.4 [69.6–73.1] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| multi-hop | 282 | 36.9 [31.2–42.2] | 56.7 [50.7–62.4] | 79.8 [74.8–84.8] |
| open-domain | 92 | 50.0 [40.2–59.8] | 64.1 [54.3–73.9] | 66.7 [57.3–76.0] |
| single-hop | 841 | 93.3 [91.7–94.9] | 97.9 [96.8–98.8] | 90.2 [88.2–92.4] |
| temporal | 321 | 89.4 [86.0–92.8] | 96.0 [93.5–97.8] | 75.1 [70.4–79.8] |

## Answer accuracy (LLM judge)

**83.7 [81.8–85.5]** over 1540 questions, judged by `openai:openai/gpt-4o-mini` with the benchmark's judging protocol.

## Background enrichment (async LLM fact extraction)

| Metric | Value |
|---|---|
| Model | `openai:qwen/qwen3.7-flash@openrouter.ai` |
| Jobs (one per ingested session) | 272 (1 LLM calls, 271 from cache, 0 skipped as too short, 0 failed) |
| Facts stored | 2559 |
| Tokens | 1012 prompt + 74 completion |
| **Cost** | **$0.0000** ($0.000000 per LLM call; 1 of 1 calls priced by the provider) |
| LLM call latency | p50 1327 · p95 1327 · p99 1327 ms |
| Lag, ingest to facts searchable | p50 0.1 s · p95 0.1 s |
| Recall while jobs were still pending (does not wait) | p50 70 · p95 77 ms over 10 recalls, 55 jobs pending |

## LLM usage and cost

| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| answer | `openai:openai/gpt-4o-mini` | 1540 | 3765187 | 136945 | 0.6465 | reported by provider | 0 | 1494 / 2653 / 3363 ms |
| judge | `openai:openai/gpt-4o-mini` | 1540 | 344737 | 3080 | 0.0536 | reported by provider | 0 | 754 / 1236 / 1533 ms |
| **total** | | 3080 | 4109924 | 140025 | **0.7001** | | | |

Per question: 2445 prompt + 89 completion tokens to the answer model, $0.00045 in all.

**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):

| | p50 | p95 | p99 |
|---|---|---|---|
| Memory recall only (local, no external call) | 109 ms | 127 ms | 132 ms |
| Answer-model call alone (network + provider) | 1494 ms | 2653 ms | 3363 ms |
| Recall + answer (what an agent waits for) | 1595 ms | 2736 ms | 3469 ms |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 108.8 ms · p95 127.1 ms · p99 131.7 ms · n=1540 |
| — of which SQL hybrid search (Postgres) | p50 75.2 ms · p95 90.1 ms · p99 92.6 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 34.0 ms · p95 38.9 ms |
| Ingest | 5882 rounds, 5900 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published answer accuracy on locomo

Mostly vendor-reported, with different answer and judge models; use for orientation only.

| System | Accuracy % | Models | Reported by |
|---|---|---|---|
| **MemHouse (this run)** | **83.7** | openai:openai/gpt-4o-mini | this tool |
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

