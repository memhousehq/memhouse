# MemHouse benchmark: success — starter

Run `20261113-110039-13dc4a` · 2026-11-13 11:00 UTC · 39 s wall time

| Setting | Value |
|---|---|
| MemHouse | 2.0.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Evaluation suite `success-starter`

20 synthetic success conversations (facts, corrections, plans carried out or dropped, guesses, small talk).

20 conversations, 329 turns, replayed under policy `gov-3b434d14ac4d` in 39.2 s (suite hash `795a0fc53645`). Percentages with 95% bootstrap intervals over conversations.

| | Precision | Recall | F1 | Scored |
|---|---|---|---|---|
| Storage | 72.1 [67.9–76.7] | 100.0 [100.0–100.0] | 83.8 [80.9–86.8] | 333 facts at checkpoints, 462 records |
| Retrieval | 64.3 [57.8–72.0] | 100.0 [100.0–100.0] | 78.3 [73.3–83.7] | 280 questions, top 5 |

| Rate | Value | Scored |
|---|---|---|
| Stale facts returned | 74.3 [63.6–83.7] | 104 of 140 questions about a corrected fact |
| Contamination | 0.0 [0.0–0.0] | 0 of 202 plans and guesses committed |

Storage precision: of the scored records committed and valid at a checkpoint, the part that are current facts. Storage recall: of the current facts, the part stored. Retrieval precision: the first hit is the current fact; recall: it is in the top 5.

