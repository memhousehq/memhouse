# MemHouse benchmark: synth-personal-7-500 — reference-500

Run `20261113-105819-bd721e` · 2026-11-13 10:58 UTC · 616 s wall time

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

500 conversations, 8511 turns, replayed under policy `gov-3b434d14ac4d` in 615.5 s (suite hash `b2b767094c15`). Percentages with 95% bootstrap intervals over conversations.

| | Precision | Recall | F1 | Scored |
|---|---|---|---|---|
| Storage | 76.5 [75.3–77.6] | 99.7 [99.4–99.9] | 86.6 [85.8–87.3] | 10289 facts at checkpoints, 13421 records |
| Retrieval | 81.9 [80.3–83.6] | 99.5 [99.1–99.8] | 89.9 [88.8–90.9] | 7196 questions, top 5 |

| Rate | Value | Scored |
|---|---|---|
| Stale facts returned | 76.1 [73.5–78.6] | 2508 of 3296 questions about a corrected fact |
| Contamination | 0.3 [0.1–0.5] | 13 of 4909 plans and guesses committed |

Storage precision: of the scored records committed and valid at a checkpoint, the part that are current facts. Storage recall: of the current facts, the part stored. Retrieval precision: the first hit is the current fact; recall: it is in the top 5.

