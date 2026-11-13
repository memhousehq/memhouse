# MemHouse benchmark: coding — starter

Run `20261113-123338-6516d4` · 2026-11-13 12:33 UTC · 19 s wall time

| Setting | Value |
|---|---|
| MemHouse | 2.0.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Evaluation suite `coding-starter`

20 synthetic coding conversations (facts, corrections, plans carried out or dropped, guesses, small talk).

20 conversations, 327 turns, replayed under policy `gov-3b434d14ac4d` in 18.5 s (suite hash `b7f7413404da`). Percentages with 95% bootstrap intervals over conversations.

| | Precision | Recall | F1 | Scored |
|---|---|---|---|---|
| Storage | 69.5 [64.7–75.8] | 100.0 [100.0–100.0] | 82.0 [78.5–86.3] | 333 facts at checkpoints, 479 records |
| Retrieval | 74.8 [66.9–83.8] | 100.0 [100.0–100.0] | 85.6 [80.2–91.2] | 270 questions, top 5 |

| Rate | Value | Scored |
|---|---|---|
| Stale facts returned | 75.5 [62.3–86.5] | 108 of 143 questions about a corrected fact |
| Contamination | 0.0 [0.0–0.0] | 0 of 148 plans and guesses committed |

Storage precision: of the scored records committed and valid at a checkpoint, the part that are current facts. Storage recall: of the current facts, the part stored. Retrieval precision: the first hit is the current fact; recall: it is in the top 5.

