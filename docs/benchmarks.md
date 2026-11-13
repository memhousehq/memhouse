<!-- SPDX-License-Identifier: CC-BY-4.0 -->
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
has about 500 sessions (~1.5M tokens, ~2,450 rounds) of history instead of ~50. MemHouse ran
all 500 M questions (470 scored) with the default retrieval, no LLM anywhere:

| System | Split | session R@5 | session R@10 | session nDCG@10 | round R@5 | round R@10 |
|---|---|---|---|---|---|---|
| **MemHouse default (bge-small Q, no LLM)** | **M**, 470 q | 74.5 [70.4–78.3] | 84.7 [81.3–87.9] | **80.2** | 55.1 | 69.1 |
| Contriever + LLM-extracted fact keys (paper's best) | M | **76.2** | **86.2** | 65.8 | – | – |
| Stella V5 1.5B | M | 72.0 | 79.4 | 61.5 | **66.0** | **78.4** |
| Contriever | M | 72.3 | 82.3 | 66.3 | 58.9 | 74.7 |
| BM25 | M | 63.4 | 71.0 | 54.0 | 47.2 | 53.8 |
| MemHouse default | S, 470 q | 91.3 | 96.2 | 94.1 | 84.5 ⁴ | |

On the like-for-like split MemHouse's session recall is on par with the paper's best retriever
(1.5 points lower, inside the confidence interval) without its LLM key-extraction pass, and its
ranking is much better (nDCG@10 +14). At round level it trails the 1.5B-parameter Stella model
by 9–11 points; MemHouse uses a 33M-parameter quantized embedder on CPU. (An earlier 48-question
sample read 79.2 / 89.6 and overstated this.) M recall is p50 234 / p95 342 ms with about 5,000
vectors per subject, exact search.

⁴ round recall_all@10.

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

Recall is one batched query embedding plus one SQL statement: keyword search, vector search,
fusion, validity and governance filters, for every probe of the query together.

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
| LoCoMo multi-hop | 35.8 / 57.1 | Raw-round retrieval; with enrichment, QA on these is 80.9 (facts carry the links). |
| LoCoMo open-domain | 46.7 / 63.0 | Answers depend on world knowledge plus a hint in the dialogue (QA 69.8 with enrichment). |
| LongMemEval_M round level | 55.1 / 69.1 | 33M-parameter embedder vs 1.5B for the best published retriever. |
| LongMemEval temporal-reasoning | 83.5 / 91.3 | Mostly the labelling effect described above; the remaining misses need event-relative dates ("two weeks before the trip"), which the parser does not resolve. |

Next steps on these slices: event-anchored dates (find the anchor event, then window around
it) and entity-linked expansion for multi-hop questions.

## Answer accuracy (QA)

End-to-end protocol: MemHouse recalls memories, an LLM answers from them, and an LLM judge grades
the answer with each benchmark's published judging prompt. Models are called through OpenRouter;
tokens and cost are the provider's own figures, recorded per call in `items.jsonl` and totalled
in `report.md`.

### Current results: async enrichment + answer prompt v2

| Dataset | Answer / judge model | Questions | **Accuracy** | Enrichment cost | QA cost |
|---|---|---|---|---|---|
| LongMemEval_S | gpt-4o / gpt-4o | 500 | **86.0** [83.0–88.8] | **$1.54** (21,002 sessions) | $7.33 |
| LoCoMo (categories 1–4) | gpt-4o-mini / gpt-4o-mini | 1,540 | **83.7** [81.8–85.5] | **$0.03** (272 sessions) | $0.70 |

Both rows use the same final configuration. Enrichment cost is paid once: the reruns read every
extraction from the cache (LongMemEval_S rerun: 9 new LLM calls, $0.001).

What changed against the first QA runs (77.0 and 68.4):

1. **Asynchronous enrichment** ([architecture](architecture.md#enrichment-asynchronous-llm-fact-extraction-optional)):
   every ingested session is queued; `qwen/qwen3.7-flash` extracts short, dated facts in the
   background (**$0.000073 per session**, 2,341 ms p50 per call, facts searchable p50 18 s after
   ingest). 110k facts for LongMemEval_S. Recall never waits: 500 recalls made while 23,768 jobs
   were still queued took 42 ms p50.
2. **Answer context:** the 10 best conversation rounds plus the 50 best facts (a facts-only
   recall), and the dates recall resolved for the question's time phrases ("last Saturday" =
   2023-04-15).
3. **Answer prompt v2:** guidance for time arithmetic, counting across sessions, personalised
   advice, and a premise check: every specific thing the question names (item, place, employer,
   job title, second item in "A and B") must be in the memories, otherwise the answer is "not
   enough information". That check took abstention from 53.3 to 83.3 (run `final-lme-s-v3`;
   the run before it, without the check, scored 83.2 overall).

Published results with the same answer model (vendor-reported unless noted):

| LongMemEval_S, GPT-4o | Accuracy |
|---|---|
| Full context, no memory system (Zep paper) | 60.2 |
| Zep | 71.2 |
| Bedrock AgentCore memory (Redis re-run) | 77.0 |
| Emergence fast (Redis re-run) | 81.3 |
| Supermemory | 81.6 |
| Hindsight (GPT-OSS-20B answer, -120B judge) | 83.6 |
| Mastra Observational Memory (Redis reproduced) | 84.2 |
| **MemHouse** | **86.0** |

| LoCoMo, GPT-4o-mini | Accuracy |
|---|---|
| Mem0 (2025 paper) | 66.9 |
| Full context (Mem0 paper) | 72.9 |
| Letta filesystem | 74.0 |
| Zep (vendor; Mem0 measured 66.0) | 75.1 |
| MemOS | 75.8 |
| Hindsight (GPT-OSS-20B / -120B) | 83.2 |
| **MemHouse** | **83.7** |
| EverMemOS (GPT-4.1-mini) | 92.3 |

On LongMemEval_S MemHouse scores above every published GPT-4o result we know of, including
Mastra (84.2, inside our 95% interval of 83.0–88.8) and Supermemory (81.6, below it). On LoCoMo
it is ahead of every published GPT-4o-mini result; Hindsight's 83.2 used other models, and
EverMemOS reports 92.3 with the stronger GPT-4.1-mini. All vendor numbers are self-reported
except where a re-run is noted.

By question type, first run → current:

| LongMemEval_S | n | first run | **now** |
|---|---|---|---|
| single-session-user | 64 | 96.9 | 96.9 |
| knowledge-update | 72 | 87.5 | 90.3 |
| single-session-assistant | 56 | 85.7 | 89.3 |
| **temporal-reasoning** | 127 | 80.3 | **89.0** |
| abstention | 30 | 76.7 | 83.3 |
| multi-session | 121 | 62.0 | 78.5 |
| single-session-preference | 30 | 40.0 | 66.7 |

| LoCoMo | n | first run | **now** |
|---|---|---|---|
| single-hop | 841 | 77.1 | 90.2 |
| multi-hop | 282 | 59.6 | 79.8 |
| **temporal** | 321 | 60.7 | 75.1 |
| open-domain | 92 | 43.8 | 66.7 |

Temporal questions, the original weak spot, are now the third-best LongMemEval type. The
weakest remaining slices are personalised advice (preference, 66.7; it was 80.0 before the
premise check made the model more cautious) and LoCoMo temporal and open-domain questions.

### First QA runs (no enrichment, answer prompt v1)

| Dataset | Answer / judge model | Accuracy | Tokens (prompt + completion) | Cost |
|---|---|---|---|---|
| LongMemEval_S | gpt-4o / gpt-4o | 77.0 [73.4–80.8] | 1.72M + 22k | $4.52 |
| LoCoMo | gpt-4o-mini / gpt-4o-mini | 68.4 [66.0–70.8] | 1.16M + 34k | $0.19 |

### Latency with and without the external LLM call

| p50 / p95 | LongMemEval_S | LoCoMo |
|---|---|---|
| Memory recall only (local) | 27 / 40 ms | 109 / 127 ms ³ |
| Answer-model call alone (OpenRouter) | 1,260 / 2,317 ms | 1,494 / 2,653 ms |
| Recall + answer (what an agent waits for) | 1,289 / 2,345 ms | 1,595 / 2,736 ms |

Memory is about 3–8% of what an agent waits for; the rest is the LLM provider. The judge call is
benchmark-only and not included. Enrichment runs in the background and adds nothing here.

³ Recall during the QA run shares the CPU with ingest, fact embedding and 16 enrichment workers;
on an idle machine LoCoMo recall is 35 ms.

Reproduce (needs an OpenAI-compatible key, given for the run as shown in
[where benchmarks run](#where-benchmarks-run); `--max-cost-usd` stops a run that overspends):

```bash
memhouse bench run --dataset longmemeval-s --qa --enrich --llm-base-url https://openrouter.ai/api/v1 \
  --answer-model openai/gpt-4o --judge-model openai/gpt-4o --enrich-max-cost-usd 2.5 --max-cost-usd 12
memhouse bench run --dataset locomo --qa --enrich --llm-base-url https://openrouter.ai/api/v1 \
  --answer-model openai/gpt-4o-mini --judge-model openai/gpt-4o-mini --enrich-max-cost-usd 0.3 --max-cost-usd 2
```

## Synthetic timeline suites

MemHouse's own suites: scripted conversations with ground truth at every checkpoint, replayed
through the real write and recall paths ([evaluation.md](evaluation.md)). They measure what the
public datasets can't: whether what should be stored is stored, whether a corrected fact still
comes back, and whether a plan is ever committed as a fact. No model is called except the local
embedder; a replay costs nothing.

13 November 2026, `bge-small-en-v1.5-onnx-Q`, rule classifier, default policy. Storage and
retrieval are precision / recall / **F1**, in percent.

| Suite | Conversations | Questions | Storage | Retrieval (top 5) | Stale facts returned | Contamination |
|---|---|---|---|---|---|---|
| `personal-starter` | 20 | 285 | 79.8 / 100.0 / **88.7** | 87.4 / 98.9 / **92.8** | 84.9 | 0.0 |
| `support-starter` | 20 | 271 | 68.1 / 100.0 / **81.0** | 61.6 / 99.3 / **76.0** | 91.5 | 0.0 |
| `coding-starter` | 20 | 270 | 69.5 / 100.0 / **82.0** | 74.8 / 100.0 / **85.6** | 75.5 | 0.0 |
| `sales-starter` | 20 | 279 | 69.9 / 100.0 / **82.3** | 67.4 / 100.0 / **80.5** | 85.8 | 0.0 |
| `success-starter` | 20 | 280 | 72.1 / 100.0 / **83.8** | 64.3 / 100.0 / **78.3** | 74.3 | 0.0 |
| reference: `bench synth --profile personal --seed 7 --conversations 500` | 500 | 7,196 | 76.7 / 100.0 / **86.8** [86.1–87.5] | 82.7 / 99.8 / **90.4** [89.4–91.4] | 76.2 [73.6–78.6] | 0.0 |

The reference suite has 8,511 turns and 10,289 facts at checkpoints; its replay took 8 minutes on a
laptop that was busy with other work. Brackets are 95% bootstrap intervals over conversations.

What they show:

- **Almost nothing that should be stored is lost**: storage recall is 99.98% on the reference
  suite (2 of 10,289 facts at checkpoints not stored) and 100% on the starter suites. Plans and
  guesses are held: none of the 4,399 on the reference suite was committed as a fact, and none
  on the starter suites. A plan that a later turn carries out is not counted, since the engine
  then rightly commits it.
- **Corrections are the weak point.** Three quarters or more of the questions about a
  corrected fact still get a stale version among the top 5, and storage precision is 68 to 80
  because those stale records are still current. A correction supersedes the record it
  corrects only when the two are close enough as vectors (`[intake] correction_threshold`,
  0.8), and sentences such as "I no longer live in Lisbon; I now live in Porto" are not that
  close to "I live in Lisbon" for this embedder. The public datasets did not show this: they
  have few explicit corrections. It is what the first quality goal (G14) tunes, on these
  suites.
- Retrieval finds the current fact almost always (recall 98.9 to 100); it is first less often
  where a stale version competes with it.

```bash
memhouse bench run --suite bench/suites --embedding-model bge-small-en-v1.5-onnx-Q
memhouse bench synth --profile personal --seed 7 --conversations 500 --out reference.yaml
memhouse bench run --suite reference.yaml --embedding-model bge-small-en-v1.5-onnx-Q
```

## Governance suite

`memhouse bench run --suite governance` runs 18 checks; all pass:
prompt-injection persistence (0 of 15 attempts committed or recalled), false quarantine (0%),
PII canaries in storage (0 of 5), subject and tenant isolation (0 cross hits), deletion and
subject erasure (0 remaining, including both cached vectors per round), stale facts (0%),
validity windows, dedup, audit hash chain, deterministic recall, and two checks on the
enrichment path with a stub model: recall works before enrichment, derived facts are redacted
and quarantined like any write, and deleting a round removes its facts and cached extraction. A retention check confirms that
purging old rounds also removes the facts, jobs and cached extractions derived from them. Three
checks guard the recall statement: its plan never reads outside the subject, vector top-K equals
brute force, and seeded random sequences of writes, revisions and deletions stay consistent with a
reference model.

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

## Datasets and models: where they come from and their licences

Nothing below is committed to this repository. `memhouse bench download` (or the first run)
fetches each dataset from its source into `$MEMHOUSE_HOME/bench-data`, and the embedding and
reranking models into `$MEMHOUSE_HOME/models`. The result directories in `bench-results/` hold
metrics only: no conversation, question or answer text.

| Asset | Source | Licence | Used for |
|---|---|---|---|
| LongMemEval (`longmemeval-s`, `-m`, oracle; cleaned release) | [xiaowu0162/longmemeval-cleaned](https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned) on Hugging Face; paper and code at [xiaowu0162/LongMemEval](https://github.com/xiaowu0162/LongMemEval) | MIT | retrieval and QA benchmarks, the T1 guard |
| LoCoMo (`locomo10.json`) | [snap-research/locomo](https://github.com/snap-research/locomo) | CC BY-NC 4.0 (non-commercial) | retrieval and QA benchmarks, the local T1 guard |
| bge-small-en-v1.5 (default embedding model) | [BAAI/bge-small-en-v1.5](https://huggingface.co/BAAI/bge-small-en-v1.5), ONNX build [Xenova/bge-small-en-v1.5](https://huggingface.co/Xenova/bge-small-en-v1.5), run with fastembed | MIT | embeddings |
| jina-reranker-v1-turbo-en (optional reranker) | [jinaai/jina-reranker-v1-turbo-en](https://huggingface.co/jinaai/jina-reranker-v1-turbo-en), downloaded on first use of `--rerank` | Apache-2.0 | reranking ablations |

LoCoMo's licence allows non-commercial use only. Download it yourself and make sure your use
complies; MemHouse never redistributes it. Its role in the project's own benchmarking is reviewed
with counsel before publication (roadmap G09).

## Where benchmarks run

On a maintainer's machine, on demand. Hosted CI runs none: it holds no datasets and no keys (its
end-to-end job runs the governance suite, which uses synthetic data). Every published number
comes with the command that produced it and its `bench-results/` directory, so anyone can rerun it.

Paid tiers need an OpenAI-compatible key for that one run. Give it as the environment variable the
run names (`--llm-key-env`, default `OPENAI_API_KEY`), never as a command-line argument, which
would land in the shell history and the process list:

```bash
read -rs OPENAI_API_KEY && export OPENAI_API_KEY   # typed, not echoed
memhouse bench guard --tier 2
unset OPENAI_API_KEY
# or, from a password manager:
op run --env-file=.env.example -- memhouse bench run --dataset locomo --qa --max-cost-usd 2
```

Always pass `--max-cost-usd` to runs that call a paid model.
