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
analysis (time-window probe, weight 0.3), no reranker.

| Dataset | Questions scored | session recall_any@5 | session recall_all@5 | session recall_all@10 | session nDCG@10 | round recall_all@10 | recall p50 / p95 |
|---|---|---|---|---|---|---|---|
| LongMemEval_S (500 q, ~50 sessions each) | 470 | 98.9 | **90.4** | **95.7** | **93.8** | 84.5 | 64 / 91 ms ¹ |
| LoCoMo (10 conversations, 1,540 q) | 1,536 | 90.2 | **79.0** | **87.9** | **78.7** | 59.3 | 43 / 57 ms |

¹ Measured while four ingest workers were embedding on the same CPU. With ingest finished,
LongMemEval_S recall is 26 / 37 ms (the `full-v5-noanalysis` run, which re-used cached vectors).

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
| knowledge-update | 72 | 97.2 | 100.0 |
| multi-session | 121 | 85.1 | 94.2 |
| temporal-reasoning | 127 | 81.9 | 89.8 |

| LoCoMo | n | recall_all@5 | recall_all@10 |
|---|---|---|---|
| single-hop | 841 | 93.8 | 98.1 |
| temporal | 321 | 86.9 | 95.0 |
| open-domain | 92 | 47.8 | 64.1 |
| multi-hop | 282 | 35.8 | 57.1 |

### Against published retrieval baselines

The LongMemEval paper (Table 9) reports retrievers on **LongMemEval_M**, the 500-session
variant of each question. Our numbers are on **LongMemEval_S**, the ~50-session variant the
memory vendors use for their QA results. **The comparison favours MemHouse**; M is the
like-for-like split (`memhouse bench run --dataset longmemeval-m`) and has not been run yet.

| System | Split | session R@5 | session R@10 | session nDCG@10 |
|---|---|---|---|---|
| **MemHouse default (bge-small Q, no LLM)** | S | **90.4** | **95.7** | **93.8** |
| Contriever + LLM-extracted fact keys | M | 76.2 | 86.2 | 65.8 |
| Stella V5 1.5B | M | 72.0 | 79.4 | 61.5 |
| Contriever | M | 72.3 | 82.3 | 66.3 |
| BM25 | M | 63.4 | 71.0 | 54.0 |

Memory vendors (Mem0, Zep, Supermemory, Mastra) publish answer accuracy, not retrieval recall,
so there is no direct retrieval number to compare against; see [Answer accuracy](#answer-accuracy-qa).

### What changed since the first full run

| | LongMemEval_S R_all@5 / @10 / nDCG@10 | LoCoMo R_all@5 / @10 / nDCG@10 |
|---|---|---|
| First full run (`full-q-hybrid`) | 81.1 / 86.4 / 85.8 | 73.6 / 84.4 / 71.7 |
| Current default (`full-v5`) | **90.4 / 95.7 / 93.8** | **79.0 / 87.9 / 78.7** |

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
time-window probe next to the main one. The two result lists are fused with weighted RRF
(window weight 0.3), so the window boosts in-range memories without hiding the rest. No LLM is
involved; the parser is a set of regular expressions (`crates/memhouse-core/src/query.rs`).

Effect on the full datasets (on vs `--no-analysis`):

| | R_any@5 | R_all@5 | R_all@10 | nDCG@10 | round R_all@10 |
|---|---|---|---|---|---|
| LoCoMo, analysis on | **90.2** | **79.0** | **87.9** | **78.7** | **59.3** |
| LoCoMo, off | 88.2 | 76.8 | 86.5 | 76.0 | 58.3 |
| LoCoMo temporal, on / off | | 86.9 / 84.4 | 95.0 / 92.5 | | |
| LongMemEval_S, analysis on | **98.9** | 90.4 | 95.7 | 93.8 | **84.5** |
| LongMemEval_S, off | 98.3 | **91.3** | **96.0** | **94.0** | 84.0 |

On LoCoMo the window probe improves every metric (+2.2 R_all@5, +2.5 on temporal questions).
On LongMemEval_S it finds more first hits and exact rounds but loses about one point of strict
recall_all, which is inside the confidence interval. The reason is the dataset's labelling:
for questions such as "how many weeks ago did I start the course", LongMemEval also lists
same-topic sessions from *other* dates as evidence, and the window, correctly, ranks those
lower. On the 127 temporal-reasoning questions:

| Temporal subset (127 q) | R_any@5 | R_all@5 | R_all@10 | nDCG@10 | round R_all@10 | round nDCG@10 |
|---|---|---|---|---|---|---|
| no analysis | 96.1 | **83.5** | **90.6** | 89.8 | 79.5 | 67.6 |
| window weight 1.0 | **98.4** | 81.1 | 85.0 | 88.6 | **84.3** | **69.9** |
| **window weight 0.3 (default)** | **98.4** | 81.9 | 89.8 | **90.0** | 83.5 | 69.5 |
| window 0.5 | **98.4** | 81.1 | 87.4 | 89.6 | 83.5 | 70.0 |
| sub-queries only (split "X or Y" comparisons) | 96.1 | 81.9 | 91.3 | 88.5 | 70.9 | 62.6 |

Weight 0.3 keeps most of the round-level gain (+4 points: the exact evidence turns reach the
agent) at the smallest cost in session recall_all. Comparison sub-queries added noise and are
off by default (`subquery_weight = 0`). Turn the analysis off with `query_analysis = false` or
per request with `"analyze": false`.

### Latency

Recall is one batched query embedding plus one SQL statement per probe (keyword search, vector
search, fusion, validity and governance filters together); probes run concurrently.

| | p50 | p95 | p99 |
|---|---|---|---|
| End-to-end recall, LongMemEval_S, during ingest | 64 ms | 91 ms | 102 ms |
| — SQL hybrid search in Postgres | 26 ms | 37 ms | 45 ms |
| — query embedding on CPU | 38 ms | 59 ms | – |
| End-to-end recall, LongMemEval_S, idle CPU, no analysis | 26 ms | 37 ms | – |
| End-to-end recall, LoCoMo | 43 ms | 57 ms | 64 ms |
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
| LoCoMo open-domain | 47.8 / 64.1 | Answers depend on world knowledge plus a hint in the dialogue. |
| LongMemEval temporal-reasoning | 81.9 / 89.8 | Mostly the labelling effect described above; the remaining misses need event-relative dates ("two weeks before the trip"), which the parser does not resolve. |

Next steps on these slices: event-anchored dates (find the anchor event, then window around
it) and entity-linked expansion for multi-hop questions.

## Answer accuracy (QA)

Vendors report end-to-end answer accuracy with an LLM answering from retrieved memories and an
LLM judge (LongMemEval_S: Zep 71.2, Supermemory 81.6, Mastra 84.2; LoCoMo: Mem0 66.9, Zep
75.1; all self-reported, different models). `memhouse bench run --qa` runs the same protocol
with the official LongMemEval and LoCoMo judge prompts against any OpenAI-compatible or
Anthropic endpoint. **These results have not been run yet** because no LLM endpoint was
configured on the benchmark machine; the retrieval numbers above are what feeds the answer
model, and retrieval recall at k=10 is the ceiling for answer accuracy on evidence questions.

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
memhouse bench run --dataset longmemeval-s --embedding-model bge-small-en-v1.5-onnx-Q --label full-v5
memhouse bench run --dataset locomo --embedding-model bge-small-en-v1.5-onnx-Q --label full-v5
memhouse bench run --dataset longmemeval-s --embedding-model bge-small-en-v1.5-onnx-Q --no-analysis --label full-v5-noanalysis
memhouse bench run --dataset longmemeval-s --types temporal-reasoning --window-weight 1.0 --label tr-w10
memhouse bench run --dataset longmemeval-s --stride 10 --mode dense --label s50-dense   # ablations
memhouse bench run --dataset longmemeval-s --stride 10 --rerank --label s50-rerank
memhouse bench run --suite governance
memhouse bench report bench-results/*                                                   # comparison table
```

Run directories for every number on this page are in `bench-results/` (summary and report;
per-question `items.jsonl` files are written locally but not committed).
