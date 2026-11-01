# Benchmarks

MemHouse ships its own benchmark tool (`memhouse bench`). It downloads the public datasets,
replays every conversation through the normal ingest path, queries through the normal recall
path, and scores against the datasets' ground-truth evidence with the metric definitions from
the LongMemEval reference code. Every run writes `summary.json` and `report.md` under
`bench-results/`, so results are reproducible and diffable.

All numbers below are from one MacBook (Apple M2, 8 CPU threads, 24 GB), everything local:
Postgres 17 + pgvector in Docker, the quantized `bge-small-en-v1.5` embedding model on CPU,
no GPU, no network calls, no LLM anywhere in the write or read path.

## Headline results (retrieval)

Default configuration: hybrid BM25 + vector search, two vectors per round, date-aware query
analysis (time-window probe: weight 0.15 for every in-window hit, +1.0 for the top 3), no reranker.

| Dataset | Questions scored | session recall_any@5 | session recall_all@5 | session recall_all@10 | session nDCG@10 | round recall_all@10 | recall p50 / p95 |
|---|---|---|---|---|---|---|---|
| LongMemEval_S (500 q, ~50 sessions each) | 470 | 98.9 | **91.3** | **96.2** | **94.1** | 84.5 | 26 / 37 ms |
| LoCoMo (10 conversations, 1,540 q) | 1,536 | 90.1 | **78.8** | **87.5** | **78.6** | 59.2 | 35 / 42 ms |

Latency here is with cached vectors (no concurrent embedding); recall during a cold ingest,
with four workers embedding on the same CPU, is 64 / 91 ms on LongMemEval_S.

LongMemEval abstention questions (`_abs`) and LoCoMo adversarial questions (category 5) have no
evidence and are not scored for retrieval. *recall_all@k* is the stricter definition: every
evidence session must be in the top k. Every report in `bench-results/` carries 95% bootstrap
confidence intervals; on LongMemEval_S the interval for recall_all@5 is about ±2.7 points.

### By question type

| LongMemEval_S | n | recall_all@5 | recall_all@10 |
|---|---|---|---|
| single-session-user | 64 | 100.0 | 100.0 |
| single-session-assistant | 56 | 100.0 | 100.0 |
| single-session-preference | 30 | 93.3 | 100.0 |
| knowledge-update | 72 | 98.6 | 100.0 |
| multi-session | 121 | 86.0 | 94.2 |
| temporal-reasoning | 127 | 83.5 | 91.3 |

| LoCoMo | n | recall_all@5 | recall_all@10 |
|---|---|---|---|
| single-hop | 841 | 93.6 | 97.6 |
| temporal | 321 | 87.2 | 94.7 |
| open-domain | 92 | 46.7 | 63.0 |
| multi-hop | 282 | 35.8 | 57.1 |

### Against published retrieval baselines

The LongMemEval paper (Table 9) reports retrievers on **LongMemEval_M**, where each question
has about 500 sessions (~1.5M tokens) of history instead of ~50. MemHouse on M is from a
stratified 50-question sample (`--stride 10`, 48 scored, ~2,450 rounds per question); a full
M run takes about 11 hours on this laptop and has not been done.

| System | Split | session R@5 | session R@10 | session nDCG@10 |
|---|---|---|---|---|
| **MemHouse default (bge-small Q, no LLM)** | **M**, 48 q | **79.2** [66.7–89.6] | **89.6** [81.2–97.9] | **82.6** [75.0–89.6] |
| MemHouse, `--no-analysis` | M, 48 q | 81.2 | 89.6 | 82.9 |
| Contriever + LLM-extracted fact keys (paper's best) | M | 76.2 | 86.2 | 65.8 |
| Stella V5 1.5B | M | 72.0 | 79.4 | 61.5 |
| Contriever | M | 72.3 | 82.3 | 66.3 |
| BM25 | M | 63.4 | 71.0 | 54.0 |
| MemHouse default | S, 470 q | 91.3 | 96.2 | 94.1 |

On the like-for-like split MemHouse matches the paper's best retriever at R@5 and is ahead at
R@10 and on ranking quality (nDCG@10 +17 points), without the LLM key-extraction pass at
ingest that system needs. The sample is small: the R@5 interval is ±11 points, so "on par" is
the honest reading for R@5; the 2-point gap to `--no-analysis` is one question. M recall is
p50 66 / p95 96 ms (exact vector search over ~5k vectors per subject).

Memory vendors (Mem0, Zep, Supermemory, Mastra) publish answer accuracy, not retrieval recall,
so there is no direct retrieval number to compare against; see [Answer accuracy](#answer-accuracy-qa) for the end-to-end comparison.

### What changed since the first full run

| | LongMemEval_S R_all@5 / @10 / nDCG@10 | LoCoMo R_all@5 / @10 / nDCG@10 |
|---|---|---|
| First full run (`full-q-hybrid`) | 81.1 / 86.4 / 85.8 | 73.6 / 84.4 / 71.7 |
| Current default (`full-v7`) | **91.3 / 96.2 / 94.1** | **78.8 / 87.5 / 78.6** |

Four changes, in order of impact:

1. **Benchmark protocol fix.** The runner used to pass the question date as `as_of`, which is a
   *state filter*: it hid evidence stamped later on the same day as the question (40 of 127
   LongMemEval temporal questions). The runner now passes it as `reference_time`, the "now"
   used to read relative dates, and leaves state unfiltered. All earlier LongMemEval numbers
   were under-reported because of this.
2. **BM25 keyword scoring** in SQL instead of `ts_rank` (keyword-only on the 50-question sample:
   R_all@5 63.0 → 80.4).
3. **Two vectors per round**: the whole round, and the user's own message alone. Vector search
   takes the closer of the two, so long assistant replies no longer drown out what the user said
   (temporal subset round recall_all@10: 47.2 → 51.2 before the protocol fix).
4. **Date-aware query analysis** (below).

### Date-aware recall

`recall` parses relative and absolute dates in the query ("two weeks ago", "last weekend",
"in March", "on May 3rd", "between … and …") against `reference_time` and runs a second,
time-window probe next to the main one. The lists are fused with weighted RRF in two parts:
every in-window hit gets a light boost (weight 0.15) and the top 3 in-window hits get a strong
one (+1.0). The few memories that best match both the topic and the date jump to the top, while
same-topic memories from other dates keep their place instead of being pushed down. No LLM is
involved; the parser is a set of regular expressions (`crates/memhouse-core/src/query.rs`).

Effect on the full datasets (default vs `--no-analysis`):

| | R_any@5 | R_all@5 | R_all@10 | nDCG@10 | round R_all@10 |
|---|---|---|---|---|---|
| LongMemEval_S, default | **98.9** | **91.3** | **96.2** | **94.1** | **84.5** |
| LongMemEval_S, off | 98.3 | **91.3** | 96.0 | 94.0 | 84.0 |
| LongMemEval_S temporal, default / off | 98.4 / 96.1 | 83.5 / 83.5 | **91.3** / 90.6 | **90.7** / 89.8 | **82.7** / 79.5 |
| LoCoMo, default | **90.1** | **78.8** | **87.5** | **78.6** | **59.2** |
| LoCoMo, off | 88.2 | 76.8 | 86.5 | 76.0 | 58.3 |
| LoCoMo temporal, default / off | | **87.2** / 84.4 | **94.7** / 92.5 | | |
| LongMemEval_M sample, default / off | 93.8 / 93.8 | 79.2 / **81.2** | 89.6 / 89.6 | 82.6 / 82.9 | 77.1 / 77.1 |

On LongMemEval_S and LoCoMo the default is equal or better on every metric; on LoCoMo temporal
questions +2.8 R_all@5, on LongMemEval temporal questions +3.2 exact-turn recall (the turns the
agent needs to answer). The M sample is within one question either way.

How the weights were chosen, on the 127 LongMemEval temporal-reasoning questions (LoCoMo and M
were not used for tuning and serve as the check):

| Temporal subset (127 q) | R_any@5 | R_all@5 | R_all@10 | nDCG@10 | round R_all@10 | round nDCG@10 |
|---|---|---|---|---|---|---|
| no analysis | 96.1 | **83.5** | 90.6 | 89.8 | 79.5 | 67.6 |
| all window hits, weight 1.0 | **98.4** | 81.1 | 85.0 | 88.6 | **84.3** | **69.9** |
| all window hits, weight 0.3 (previous default) | **98.4** | 81.9 | 89.8 | 90.0 | 83.5 | 69.5 |
| only top 3 window hits, weight 1.0 | 96.9 | **83.5** | **91.3** | 90.9 | 80.3 | 68.4 |
| **0.15 all + 1.0 top 3 (default)** | **98.4** | **83.5** | **91.3** | 90.7 | 82.7 | 69.6 |
| 0.3 all + 1.0 top 3 | **98.4** | 81.9 | 89.8 | 90.1 | 83.5 | 70.0 |
| sub-queries only (split "X or Y" comparisons) | 96.1 | 81.9 | 91.3 | 88.5 | 70.9 | 62.6 |

Why a uniform window weight lowered strict recall_all: for questions such as "what sports event
did I do two weeks ago", LongMemEval also lists same-topic sessions from *other* dates as
evidence, and boosting the whole window pushed those down. Capping the strong boost to three
hits removes that cost. Comparison sub-queries added noise and are off by default
(`subquery_weight = 0`). Turn the analysis off with `query_analysis = false` or per request
with `"analyze": false`.

### Latency

Recall is one batched query embedding plus one SQL statement per probe (keyword search, vector
search, fusion, validity and governance filters together); probes run concurrently.

| | p50 | p95 | p99 |
|---|---|---|---|
| End-to-end recall, LongMemEval_S, during ingest | 64 ms | 91 ms | 102 ms |
| — SQL hybrid search in Postgres | 26 ms | 37 ms | 45 ms |
| — query embedding on CPU | 38 ms | 59 ms | – |
| End-to-end recall, LongMemEval_S, idle CPU | 26 ms | 37 ms | – |
| End-to-end recall, LoCoMo, idle CPU | 35 ms | 42 ms | – |
| Recall with cross-encoder rerank (top 20, 4 concurrent queries) | 2.6 s | 4.5 s | – |

For orientation, the Mem0 paper measured search latency on LoCoMo for hosted services
(network included): Mem0 148 / 200 ms, Zep 513 / 778 ms, LangMem 18 s / 60 s (p50 / p95).

Ingest ran at about 30 rounds/s on LongMemEval_S (124k rounds, two vectors each) with
4 workers on CPU; ingest never calls an LLM.

## Ablations (50 LongMemEval_S questions, `--stride 10`)

These ran before the protocol fix and before dual vectors, so absolute numbers are lower than
the headline; they compare retrieval modes against each other.

| Mode | session R_any@5 | session R_all@5 | session nDCG@10 | round nDCG@10 | recall p50 |
|---|---|---|---|---|---|
| keyword only, `ts_rank` | 95.7 | 63.0 | 75.3 | 53.4 | 9 ms |
| keyword only, BM25 | 97.8 | 80.4 | 88.1 | 72.2 | 12 ms |
| dense only | 95.7 | 80.4 | 85.9 | 62.0 | 57 ms |
| hybrid | 95.7 | 80.4 | 86.8 | 66.1 | 60 ms |
| hybrid + rerank, bge-reranker-base top 40 | 95.7 | 78.3 | 89.3 | 73.7 | 221 s ² |
| hybrid + rerank, jina-reranker-v1-turbo-en top 20 | 97.8 | 80.4 | 90.6 | 73.9 | 2.6 s |

² Before length-batched reranking; unusable on CPU, kept for the record.

The cross-encoder mainly improves *ordering* (round nDCG +8 points). It is opt-in
(`[rerank] enabled = true`) because it costs about a second per recall on CPU.

## Where it is weak

| Slice | session R_all@5 / @10 | Why |
|---|---|---|
| LoCoMo multi-hop | 35.8 / 57.1 | Evidence spread over several sessions with little lexical overlap with the question. |
| LoCoMo open-domain | 46.7 / 63.0 | Answers depend on world knowledge plus a hint in the dialogue. |
| LongMemEval temporal-reasoning | 83.5 / 91.3 | Mostly the labelling effect described above; the remaining misses need event-relative dates ("two weeks before the trip"), which the parser does not resolve. |

Next steps on these slices: event-anchored dates (find the anchor event, then window around
it) and entity-linked expansion for multi-hop questions.

## Answer accuracy (QA)

End-to-end protocol: MemHouse recalls the top 10 rounds, an LLM answers from them, and an LLM
judge grades the answer with each benchmark's published judging prompt. Models were called
through OpenRouter; tokens and cost are the provider's own figures, recorded per call in the
run's `items.jsonl` and totalled in `report.md`. One run each, no tuning on the paid API.

| Dataset | Answer / judge model | Questions | **Accuracy** | Tokens (prompt + completion) | **Cost** |
|---|---|---|---|---|---|
| LongMemEval_S | gpt-4o / gpt-4o | 500 | **77.0** [73.4–80.8] | 1.72M + 22k | **$4.52** |
| LoCoMo (categories 1–4) | gpt-4o-mini / gpt-4o-mini | 1,540 | **68.4** [66.0–70.8] | 1.16M + 34k | **$0.19** |

Published results with the same answer model (vendor-reported unless noted):

| LongMemEval_S, GPT-4o | Accuracy |
|---|---|
| Full context, no memory system (Zep paper) | 60.2 |
| Zep | 71.2 |
| **MemHouse** | **77.0** |
| Bedrock AgentCore memory (Redis re-run) | 77.0 |
| Emergence fast (Redis re-run) | 81.3 |
| Supermemory | 81.6 |
| Mastra Observational Memory (Redis reproduced) | 84.2 |

| LoCoMo, GPT-4o-mini | Accuracy |
|---|---|
| OpenAI memory (Mem0 paper) | 52.9 |
| LangMem (Mem0 paper) | 58.1 |
| Best plain RAG (Mem0 paper) | 61.0 |
| Mem0 (2025 paper) | 66.9 |
| **MemHouse** | **68.4** |
| Full context (Mem0 paper) | 72.9 |
| Letta filesystem | 74.0 |
| Zep (vendor; Mem0 measured 66.0) | 75.1 |

MemHouse is ahead of Zep and Mem0 and level with Bedrock AgentCore, without an LLM anywhere in
its write path, but 4–7 points behind the leaders on LongMemEval (Emergence, Supermemory,
Mastra) and 6–7 behind Letta and Zep on LoCoMo. Those systems spend LLM calls at ingest
(fact extraction, observations, summaries) and give the answer model more context.

By question type:

| LongMemEval_S | n | retrieval R_all@10 | **QA accuracy** |
|---|---|---|---|
| single-session-user | 64 | 100.0 | 96.9 |
| knowledge-update | 72 | 100.0 | 87.5 |
| single-session-assistant | 56 | 100.0 | 85.7 |
| temporal-reasoning | 127 | 91.3 | 80.3 |
| abstention | 30 | – | 76.7 |
| multi-session | 121 | 94.2 | 62.0 |
| single-session-preference | 30 | 100.0 | 40.0 |

| LoCoMo | n | retrieval R_all@10 | **QA accuracy** |
|---|---|---|---|
| single-hop | 841 | 97.6 | 77.1 |
| temporal | 321 | 94.7 | 60.7 |
| multi-hop | 282 | 57.1 | 59.6 |
| open-domain | 92 | 63.0 | 43.8 |

The gap between retrieval and answer accuracy shows where the remaining points are. Temporal
questions are retrieved well (91–95%), so the losses there are in the answer step:
- **Preference (40%)** needs a personalised suggestion, not a fact; the answer prompt asks for
  a short direct answer.
- **Multi-session (62%)** is counting and aggregation across sessions, and 10 rounds of
  context is often too little.
- **LoCoMo temporal (61%)** expects absolute dates ("7 May 2023") for relative phrases in the
  dialogue ("yesterday"); the answer model sees each memory's date but often does not resolve
  it.
- **LoCoMo context is small:** 599 prompt tokens per question, against 3,264 on LongMemEval.

### Latency with and without the external LLM call

| | LongMemEval_S p50 / p95 | LoCoMo p50 / p95 |
|---|---|---|
| Memory recall only (local) | 27 / 41 ms | 96 / 109 ms ³ |
| Answer-model call alone (OpenRouter) | 1,028 / 1,622 ms | 930 / 1,504 ms |
| Recall + answer (what an agent waits for) | 1,057 / 1,653 ms | 1,020 / 1,597 ms |

Memory adds about 3% to the time an agent waits for its answer; the rest is the LLM provider.
The judge call (708 / 780 ms p50) is benchmark-only and not included.

³ Higher than the retrieval-only LoCoMo run (35 ms) because four workers were waiting on
network calls while sharing the CPU with ingest.

Reproduce (needs an OpenAI-compatible key; `--max-cost-usd` stops a run that overspends):

```bash
memhouse bench run --dataset longmemeval-s --qa --llm-base-url https://openrouter.ai/api/v1 \
  --answer-model openai/gpt-4o --judge-model openai/gpt-4o --max-cost-usd 10
memhouse bench run --dataset locomo --qa --llm-base-url https://openrouter.ai/api/v1 \
  --answer-model openai/gpt-4o-mini --judge-model openai/gpt-4o-mini --max-cost-usd 3
```

## Governance suite

`memhouse bench run --suite governance` runs 12 checks; all pass:
prompt-injection persistence (0 of 15 attempts committed or recalled), false quarantine (0%),
PII canaries in storage (0 of 5), subject and tenant isolation (0 cross hits), deletion and
subject erasure (0 remaining, including both cached vectors per round), stale facts (0%),
validity windows, dedup, audit hash chain, and deterministic recall.

## Reproduce

```bash
memhouse up
memhouse bench download longmemeval-s
memhouse bench run --dataset longmemeval-s --embedding-model bge-small-en-v1.5-onnx-Q --label full-v7
memhouse bench run --dataset locomo --embedding-model bge-small-en-v1.5-onnx-Q --label full-v7
memhouse bench run --dataset longmemeval-s --embedding-model bge-small-en-v1.5-onnx-Q --no-analysis --label full-v7-noanalysis
memhouse bench download longmemeval-m && memhouse bench run --dataset longmemeval-m --stride 10 --embedding-model bge-small-en-v1.5-onnx-Q --label m50-v7
memhouse bench run --dataset longmemeval-s --types temporal-reasoning --window-weight 0.15 --window-top 3 --window-top-weight 1.0 --label tr-sweep
memhouse bench run --dataset longmemeval-s --stride 10 --mode dense --label s50-dense   # ablations
memhouse bench run --dataset longmemeval-s --stride 10 --rerank --label s50-rerank
memhouse bench run --suite governance
memhouse bench report bench-results/*                                                   # comparison table
```

Run directories for every number on this page are in `bench-results/` (summary and report;
per-question `items.jsonl` files are written locally but not committed).
