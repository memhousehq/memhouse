# MemHouse benchmark: locomo — qa-full-gpt4o-mini

Run `20261101-103558-830626` · 2026-11-01 10:35 UTC · 831 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Answer model | `openai:openai/gpt-4o-mini` (top 10 memories) |
| Judge model | `openai:openai/gpt-4o-mini` |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

1540 questions, 1536 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 65.8 [63.4–68.1] | 54.9 [52.4–57.4] | 65.8 [63.4–68.1] |
| 3 | 84.4 [82.6–86.2] | 72.8 [70.5–75.1] | 73.2 [71.3–75.1] |
| 5 | 90.1 [88.6–91.6] | 78.8 [76.7–80.9] | 75.7 [74.0–77.5] |
| 10 | 95.7 [94.7–96.6] | 87.5 [85.8–89.1] | 78.6 [77.0–80.1] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 36.1 [33.9–38.4] | 28.6 [26.3–30.9] | 36.1 [33.9–38.4] |
| 3 | 55.9 [53.3–58.4] | 45.1 [42.4–47.5] | 44.4 [42.1–46.5] |
| 5 | 63.7 [61.2–66.2] | 51.6 [48.9–54.1] | 47.2 [45.0–49.3] |
| 10 | 72.0 [69.8–74.2] | 59.2 [56.7–61.7] | 50.0 [48.0–52.0] |
| 30 | 82.6 [80.5–84.4] | 69.4 [67.0–71.7] | 52.9 [51.0–54.8] |
| 50 | 88.5 [86.8–90.0] | 76.1 [73.9–78.3] | 54.4 [52.5–56.1] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| multi-hop | 282 | 35.8 [30.1–41.5] | 57.1 [51.1–62.4] | 59.6 [53.5–64.9] |
| open-domain | 92 | 46.7 [35.9–57.6] | 63.0 [52.2–72.8] | 43.8 [33.3–53.1] |
| single-hop | 841 | 93.6 [91.8–95.1] | 97.6 [96.6–98.6] | 77.1 [74.1–79.9] |
| temporal | 321 | 87.2 [83.5–91.0] | 94.7 [92.2–97.2] | 60.7 [55.1–66.0] |

## Answer accuracy (LLM judge)

**68.4 [66.0–70.8]** over 1540 questions, judged by `openai:openai/gpt-4o-mini` with the benchmark's judging protocol.

## LLM usage and cost

| Role | Model | Calls | Prompt tokens | Completion tokens | Cost (USD) | Cost source | Retries | Call latency p50 / p95 / p99 |
|---|---|---|---|---|---|---|---|---|
| answer | `openai:openai/gpt-4o-mini` | 1540 | 922659 | 30735 | 0.1568 | reported by provider | 0 | 930 / 1504 / 1935 ms |
| judge | `openai:openai/gpt-4o-mini` | 1540 | 238102 | 3080 | 0.0376 | reported by provider | 0 | 780 / 1250 / 1605 ms |
| **total** | | 3080 | 1160761 | 33815 | **0.1944** | | | |

Per question: 599 prompt + 20 completion tokens to the answer model, $0.00013 in all.

**Latency with and without the external LLM call** (the judge is benchmark-only and excluded):

| | p50 | p95 | p99 |
|---|---|---|---|
| Memory recall only (local, no external call) | 96 ms | 109 ms | 114 ms |
| Answer-model call alone (network + provider) | 930 ms | 1504 ms | 1935 ms |
| Recall + answer (what an agent waits for) | 1020 ms | 1597 ms | 2035 ms |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 96.2 ms · p95 108.8 ms · p99 113.9 ms · n=1540 |
| — of which SQL hybrid search (Postgres) | p50 62.5 ms · p95 71.6 ms · p99 73.3 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 34.5 ms · p95 39.0 ms |
| Ingest | 5882 rounds, 8353 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published answer accuracy on locomo

Mostly vendor-reported, with different answer and judge models; use for orientation only.

| System | Accuracy % | Models | Reported by |
|---|---|---|---|
| **MemHouse (this run)** | **68.4** | openai:openai/gpt-4o-mini | this tool |
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

