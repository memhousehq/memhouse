# MemHouse benchmark: support — starter

Run `20261113-105903-8f7915` · 2026-11-13 10:59 UTC · 31 s wall time

| Setting | Value |
|---|---|
| MemHouse | 2.0.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Evaluation suite `support-starter`

20 synthetic support conversations (facts, corrections, plans carried out or dropped, guesses, small talk).

20 conversations, 323 turns, replayed under policy `gov-3b434d14ac4d` in 31.4 s (suite hash `a8c70558f8e8`). Percentages with 95% bootstrap intervals over conversations.

| | Precision | Recall | F1 | Scored |
|---|---|---|---|---|
| Storage | 68.1 [64.1–72.5] | 100.0 [100.0–100.0] | 81.0 [78.1–84.1] | 325 facts at checkpoints, 477 records |
| Retrieval | 61.6 [53.2–70.8] | 99.3 [98.1–100.0] | 76.0 [69.3–82.7] | 271 questions, top 5 |

| Rate | Value | Scored |
|---|---|---|
| Stale facts returned | 91.5 [82.6–98.6] | 130 of 142 questions about a corrected fact |
| Contamination | 0.0 [0.0–0.0] | 0 of 201 plans and guesses committed |

Storage precision: of the scored records committed and valid at a checkpoint, the part that are current facts. Storage recall: of the current facts, the part stored. Retrieval precision: the first hit is the current fact; recall: it is in the top 5.

