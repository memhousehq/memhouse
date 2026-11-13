# MemHouse benchmark: synth-personal-7-500 — reference-500

Run `20261113-114135-c7eab4` · 2026-11-13 11:41 UTC · 409 s wall time

| Setting | Value |
|---|---|
| MemHouse | 2.0.0 |
| Embedder | `local:Qdrant/bge-small-en-v1.5-onnx-Q` |
| Reranker | off |
| Retrieval | hybrid (RRF k=60, keyword w=1, vector w=1, 100 candidates per retriever) |
| Query analysis | window w=0.15, top 3 +1, sub-query w=0 |
| Selection | limit=all stride=1 offset=0 types=all |
| Host | macos aarch64 · 8 CPU threads · embeddings on CPU |

## Evaluation suite `synth-personal-7-500`

Synthetic personal timelines: 500 conversations from seed 7 (memhouse bench synth --profile personal --seed 7 --conversations 500).

500 conversations, 8511 turns, replayed under policy `gov-3b434d14ac4d` in 409.4 s (suite hash `b2b767094c15`). Percentages with 95% bootstrap intervals over conversations.

| | Precision | Recall | F1 | Scored |
|---|---|---|---|---|
| Storage | 76.6 [75.4–77.7] | 100.0 [99.9–100.0] | 86.7 [86.0–87.4] | 10289 facts at checkpoints, 13437 records |
| Retrieval | 82.2 [80.5–83.8] | 99.8 [99.6–99.9] | 90.1 [89.1–91.1] | 7196 questions, top 5 |

| Rate | Value | Scored |
|---|---|---|
| Stale facts returned | 76.2 [73.6–78.6] | 2511 of 3296 questions about a corrected fact |
| Contamination | 0.3 [0.1–0.5] | 13 of 4909 plans and guesses committed |

Storage precision: of the scored records committed and valid at a checkpoint, the part that are current facts. Storage recall: of the current facts, the part stored. Retrieval precision: the first hit is the current fact; recall: it is in the top 5.

