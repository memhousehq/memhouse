# MemHouse benchmark: synth-personal-7-500 — reference-500

Run `20261113-123444-36d970` · 2026-11-13 12:34 UTC · 483 s wall time

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

500 conversations, 8511 turns, replayed under policy `gov-3b434d14ac4d` in 483.4 s (suite hash `67bf27a1859e`). Percentages with 95% bootstrap intervals over conversations.

| | Precision | Recall | F1 | Scored |
|---|---|---|---|---|
| Storage | 76.7 [75.6–77.8] | 100.0 [99.9–100.0] | 86.8 [86.1–87.5] | 10289 facts at checkpoints, 13415 records |
| Retrieval | 82.7 [81.0–84.3] | 99.8 [99.6–99.9] | 90.4 [89.4–91.4] | 7196 questions, top 5 |

| Rate | Value | Scored |
|---|---|---|
| Stale facts returned | 76.2 [73.6–78.6] | 2511 of 3296 questions about a corrected fact |
| Contamination | 0.0 [0.0–0.0] | 0 of 4399 plans and guesses committed |

Storage precision: of the scored records committed and valid at a checkpoint, the part that are current facts. Storage recall: of the current facts, the part stored. Retrieval precision: the first hit is the current fact; recall: it is in the top 5.

