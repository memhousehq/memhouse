# MemHouse

Open-source, governed memory for AI agents. Rust + Postgres.

MemHouse gives agents persistent memory with an owner, a source and an expiry for every item.
It runs on your laptop in one command, connects to the agents you already use over MCP, and
ships with its own benchmark and validation tool so you can check its quality, safety and speed yourself.

```bash
memhouse up                      # Postgres + pgvector in Docker, config, local embedding model
memhouse connect claude-code     # or cursor, claude-desktop, vscode, windsurf, codex, gemini, all
```

That's the whole setup. There are no API keys to obtain and no cloud account. Embeddings run locally on CPU.

---

## Why MemHouse

| | |
|---|---|
| **Easy** | One binary. `memhouse up` starts a managed Postgres in Docker, writes `~/.memhouse/config.toml`, downloads a small local embedding model and migrates the schema (about 15 seconds on a laptop). `memhouse connect <agent>` writes the agent's MCP config and verifies a real recall through it. |
| **Governed** | Every write passes a deterministic write gate: secrets, card numbers, SSNs and IBANs are redacted before storage. Prompt-injection attempts are quarantined, never recalled. Writes, updates and deletions go into a hash-chained, tamper-evident audit log. Deletion removes the record, its cached embedding and every recall path, and is recorded in a deletion ledger. |
| **Measurable** | `memhouse bench` runs LongMemEval and LoCoMo through the same engine your agents use, plus 12 governance gates. It reports confidence intervals, latency percentiles and published reference results side by side. |
| **Yours** | Plain Postgres (16+) with pgvector. Point it at your own database with `memhouse init --database-url ...`. Export everything as JSONL at any time. |
| **Made for customer-facing teams** | Templates for `support`, `sales` and `success` (plus `coding` and `personal`) set how subjects are named, what gets remembered and how the agent is instructed. |

## Install

Build from source (Rust 1.85+):

```bash
cargo install --path crates/memhouse-cli
```

Docker is needed only for `memhouse up`. With your own Postgres, use `memhouse init --database-url postgres://...` instead.

## Use it from an agent (MCP)

`memhouse connect` supports:

| Agent | Command | What it writes |
|---|---|---|
| Claude Code | `memhouse connect claude-code` | `claude mcp add --scope user memhouse ...` (`--project` writes `.mcp.json` scope) |
| Claude Desktop | `memhouse connect claude-desktop` | `claude_desktop_config.json` |
| Cursor | `memhouse connect cursor` | `~/.cursor/mcp.json` (`--project`: `.cursor/mcp.json`) |
| VS Code (Copilot agent mode) | `memhouse connect vscode` | `.vscode/mcp.json` |
| Windsurf | `memhouse connect windsurf` | `~/.codeium/windsurf/mcp_config.json` |
| OpenAI Codex CLI | `memhouse connect codex` | `~/.codex/config.toml` |
| Gemini CLI | `memhouse connect gemini` | `~/.gemini/settings.json` |
| Zed, Goose | `memhouse connect zed` / `goose` | prints the snippet |
| Any HTTP MCP client (OpenAI Agents SDK, LangGraph, n8n…) | `memhouse connect http` | prints URL + bearer key for `memhouse serve` |

Existing config files are backed up (`*.memhouse.bak`) before they are changed. Files that aren't plain JSON are never modified; the snippet is printed instead. Add `--print` to see what would be written, and `--subject repo:myapp` to give an agent its own default subject.

Tools exposed to the agent:

| Tool | Purpose |
|---|---|
| `memory_recall` | Hybrid search over a subject's memory (filters: kinds, tags, `as_of`) |
| `memory_remember` | Store one durable fact, preference, procedure, decision or commitment |
| `memory_update` | Supersede a memory that changed; the old version is kept for audit, not recalled |
| `memory_forget` | Delete a memory permanently |
| `memory_log_conversation` | Save conversation turns as episodic memory |
| `memory_list` | Most recent memories of a subject |

The MCP `instructions` field tells the agent how to use memory for the active template.

## Use it from code (REST)

```bash
memhouse serve                                   # http://127.0.0.1:7077, Memory Browser at /
KEY=$(memhouse key)
curl -s localhost:7077/v1/memories -H "authorization: Bearer $KEY" -H "content-type: application/json" \
  -d '{"subject":"customer:acme","content":"Acme is on the Enterprise plan; renewal due 2027-03-01","kind":"semantic","tags":["plan"]}'
curl -s localhost:7077/v1/recall -H "authorization: Bearer $KEY" -H "content-type: application/json" \
  -d '{"subject":"customer:acme","query":"when does Acme renew?"}'
```

| Method | Path | |
|---|---|---|
| POST | `/v1/memories` | remember |
| GET | `/v1/memories?subject=&kind=&limit=&all=` | list |
| GET / PATCH / DELETE | `/v1/memories/{id}` | get, supersede with new content, delete |
| POST | `/v1/ingest` | store a conversation (`messages: [{role, content, timestamp?}]`) |
| POST | `/v1/recall` | hybrid recall (`query, k, kinds, tags, as_of, reference_time, mode, rerank, analyze, token_budget`) |
| GET | `/v1/subjects`, `/v1/stats`, `/v1/audit` | browse and operate |
| DELETE | `/v1/subjects/{subject}` | erase everything about a subject |
| POST | `/mcp` | MCP over streamable HTTP |

## How it works

```
agent ──MCP/REST──▶ memhouse (Rust)
                      │ write gate: redact PII & secrets → injection screen → dedup
                      │ local embedding (ONNX, CPU) with content-addressed cache
                      ▼
                   Postgres + pgvector
                      one SQL statement per probe:
                      BM25 full-text       ┐
                                           ├─ reciprocal rank fusion → (optional cross-encoder rerank)
                      exact vector scan    ┘   → validity / as-of filter → token-budget packing
                      (per subject, no ANN index: exact top-k)
```

- **Date-aware recall (no LLM):** recall reads time expressions ("two weeks ago", "last
  Saturday", "in February", "the past three months", "June 3rd") relative to `reference_time`,
  `as_of` or now, and runs the query a second time restricted to that window. The two ranked
  lists are fused, so in-window memories rise without hiding the rest (people often mention an
  event days after it happened). The result's `plan` field shows the windows it read; turn it
  off with `analyze: false` or `[memory] query_analysis = false`.
- **Two vectors per conversation round:** the whole round, and the user's own words alone, so a
  fact mentioned in passing is not drowned out by a long assistant reply. Keyword search is BM25.

- **Memory kinds:** `episodic` (conversation rounds), `semantic`, `preference`, `procedural`, `commitment`, `document`.
- **Subjects** partition memory (a user, customer, account or repository). Recall never crosses subjects or tenants. The governance suite checks this on every run.
- **Time:** every record has an event time (`occurred_at`) and a validity window. `as_of` recall answers "what did we know then"; expired memories drop out of recall automatically.
- **Supersession:** `memory_update` replaces a fact without losing history.

## Benchmark and validate (`memhouse bench`)

The validation tool is part of the binary. It drives the real engine through its public API and writes `bench-results/<run>/{summary.json,report.md,items.jsonl}`.

```bash
memhouse bench list
memhouse bench run --suite governance                       # 12 deterministic safety gates
memhouse bench download longmemeval-s                       # also: longmemeval-m, longmemeval-oracle, locomo
memhouse bench run --dataset longmemeval-s                  # retrieval quality + latency, all 500 questions
memhouse bench run --dataset longmemeval-s --stride 10      # 50-question stratified sample
memhouse bench run --dataset locomo --mode keyword          # ablations: hybrid | dense | keyword, --rerank
memhouse bench run --dataset longmemeval-s --qa \
  --answer-model gpt-4o-mini --judge-model gpt-4o \
  --max-cost-usd 5                                         # end-to-end QA accuracy with an LLM judge; records tokens and cost
memhouse bench report bench-results/*                       # compare runs side by side
```

- **Retrieval metrics** follow the LongMemEval reference code exactly: `recall_any@k`, `recall_all@k` and `nDCG@k`, at session level and at round level. Abstention and adversarial questions aren't scored for retrieval.
- **Every metric has a 95% bootstrap confidence interval** with a fixed seed.
- **QA mode** works with any OpenAI-compatible endpoint (OpenAI, Ollama, vLLM, LM Studio, OpenRouter) or Anthropic. The judge prompts follow each benchmark's published protocol, per question type. Each QA report records tokens and cost per role (the provider's reported cost on OpenRouter, else list price × tokens), LLM call latency, and latency with and without the external call; `--max-cost-usd` stops a run that overspends.
- **Isolation:** benchmark data goes to its own database per embedding model (`memhouse_bench_*`) and never mixes with your memories.
- **Governance gates:** injection persistence, false quarantine rate, PII and secret redaction (random canaries), subject and tenant isolation, deletion (record + cached vector + recall + audit), subject erasure, stale-fact rate after updates, validity windows, dedup, audit-chain integrity and embedding determinism.

Current results on a laptop CPU, no LLM in the loop (details and baselines in [docs/benchmarks.md](docs/benchmarks.md)):

| Dataset | session recall_all@5 | session recall_all@10 | session nDCG@10 | recall p50 / p95 |
|---|---|---|---|---|
| LongMemEval_S (470 scored) | 91.3 | 96.2 | 94.1 | 26 / 37 ms |
| LoCoMo (1,536 scored) | 78.8 | 87.5 | 78.6 | 35 / 42 ms |

On the harder 500-session LongMemEval_M split (all 500 questions) MemHouse scores 74.5 / 84.7 / 80.2, against 76.2 / 86.2 / 65.8 for the best retriever in the LongMemEval paper (Contriever + LLM-extracted keys): on par for recall, ahead on ranking.

End-to-end answer accuracy with an LLM judge, with asynchronous enrichment on:

| Benchmark | Answer model | MemHouse | Published (same answer model) | Enrichment cost |
|---|---|---|---|---|
| LongMemEval_S, 500 q | GPT-4o | **83.2** | Mastra 84.2, Supermemory 81.6, Emergence 81.3, Zep 71.2 | $1.54 for 21k sessions |
| LoCoMo, 1,540 q | GPT-4o-mini | **84.5** | Hindsight 83.2 (other models), MemOS 75.8, Zep 75.1, Letta 74.0, Mem0 66.9 | $0.03 |

Enrichment is optional and asynchronous: ingest stores rounds and queues a job; background workers ask a small model (`qwen/qwen3.7-flash`, ~$0.00007 per session) for dated facts, which pass the same write gate. Recall never waits for it. Every QA report records tokens, cost and latency with and without the LLM call.

## Configuration

`~/.memhouse/config.toml` (override the path with `MEMHOUSE_CONFIG`, the directory with `MEMHOUSE_HOME`). Every key can also be set through the environment (`MEMHOUSE_DATABASE_URL`, `MEMHOUSE_SUBJECT`, `MEMHOUSE_EMBEDDING_MODEL`, `MEMHOUSE_RERANK=1`, …).

```toml
[embedding]
provider = "local"               # or "openai" for any OpenAI-compatible /embeddings endpoint (OpenAI, Ollama, vLLM)
model = "bge-small-en-v1.5"      # dimension is fixed per database
[rerank]
enabled = false                  # cross-encoder reranking (jina-reranker-v1-turbo-en, top 20): better ordering, ~+0.9 s per recall on CPU
[memory]
template = "support"             # personal | coding | support | sales | success
default_subject = "customer:unknown"
query_analysis = true            # date-aware recall: time-window probe (window_weight = 0.15, window_top = 3, window_top_weight = 1.0)
[enrich]
enabled = false                  # async LLM fact extraction: ingest queues a job, workers add dated facts (~$0.00007 per session)
workers = 8
llm = { base_url = "https://openrouter.ai/api/v1", model = "qwen/qwen3.7-flash", api_key_env = "OPENAI_API_KEY" }
max_cost_usd = 0.0               # stop calling the LLM after this much spend per process (0 = no limit)
[governance]
redact = ["secret", "card", "ssn", "iban"]   # also: email, phone, ip
quarantine_injection = true
episodic_retention_days = 0      # 0 = keep
audit_reads = false              # audit every recall too
```

## Operating it

```bash
memhouse doctor                  # config, container, database, model, audit chain, MCP round-trip
memhouse audit --verify          # verify the hash chain
memhouse export -o backup.jsonl  # canonical JSONL (MemHouse Memory Format v1)
memhouse import backup.jsonl
memhouse forget --subject customer:acme   # right to be forgotten
memhouse down                    # stop the container; data stays in the Docker volume
```

## Repository layout

| Crate | Role |
|---|---|
| `memhouse-core` | Engine: types, config, write gate, ranking, templates, adapter traits |
| `memhouse-store-postgres` | Postgres adapter: schema, single-statement hybrid recall, audit chain, deletion ledger |
| `memhouse-models` | Local ONNX embedder and reranker, OpenAI-compatible embeddings, chat client for the benchmark |
| `memhouse-server` | REST API, MCP (stdio + HTTP), Memory Browser |
| `memhouse-bench` | Datasets, runner, metrics, governance suite, reports |
| `memhouse-cli` | The `memhouse` binary |

Design documents are in [`draft_plan/`](draft_plan/).

## Licence

Apache-2.0.
