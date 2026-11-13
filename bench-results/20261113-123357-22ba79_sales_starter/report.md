# MemHouse benchmark: sales — starter

Run `20261113-123357-22ba79` · 2026-11-13 12:33 UTC · 18 s wall time

| Setting | Value |
|---|---|
| MemHouse | 2.0.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Evaluation suite `sales-starter`

20 synthetic sales conversations (facts, corrections, plans carried out or dropped, guesses, small talk).

20 conversations, 328 turns, replayed under policy `gov-3b434d14ac4d` in 18.0 s (suite hash `b67cf8f16b30`). Percentages with 95% bootstrap intervals over conversations.

| | Precision | Recall | F1 | Scored |
|---|---|---|---|---|
| Storage | 69.9 [66.8–74.0] | 100.0 [100.0–100.0] | 82.3 [80.1–85.0] | 330 facts at checkpoints, 472 records |
| Retrieval | 67.4 [60.3–76.1] | 100.0 [100.0–100.0] | 80.5 [75.2–86.4] | 279 questions, top 5 |

| Rate | Value | Scored |
|---|---|---|
| Stale facts returned | 85.8 [77.2–93.5] | 115 of 134 questions about a corrected fact |
| Contamination | 0.0 [0.0–0.0] | 0 of 178 plans and guesses committed |

Storage precision: of the scored records committed and valid at a checkpoint, the part that are current facts. Storage recall: of the current facts, the part stored. Retrieval precision: the first hit is the current fact; recall: it is in the top 5.

