# MemHouse benchmark: locomo — full-q-hybrid

Run `20261101-040035-ab43ed` · 2026-11-01 04:00 UTC · 88 s wall time

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
| 1 | 54.9 [52.2–57.4] | 45.6 [43.0–48.0] | 54.9 [52.2–57.4] |
| 3 | 77.5 [75.3–79.6] | 65.8 [63.4–68.1] | 64.6 [62.4–66.7] |
| 5 | 85.5 [83.8–87.3] | 73.6 [71.3–75.7] | 68.1 [66.1–70.0] |
| 10 | 93.4 [92.3–94.6] | 84.4 [82.6–86.2] | 71.7 [70.0–73.3] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 30.1 [27.7–32.4] | 24.2 [22.0–26.2] | 30.1 [27.7–32.4] |
| 3 | 49.0 [46.5–51.5] | 39.3 [36.7–41.7] | 38.2 [36.0–40.2] |
| 5 | 57.7 [55.3–60.2] | 45.9 [43.4–48.3] | 41.3 [39.2–43.2] |
| 10 | 67.3 [65.0–69.7] | 54.7 [52.1–57.2] | 44.5 [42.5–46.4] |
| 30 | 80.1 [78.1–82.2] | 67.4 [65.0–69.6] | 48.0 [46.2–49.8] |
| 50 | 86.9 [85.2–88.6] | 74.0 [71.7–76.2] | 49.6 [47.8–51.3] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| multi-hop | 282 | 30.5 [25.2–35.8] | 52.8 [47.2–59.2] | – |
| open-domain | 92 | 46.7 [35.9–56.5] | 62.0 [52.2–71.7] | – |
| single-hop | 841 | 88.0 [85.6–90.1] | 94.9 [93.3–96.3] | – |
| temporal | 321 | 81.3 [77.3–85.4] | 91.3 [88.2–94.4] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 54.9 ms · p95 75.8 ms · p99 84.4 ms · n=1540 |
| — of which SQL hybrid search (Postgres) | p50 26.2 ms · p95 39.5 ms · p99 44.6 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 31.3 ms · p95 42.6 ms |
| Ingest | 5882 rounds, 103 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

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

