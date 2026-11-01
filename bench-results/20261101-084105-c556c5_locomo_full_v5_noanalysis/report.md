# MemHouse benchmark: locomo — full-v5-noanalysis

Run `20261101-084105-c556c5` · 2026-11-01 08:41 UTC · 17 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | off |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

1540 questions, 1536 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 61.7 [59.1–64.1] | 51.0 [48.5–53.5] | 61.7 [59.1–64.1] |
| 3 | 81.6 [79.6–83.6] | 70.1 [67.8–72.3] | 69.9 [67.9–71.9] |
| 5 | 88.2 [86.6–89.8] | 76.8 [74.7–79.0] | 72.8 [71.0–74.6] |
| 10 | 94.8 [93.7–95.9] | 86.5 [84.7–88.2] | 76.0 [74.3–77.5] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 34.1 [31.6–36.5] | 26.8 [24.5–29.0] | 34.1 [31.6–36.5] |
| 3 | 53.8 [51.2–56.5] | 43.2 [40.5–45.6] | 42.4 [40.1–44.6] |
| 5 | 62.0 [59.5–64.5] | 50.0 [47.3–52.5] | 45.4 [43.1–47.5] |
| 10 | 71.0 [68.6–73.2] | 58.3 [55.8–60.7] | 48.4 [46.3–50.4] |
| 30 | 81.6 [79.7–83.6] | 68.8 [66.5–71.0] | 51.4 [49.5–53.2] |
| 50 | 88.2 [86.5–89.7] | 75.6 [73.4–77.7] | 52.9 [51.0–54.7] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| multi-hop | 282 | 34.8 [29.4–40.4] | 56.7 [51.1–62.1] | – |
| open-domain | 92 | 45.7 [35.9–55.4] | 62.0 [52.2–71.7] | – |
| single-hop | 841 | 91.3 [89.4–93.2] | 96.8 [95.6–98.0] | – |
| temporal | 321 | 84.4 [80.4–88.8] | 92.5 [89.7–95.6] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement per probe) | p50 34.3 ms · p95 42.3 ms · p99 46.9 ms · n=1540 |
| — of which SQL hybrid search (Postgres) | p50 7.2 ms · p95 10.9 ms · p99 14.1 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 27.0 ms · p95 33.1 ms |
| Ingest | 5882 rounds, 5398 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

## Reference: published answer accuracy on locomo

Mostly vendor-reported, with different answer and judge models; use for orientation only.

| System | Accuracy % | Models | Reported by |
|---|---|---|---|
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

