# MemHouse benchmark: longmemeval-s — qa-full-gpt4o

Run `20261101-103118-d1fd82` · 2026-11-01 10:31 UTC · 279 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Answer model | `openai:openai/gpt-4o` (top 10 memories) |
| Judge model | `openai:openai/gpt-4o` |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

500 questions, 470 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 91.1 [88.3–93.6] | 31.1 [27.0–35.3] | 91.1 [88.3–93.6] |
| 3 | 97.2 [95.5–98.7] | 82.6 [78.9–86.0] | 91.4 [89.4–93.3] |
| 5 | 98.9 [97.9–99.8] | 91.3 [88.7–93.8] | 93.0 [91.3–94.6] |
| 10 | 99.8 [99.4–100.0] | 96.2 [94.5–97.9] | 94.1 [92.6–95.4] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 58.5 [54.0–63.2] | 22.8 [18.9–26.8] | 58.5 [54.0–63.2] |
| 3 | 85.7 [82.6–88.7] | 52.1 [47.4–56.6] | 64.3 [61.2–67.5] |
| 5 | 91.9 [89.4–94.3] | 70.6 [66.6–74.9] | 70.3 [67.5–73.2] |
| 10 | 96.2 [94.3–97.9] | 84.5 [81.3–87.7] | 74.3 [71.8–76.8] |
| 30 | 99.1 [98.3–99.8] | 95.3 [93.4–97.0] | 76.4 [74.3–78.7] |
| 50 | 99.6 [98.9–100.0] | 96.6 [94.9–98.1] | 76.7 [74.5–78.9] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| knowledge-update | 72 | 98.6 [95.8–100.0] | 100.0 [100.0–100.0] | 87.5 [79.2–94.4] |
| multi-session | 121 | 86.0 [80.2–91.7] | 94.2 [90.1–98.3] | 62.0 [53.7–70.2] |
| single-session-assistant | 56 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 85.7 [76.8–94.6] |
| single-session-preference | 30 | 93.3 [83.3–100.0] | 100.0 [100.0–100.0] | 40.0 [23.3–56.7] |
| single-session-user | 64 | 100.0 [100.0–100.0] | 100.0 [100.0–100.0] | 96.9 [92.2–100.0] |
| temporal-reasoning | 127 | 83.5 [76.4–89.8] | 91.3 [85.8–96.1] | 80.3 [73.2–86.6] |
| abstention | 30 | – | – | 76.7 [60.0–90.0] |

## Answer accuracy (LLM judge)

**77.0 [73.4–80.8]** over 500 questions, judged by `openai:openai/gpt-4o` with the benchmark's judging protocol.

## LLM usage and cost

| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| answer | `openai:openai/gpt-4o` | 500 | 1631868 | 21079 | 4.2905 | reported by provider | 0 | 1028 / 1622 / 1950 ms |
| judge | `openai:openai/gpt-4o` | 500 | 88307 | 700 | 0.2278 | reported by provider | 0 | 708 / 1069 / 1363 ms |
| **total** | | 1000 | 1720175 | 21779 | **4.5182** | | | |

Per question: 3264 prompt + 42 completion tokens to the answer model, $0.00904 in all.

**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):

| | p50 | p95 | p99 |
|---|---|---|---|
| Memory recall only (local, no external call) | 27 ms | 41 ms | 48 ms |
| Answer-model call alone (network + provider) | 1028 ms | 1622 ms | 1950 ms |
| Recall + answer (what an agent waits for) | 1057 ms | 1653 ms | 1980 ms |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 26.9 ms · p95 41.3 ms · p99 48.5 ms · n=500 |
| — of which SQL hybrid search (Postgres) | p50 6.7 ms · p95 10.0 ms · p99 12.2 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 20.0 ms · p95 33.0 ms |
| Ingest | 124286 rounds, 2958 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published retrieval results

From the LongMemEval paper (Table 9). These were measured on **LongMemEval_M** (~500 sessions per question); compare against MemHouse runs on the same split. The paper's "Recall@k" is compared here with MemHouse's recall_all@k (the stricter of the two definitions in the reference code).

| System | Granularity | R@5 | nDCG@5 | R@10 | nDCG@10 |
|---|---|---|---|---|---|
| **MemHouse (this run, longmemeval-s)** | session | **91.3** | **93.0** | **96.2** | **94.1** |
| **MemHouse (this run, longmemeval-s)** | round | **70.6** | **70.3** | **84.5** | **74.3** |
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
| **MemHouse (this run)** | **77.0** | openai:openai/gpt-4o | this tool |
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

