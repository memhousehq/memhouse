# MemHouse benchmark: locomo — full-v5

Run `20261101-083941-b1a0c0` · 2026-11-01 08:39 UTC · 84 s wall time

| Setting | Value |
|---|---|
| MemHouse | 0.1.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.3, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Retrieval quality

1540 questions, 1536 scored against ground-truth evidence (abstention / adversarial questions are not scored for retrieval). Values are percentages with 95% bootstrap confidence intervals.

**Session level** (rounds collapsed to their sessions, LongMemEval definition)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 65.7 [63.2–68.0] | 54.8 [52.2–57.2] | 65.7 [63.2–68.0] |
| 3 | 84.2 [82.4–86.0] | 72.6 [70.3–74.7] | 73.1 [71.1–74.9] |
| 5 | 90.2 [88.7–91.7] | 79.0 [76.9–81.0] | 75.8 [74.0–77.4] |
| 10 | 96.1 [95.1–97.1] | 87.9 [86.2–89.5] | 78.7 [77.2–80.1] |

**Round / turn level** (a round is relevant if it contains an evidence message)

| k | recall_any@k | recall_all@k | nDCG@k |
|---|---|---|---|
| 1 | 36.3 [33.9–38.7] | 28.8 [26.5–31.0] | 36.3 [33.9–38.7] |
| 3 | 55.9 [53.4–58.3] | 45.2 [42.6–47.7] | 44.4 [42.2–46.6] |
| 5 | 63.8 [61.3–66.1] | 51.7 [49.2–54.1] | 47.3 [45.1–49.3] |
| 10 | 72.4 [70.2–74.7] | 59.3 [56.8–61.7] | 50.2 [48.2–52.2] |
| 30 | 82.7 [80.8–84.7] | 69.7 [67.3–72.0] | 53.1 [51.2–54.9] |
| 50 | 88.8 [87.2–90.4] | 76.6 [74.3–78.6] | 54.6 [52.7–56.3] |

**By question type**

| Type | n | session/recall_all@5 | session/recall_all@10 | QA accuracy |
|---|---|---|---|---|
| multi-hop | 282 | 35.8 [30.5–41.1] | 57.1 [51.4–62.4] | – |
| open-domain | 92 | 47.8 [37.0–57.6] | 64.1 [53.3–73.9] | – |
| single-hop | 841 | 93.8 [92.2–95.2] | 98.1 [97.1–98.9] | – |
| temporal | 321 | 86.9 [83.5–90.7] | 95.0 [92.5–97.5] | – |

## Latency and throughput

| Metric | Value |
|---|---|
| Recall (end to end: query embedding + one SQL statement) | p50 43.0 ms · p95 56.9 ms · p99 64.3 ms · n=1540 |
| — of which SQL hybrid search (Postgres) | p50 9.9 ms · p95 15.1 ms · p99 18.3 ms |
| — of which query embedding (CPU, shared with concurrent ingest) | p50 32.1 ms · p95 44.5 ms |
| Ingest | 5882 rounds, 101 rounds/s with 4 workers (includes embedding on CPU, cache hits for repeated sessions) |

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

