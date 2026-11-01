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

| Dataset | Questions scored | session recall_all@5 | session recall_all@10 | session nDCG@10 | round recall_all@10 | recall p50 / p95 |
|---|---|---|---|---|---|---|
| LongMemEval_S (500 q, ~50 sessions each) | 470 | **81.1** [77.0–84.5] | **86.4** [83.0–89.4] | 85.8 | 69.6 | **56 / 82 ms** |
| LoCoMo (10 conversations, 1,540 q) | 1,536 | **73.6** [71.3–75.7] | **84.4** [82.6–86.2] | 71.7 | 54.7 | **55 / 76 ms** |

Brackets are 95% bootstrap confidence intervals. LongMemEval abstention questions (`_abs`) and
LoCoMo adversarial questions (category 5) have no evidence and are not scored for retrieval.
*recall_all@k* is the stricter definition: every evidence session must be in the top k.

### Against published retrieval baselines

The LongMemEval paper (Table 9) reports retrievers on **LongMemEval_M**, the 500-session
variant of each question. Our numbers above are on **LongMemEval_S**, the ~50-session variant
the memory vendors use for their QA results. **The comparison favours MemHouse**; M is the
like-for-like split (`memhouse bench run --dataset longmemeval-m`) and has not been run yet.

| System | Split | session R@5 | session R@10 | session nDCG@10 |
|---|---|---|---|---|
| **MemHouse hybrid (bge-small Q, no LLM)** | S | **81.1** | **86.4** | **85.8** |
| **MemHouse hybrid + rerank** (50-q sample) | S | 80.4 | 82.6 | 90.6 |
| Contriever + LLM-extracted fact keys | M | 76.2 | 86.2 | 65.8 |
| Stella V5 1.5B | M | 72.0 | 79.4 | 61.5 |
| Contriever | M | 72.3 | 82.3 | 66.3 |
| BM25 | M | 63.4 | 71.0 | 54.0 |

### Latency

Recall is one query embedding plus one SQL statement (keyword search, vector search, fusion,
validity and governance filters together). Measured during the benchmark, i.e. while four
ingest workers were also embedding on the same CPU:

| | p50 | p95 | p99 |
|---|---|---|---|
| End-to-end recall, LongMemEval_S | 56 ms | 82 ms | 97 ms |
| — SQL hybrid search in Postgres | 19 ms | 31 ms | 34 ms |
| — query embedding on CPU | 38 ms | 56 ms | – |
| End-to-end recall, LoCoMo | 55 ms | 76 ms | 84 ms |
| Recall with cross-encoder rerank (top 20, 4 concurrent queries) | 2.6 s | 4.5 s | – |

For orientation, the Mem0 paper measured search latency on LoCoMo for hosted services
(network included): Mem0 148 / 200 ms, Zep 513 / 778 ms, LangMem 18 s / 60 s (p50 / p95).

Ingest ran at 28 rounds/s (LongMemEval_S, 124k rounds) to 103 rounds/s (LoCoMo) with
4 workers on CPU; ingest never calls an LLM.

## Ablations (50 LongMemEval_S questions, `--stride 10`)

| Mode | session R_any@5 | session R_all@5 | session nDCG@10 | round nDCG@10 | recall p50 |
|---|---|---|---|---|---|
| keyword only | 95.7 | 63.0 | 75.3 | 53.4 | 9 ms |
| dense only | 95.7 | 80.4 | 85.9 | 62.0 | 57 ms |
| **hybrid (default)** | 95.7 | 80.4 | 86.8 | 66.1 | 60 ms |
| hybrid + rerank, bge-reranker-base top 40 | 95.7 | 78.3 | 89.3 | 73.7 | 221 s ¹ |
| hybrid + rerank, jina-reranker-v1-turbo-en top 20 | 97.8 | 80.4 | 90.6 | 73.9 | 2.6 s |

¹ Before length-batched reranking; unusable on CPU, kept for the record.

Findings:
- Hybrid matches dense on session recall and ranks the exact evidence turns better
  (round nDCG 66.1 vs 62.0). Keyword-only is 6x faster but misses multi-session evidence.
- The cross-encoder mainly improves *ordering* (round nDCG +8 points). It is opt-in
  (`[rerank] enabled = true`) because it costs about a second per recall on CPU.

## Where it is weak

| Slice | session R_all@5 | Why |
|---|---|---|
| LongMemEval temporal-reasoning | 52.8 | Questions like "what did I do two weeks before the trip" need date-aware retrieval; MemHouse currently filters by time only when the caller passes `as_of`. |
| LoCoMo multi-hop | 30.5 (52.8 @10) | Evidence spread over several sessions with little lexical overlap with the question. |
| LoCoMo open-domain | 46.7 | Answers depend on world knowledge plus a hint in the dialogue. |

Strong slices: LongMemEval knowledge-update 95.8, single-session-user 98.4,
single-session-assistant 100; LoCoMo single-hop 88.0, temporal 81.3.

Planned work on these slices: query-time date resolution ("last month", "before the trip")
into validity windows, and multi-query expansion for multi-hop questions.

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
subject erasure (0 remaining, including cached vectors), stale facts (0%), validity windows,
dedup, audit hash chain, and deterministic recall.

## Reproduce

```bash
memhouse up
memhouse bench download longmemeval-s
memhouse bench run --dataset longmemeval-s --embedding-model bge-small-en-v1.5-onnx-Q --label full-q-hybrid
memhouse bench run --dataset locomo --embedding-model bge-small-en-v1.5-onnx-Q --label full-q-hybrid
memhouse bench run --dataset longmemeval-s --stride 10 --mode dense --label s50-dense   # ablations
memhouse bench run --dataset longmemeval-s --stride 10 --rerank --label s50-rerank
memhouse bench run --suite governance
memhouse bench report bench-results/*                                                   # comparison table
```

Run directories for every number on this page are in `bench-results/` (summary and report;
per-question `items.jsonl` files are written locally but not committed).
