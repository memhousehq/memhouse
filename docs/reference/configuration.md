<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Configuration reference

Environment configuration is resolved at boot, never build time.

The annotated, complete example is
[`.env.example`](https://github.com/memhousehq/memhouse/blob/main/.env.example)
in the repository.

## Database

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_DATABASE_MODE` | `pg0` in a release | `pg0` (supervised) or `external` |
| `DATABASE_URL` | — | Required in external mode, e.g. `ecto://user:pass@host/db` |
| `POOL_SIZE` | `10` | Connection pool size |
| `MEMHOUSE_AUTO_MIGRATE` | `true` | Run migrations as a supervised startup step |
| `MEMHOUSE_PG0_BINARY` | packaged | Path to the pg0 binary |
| `MEMHOUSE_PG0_DATA_DIR` | under the data root | PostgreSQL data directory |
| `MEMHOUSE_PG0_PORT` | `5432` | Port the supervised server listens on |
| `MEMHOUSE_PG0_DATABASE` | `memhouse` | Database name |
| `MEMHOUSE_PG0_USERNAME` / `_PASSWORD` | `postgres` | Local credentials |
| `ECTO_IPV6` | `false` | Connect over IPv6 |
| `MEMHOUSE_DATABASE_APP_ROLE` | `memhouse_app` | Restricted PostgreSQL role every connection switches to |
| `MEMHOUSE_ALLOW_UNRESTRICTED_DATABASE_ROLE` | `false` | Boot anyway if that role can't be provisioned or reached |

External mode needs PostgreSQL 18 with pgvector available.

!!! danger "The connecting role must be able to reach a restricted role, or boot fails"
    PostgreSQL skips RLS for superusers and `BYPASSRLS` roles. MemHouse serves
    traffic only through a role that is neither:

    - Give `DATABASE_URL`'s role `CREATEROLE`, and MemHouse provisions
      `MEMHOUSE_DATABASE_APP_ROLE` itself on every boot (idempotent) and
      switches every pooled connection to it.
    - Or point `DATABASE_URL` at a login already created with `NOSUPERUSER
      NOBYPASSRLS` — the stronger arrangement, since that connection then has
      no path back to elevated access at all.

    `MEMHOUSE_ALLOW_UNRESTRICTED_DATABASE_ROLE=true` bypasses this guard and
    logs an error at every start. It exists only to avoid stranding an upgrade,
    not for supported operation.

## Identity and secrets

| Variable | Meaning |
| --- | --- |
| `MEMHOUSE_FREE_ACCOUNT_KEY` | Key of the single community Account |
| `MEMHOUSE_FREE_ACCOUNT_NAME` | Its display name |
| `MEMHOUSE_AUTH_SIGNING_SECRET` | At least 64 random bytes. **Independent of `SECRET_KEY_BASE`** |
| `SECRET_KEY_BASE` | Phoenix session and token signing |
| `MEMHOUSE_BOOTSTRAP_PASSWORD` | Read only by the one-time bootstrap task |
| `MEMHOUSE_DATA_ROOT` | Private data root; defaults to `~/.memhouse` in a release |

!!! danger "Generate independent production secrets"
    Do not reuse `SECRET_KEY_BASE` as the auth signing secret. The bootstrap
    password need not remain in the environment after the first run.

## Updates

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_UPDATE_CHECK` | `true` | Check the official signed release feed at boot and periodically. |
| `MEMHOUSE_AUTO_UPDATE` | `off` | `off` or `minor`; the latter permits an eligible signed patch/minor update before standalone pg0 startup. |
| `MEMHOUSE_UPDATE_CHECK_INTERVAL_HOURS` | `24` | Availability-check interval while the application runs. |
| `MEMHOUSE_UPDATE_INSTALL_ROOT` | launcher parent | Root holding the `current` pointer and immutable `releases/` directories. |
| `MEMHOUSE_UPDATE_SOURCE` | official GitHub API | Release discovery endpoint. Artifact trust still comes from the signed manifest. |

Updates never self-replace Docker or external-PostgreSQL deployments. Those
surfaces report the available version and retain their normal deployment flow.

## Generation models

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_MODEL_PROVIDER` | `openrouter` | Provider identity |
| `MEMHOUSE_OPENAI_COMPAT_BASE_URL` | provider default | Any OpenAI-compatible endpoint, including self-hosted |
| `OPENROUTER_API_KEY` | — | Provider credential |
| `MEMHOUSE_MODEL_VERSION` | `unversioned` | Recorded with every result as provenance |
| `MEMHOUSE_MODEL_INGEST` | — | Model for the ingest-extractor role |
| `MEMHOUSE_MODEL_DREAM` | — | Model for the dream-reasoner role |
| `MEMHOUSE_MODEL_ASK` | — | Model for the dialectic-agent role |
| `MEMHOUSE_MODEL_LOCAL_FALLBACK` | `true` in dev, off in prod | Deterministic local adapter |
| `MEMHOUSE_MODEL_REASONING_EFFORT` | `low` | Reasoning-token budget shared by all three generation roles |
| `MEMHOUSE_MODEL_MAX_TOKENS` | `8192` | Output-token cap shared by all three generation roles |
| `MEMHOUSE_MODEL_RECEIVE_TIMEOUT_MS` | `120000` | Maximum idle wait (ms) between response chunks |
| `MEMHOUSE_MODEL_REQUEST_TIMEOUT_MS` | `300000` | Total model-call ceiling (ms) shared by all three generation roles |
| `MEMHOUSE_MODEL_STREAM_POOL_SIZE` | `16` | Connections in each shared HTTP/1 shard |
| `MEMHOUSE_MODEL_STREAM_POOL_COUNT` | `1` | Shared HTTP/1 shard count; raise only for a measured shard bottleneck |
| `MEMHOUSE_MODEL_POOL_TIMEOUT_MS` | `120000` | Maximum wait (ms) to check out a model HTTP connection |
| `MEMHOUSE_INGEST_QUEUE_LIMIT` | `10` | Concurrent extraction jobs per node |
| `MEMHOUSE_EXPERIMENTAL_EXTRACTION_BATCHING` | `false` | Opt in to adjacent-anchor extraction; false preserves one provider request and replay outcome per message |
| `MEMHOUSE_EXTRACTION_BATCH_TARGET_TOKENS` | `4096` | Adjacent-anchor target when the experiment is enabled; one of `128`, `1024`, `4096`, or `16384` |
| `MEMHOUSE_EXTRACTION_BATCH_MAX_ANCHORS` | `32` | Hard anchor cap for one extraction call |
| `MEMHOUSE_MODEL_CONTEXT_LIMIT_TOKENS` | `131072` | Whole extraction request context limit used before a call |
| `MEMHOUSE_EXTRACTION_RESERVED_OUTPUT_TOKENS` | `8192` | Output capacity reserved during extraction admission |
| `MEMHOUSE_EXTRACTION_SAFETY_MARGIN_TOKENS` | `2048` | Extra whole-request admission margin |
| `MEMHOUSE_EXTRACTION_CLAIM_TIMEOUT_SECONDS` | `1200` | Age after which reconciliation releases an interrupted batch claim; when batching is enabled, boot requires at least three `MEMHOUSE_MODEL_REQUEST_TIMEOUT_MS` budgets plus 60 seconds |
| `MEMHOUSE_EXPERIMENTAL_COMPACT_EXTRACTION` | `false` | Selects the evaluation-only `compact-explicit-v1` extraction contract and `extract-compact-exp-1` prompt identity |
| `MEMHOUSE_CONTEXT_SUMMARY_CONCURRENCY` | `4` | Entity-card summary calls that overlap inside one scope rebuild |

`MEMHOUSE_EXPERIMENTAL_MINIMAL_RECALL` uses the same strict boolean boot
parsing as the experimental switches above: `true`, `false`, `1`, `0`, `yes`,
`no`, `on`, and `off` are accepted; ambiguous or misspelled values stop boot.

!!! warning "Reasoning models can blow the context window or time out without these"
    Reasoning models, including the default `openai/gpt-oss-120b`, can consume
    their context before producing output. `MEMHOUSE_MODEL_REASONING_EFFORT`
    bounds reasoning and `MEMHOUSE_MODEL_MAX_TOKENS` caps output. ReqLLM only
    extends timeouts automatically for recognized OpenAI reasoning families;
    `MEMHOUSE_MODEL_RECEIVE_TIMEOUT_MS` overrides its 30-second default for
    `openai/gpt-oss-120b` and other vendors. Raise these values only when the
    chosen model requires it.

`MEMHOUSE_MODEL_RECEIVE_TIMEOUT_MS` bounds the wait between response chunks.
`MEMHOUSE_MODEL_REQUEST_TIMEOUT_MS` bounds the complete response, even when a
provider continues sending chunks or keep-alives.

`MEMHOUSE_MODEL_STREAM_POOL_SIZE` must cover concurrent hosted model calls,
not just one role. Finch chooses a shard randomly when the count exceeds one,
so use `size` to add capacity and leave
`MEMHOUSE_MODEL_STREAM_POOL_COUNT=1` unless telemetry shows a single shard is
the bottleneck. `MEMHOUSE_MODEL_POOL_TIMEOUT_MS` is the maximum checkout wait
and defaults to the model receive timeout.

For 100 parallel ingestion flows on one node, set
`MEMHOUSE_INGEST_QUEUE_LIMIT=100` and
`MEMHOUSE_MODEL_STREAM_POOL_SIZE=128`, then validate the provider's
concurrency/rate limits and the database pool under representative load.

`MEMHOUSE_CONTEXT_SUMMARY_CONCURRENCY` bounds a different fan-out. Rebuilding
one scope's context needs a summary call for every entity cluster with enough
sources, and those calls run inside a single projection job. At `1` the rebuild
waits for the sum of them, so a scope holding a few slow calls can take tens of
minutes; higher values make it wait closer to the slowest call. The peak number
of calls in flight is this value times the projection queue limit, so raise
`MEMHOUSE_MODEL_STREAM_POOL_SIZE` with it. Each call also takes a database
connection while it resolves its model role and records usage, and an erasure
runs the same rebuild from inside its own transaction, so keep the value well
below `POOL_SIZE`.

### Experimental compact extraction

`MEMHOUSE_EXPERIMENTAL_COMPACT_EXTRACTION=true` replaces only the model-facing
candidate shape. The provider returns an atomic durable statement, an exact
supporting span, a subject reference, source-message ids, and nullable exact
source text for each valid-time boundary. Trusted code derives `fact`, direct
or indirect evidence, its confidence discount, `restricted` sensitivity, and
the narrow peer or current-scope target before applying the ordinary extraction
validator. It cannot make omitted policy fields public, Account-wide, or active.

The switch also selects prompt identity `extract-compact-exp-1`. An Account
with a persisted `ingest_extractor` role must publish a higher role-config
version carrying that exact prompt identity before enabling the switch. A
mismatch fails before the provider call and becomes operator-repairable; it
never records false provenance.

This is not a production default. ADR 0021 requires a preregistered matched
held-out report showing per-field and per-category non-inferiority, zero
privacy/attribution regressions, and lower calls, tokens, or cost, followed by
human architecture and licensing review. No paid or live run was performed as
part of the additive implementation. Disabling the flag immediately restores
`extract-14` and does not migrate or rewrite stored knowledge.

There are exactly five Account-level model roles: `embedder`, `reranker`,
`ingest_extractor`, `dream_reasoner`, and `dialectic_agent`. Only secret
*references* are persisted, never secret values.

When `MEMHOUSE_MODEL_PROVIDER=openrouter`, structured extraction and reasoning
use OpenRouter's strict JSON-schema response format. This is automatic; it
avoids models that intermittently ignore forced tool calls.

Reaching the same endpoint as `openai-compatible` plus a base URL does **not**
get that path automatically. The model identity is unknown to the client there,
so it falls back to a forced tool call that some models decline. Set the role
option `structured_output_mode` to `json_schema` for such a role. The value is
validated: anything else fails the call rather than reverting to tool calling.
`mix memhouse.model.check` reports which roles can actually return an object.

!!! warning "The local fallback is a test aid"
    Production defaults it off and never switches to it after a live provider
    error. A silent downgrade from a real model to a deterministic stand-in
    would corrupt memory quality invisibly.

## Embeddings

| Variable | Example | Meaning |
| --- | --- | --- |
| `MEMHOUSE_EMBEDDING_PROVIDER` | `ortex` | `ortex` (local ONNX) or `openai-compatible` |
| `MEMHOUSE_EMBEDDING_MODEL` | `Qwen/Qwen3-Embedding-0.6B` | Model identity |
| `MEMHOUSE_EMBEDDING_VERSION` | `onnx-1-qwen3-1024` | **The vector-space version** |
| `MEMHOUSE_EMBEDDING_DIMENSIONS` | `1024` | Vector width. Must match an installed vector index. |
| `MEMHOUSE_ORTEX_MODEL_PATH` | absolute path | Operator-supplied `.onnx` file |
| `MEMHOUSE_ORTEX_TOKENIZER_PATH` | absolute path | Operator-supplied `tokenizer.json` |
| `MEMHOUSE_ORTEX_POOLING` | `last_token` | Pooling strategy |
| `MEMHOUSE_ORTEX_QUERY_INSTRUCTION` | Qwen3 retrieval prefix | Literal prefix applied to query embeddings only; set the BGE prefix to `Represent this sentence for searching relevant passages: ` and advance the retrieval profile version |
| `MEMHOUSE_ORTEX_EXECUTION_PROVIDERS` | `cpu` | ONNX Runtime execution providers |
| `MEMHOUSE_EMBEDDING_BASE_URL` / `_API_KEY` | — | For an API embedder instead |

The Ortex embedder downloads nothing. Supply the official Qwen ONNX directory
from revision `b07450f1875a5c6cba3efbc775ceea725141bca2`. Keep `onnx/model.onnx`
beside `onnx/model.onnx_data`, and set the model path to `model.onnx` and the
tokenizer path to that revision's `onnx/tokenizer.json`. Download and verify
these files before starting MemHouse; runtime never contacts Hugging Face.

| File | SHA-256 at the pinned revision |
| --- | --- |
| `onnx/model.onnx` | `dd0996944757df30ba6cb252853e40c1f17270e5f3be5c58872e37c40bd7a27c` |
| `onnx/model.onnx_data` | `7c7569e58783ee0ad8c5fb797d7944aa4f5928af53fb4c1f626f71885af22969` |
| `onnx/tokenizer.json` | `def76fb086971c7867b829c23a26261e38d9d74e02139253b38aeb9df8b4b50a` |

Qwen3 requires an ONNX export with `input_ids` and `attention_mask`. It uses
mask-aware last-token pooling. Documents are embedded as supplied; retrieval
queries receive the configured instruction prefix. A switch from the former
384-dimensional identity requires a full, resumable re-embed. Until it
finishes, old vectors are intentionally absent from semantic retrieval.

## Reranker

`thorough` uses the `reranker` role. It defaults to the local
`BAAI/bge-reranker-v2-m3` ONNX cross-encoder. Supply its classifier and tokenizer
from revision `b9a8f459d786a86f171264d4b075572506495226`. The model outputs an
unbounded relevance logit; MemHouse uses the score only to order candidates.
Keep `onnx/model.onnx_data` beside `onnx/model.onnx`.

| Variable | Example | Meaning |
| --- | --- | --- |
| `MEMHOUSE_RERANKER_PROVIDER` | `ortex` | `ortex` or a hosted rerank provider |
| `MEMHOUSE_RERANKER_MODEL` | `BAAI/bge-reranker-v2-m3` | Model identity |
| `MEMHOUSE_RERANKER_VERSION` | `onnx-1-bge-reranker-v2-m3` | Artifact identity |
| `MEMHOUSE_RERANKER_ORTEX_MODEL_PATH` | absolute path | Classifier `.onnx` file |
| `MEMHOUSE_RERANKER_ORTEX_TOKENIZER_PATH` | absolute path | Pair tokenizer JSON file |
| `MEMHOUSE_RERANKER_ORTEX_EXECUTION_PROVIDERS` | `cpu` | ONNX Runtime execution providers |

| File | SHA-256 at the pinned revision |
| --- | --- |
| `onnx/model.onnx` | `7653075f97489878c7c6c39425de5010b001869d2f4e5e3bf20ab0dee7324f61` |
| `onnx/model.onnx_data` | `9a748c82efb2079d24650c489e053dbb3c71d8acbbcf04d7b2340db66f2748f7` |
| `tokenizer.json` | `69564b696052886ed0ac63fa393e928384e0f8caada38c1f4864a9bfbf379c15` |

This release installs 1024-dimensional vector indexes only. Boot fails when
`MEMHOUSE_EMBEDDING_DIMENSIONS` is another width. To support another width,
add a reviewed index migration, re-embed all derived vectors, verify
`GET /api/ready`, and update this configuration contract.

### DiskANN

PostgreSQL must provide `vectorscale` 0.9.0. External mode fails at boot if the
extension is unavailable.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_DISKANN_STORAGE_LAYOUT` | `memory_optimized` | SBQ layout; `plain` stores full vectors in the index |
| `MEMHOUSE_DISKANN_NUM_NEIGHBORS` | `50` | Graph neighbors per node at build time; `10` to `1000` |
| `MEMHOUSE_DISKANN_SEARCH_LIST_SIZE` | `100` | Candidate list used to build the graph; `10` to `1000` |
| `MEMHOUSE_DISKANN_MAX_ALPHA` | `1.2` | Build-time pruning factor; `1.0` to `5.0` |
| `MEMHOUSE_DISKANN_NUM_DIMENSIONS` | `0` | Indexed MRL prefix from `1` to `1024`; `0` uses all dimensions |
| `MEMHOUSE_DISKANN_QUERY_SEARCH_LIST_SIZE` | `100` | Minimum approximate candidates visited per query; `1` to `10000` |
| `MEMHOUSE_DISKANN_QUERY_RESCORE` | `50` | Minimum candidates rescored from full heap vectors; `0` to `1000` |

The five build settings require an index rebuild to take effect. Query settings
are transaction-local and apply to each semantic retrieval call. The effective
search-list size is the larger of its configured minimum and twice the request
limit. The effective rescore count is the larger of its configured minimum and
the request limit.

!!! warning "Bump the embedding version on any artefact change"
    Provider, model, version, and dimensions together are the vector-space
    identity. A mismatch takes the explicit re-embed path; vectors are never
    reused or silently substituted across identities.

## Document storage

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_BLOB_ADAPTER` | `local` | `local` or `s3` |
| `MEMHOUSE_BLOB_ROOT` | env-dependent | Absolute local blob path (`/var/lib/memhouse/blobs` in production) |
| `MEMHOUSE_S3_BUCKET` | — | Bucket name |
| `MEMHOUSE_S3_PREFIX` | `memhouse` | Key prefix |
| `MEMHOUSE_S3_HOST` / `_SCHEME` / `_PORT` | — | For MinIO or another compatible endpoint |
| `AWS_REGION` and standard AWS variables | — | ExAws credentials |
| `MEMHOUSE_DOCUMENT_CHUNK_SIZE` | `1200` | Characters per chunk |
| `MEMHOUSE_DOCUMENT_CHUNK_OVERLAP` | `160` | Overlap between chunks |
| `MEMHOUSE_DOCUMENT_MAX_EXTRACT_LENGTH` | `500000` | Extraction cap in characters |

Blob adapter choice is a runtime infrastructure seam. It does not change
document semantics.

## Budgets and cost

| Variable | Meaning |
| --- | --- |
| `MEMHOUSE_BUDGET_LIMITS_JSON` | Daily token counters, e.g. `{"input_tokens":1000000,"output_tokens":250000,"embedding_tokens":2000000}` |
| `MEMHOUSE_MODEL_COSTS_JSON` | Optional operator rates in USD per million tokens, per role; overrides the shipped `planning-reference-v1` table |
| `MEMHOUSE_MODEL_COST_PROFILE` | Content-free identity reported with costs when rates are overridden; default `operator-env` |

With no override, MemHouse uses the versioned `planning-reference-v1` rates:

| Role | Input | Output | Embedding |
| --- | ---: | ---: | ---: |
| `ingest_extractor` | 1.00 | 3.00 | — |
| `dream_reasoner` | 1.00 | 3.00 | — |
| `dialectic_agent` | 1.00 | 3.00 | — |
| `reranker` | 1.00 | 1.00 | — |
| `embedder` | — | — | 0.10 |

These are round provider-neutral planning rates, not a claim about a vendor's
current or contracted price. Their purpose is to keep a fresh deployment from
silently translating real token usage to zero USD. Set both cost variables to
your exact contracted rates and a stable internal profile id before using the
estimate for financial reconciliation.

Dream-time is throttled first when a limit bites.

### Extraction provider circuit

| Variable | Default | Meaning |
| --- | ---: | --- |
| `MEMHOUSE_INGEST_CIRCUIT_ENABLED` | `true` | Enables Account- and resolved extractor-role/provider-scoped transient-failure admission |
| `MEMHOUSE_INGEST_CIRCUIT_FAILURE_THRESHOLD` | `5` | Consecutive transient provider failures before opening |
| `MEMHOUSE_INGEST_CIRCUIT_OPEN_MS` | `30000` | Open interval before one half-open recovery probe |

Single and batched message extraction share this circuit at the gateway. An
open rejection makes no provider request and therefore creates no billed-call
usage row. Durable messages and PipelineRuns remain unchanged and retryable;
the existing repairable and terminal classifications still require explicit
operator requeue. One half-open probe is admitted at a time. If its worker
dies, the process monitor releases the permit and starts a fresh bounded open
interval instead of leaving the circuit stuck.

### Dream-time scheduling gates

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_EXPERIMENTAL_DREAM_IDLE_SCHEDULER` | `false` | Opt in to direct-fact-triggered durable scope wakeups; hourly and manual Account runs remain available while false |
| `MEMHOUSE_DREAM_MIN_CHANGES` | `1` | Eligible committed knowledge changes accumulated before a pass |
| `MEMHOUSE_DREAM_IDLE_SECONDS` | `0` | Delay from governed direct-fact activity to its durable scoped wakeup, and required inactivity before reasoning |
| `MEMHOUSE_DREAM_MIN_INTERVAL_SECONDS` | `0` | Minimum time after the last completed scoped pass |
| `MEMHOUSE_DREAM_MAX_DELTA_ITEMS` | `20` | Hard eligible-delta cap per pass; the durable cursor resumes the remainder |
| `MEMHOUSE_DREAM_MAX_WORKING_SET_ITEMS` | `50` | Hard recalled knowledge cap supplied to the reasoner |
| `MEMHOUSE_DREAM_MAX_ELAPSED_MS` | `120000` | Whole reasoning-pass timeout, shared across enabled operations, repairs, and retries |

The zero duration defaults preserve immediate existing behavior. A direct-fact
governance transaction durably schedules its scoped wakeup for the end of this
idle window. Newer activity supersedes older generations, which exit before
model work; exact duplicates and reconciler replay reuse the original
content-free key. The hourly Account sweep remains a fallback. Skipped passes
do not advance their watermark; partial passes advance only through their final
timestamp-and-id cursor. All values are validated at boot. Decisions are
emitted as content-safe `dream_gate` telemetry with no statement or source
text.

### Dream-time reasoning operations

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_EXPERIMENTAL_DREAM_OPERATION_SPLIT` | `false` | Replace the legacy single dream reasoner call with the independently versioned operation set |
| `MEMHOUSE_DREAM_UPDATE_ENABLED` | `true` | Classify support and contradiction among bounded active inputs |
| `MEMHOUSE_DREAM_SYNTHESIS_ENABLED` | `false` | Propose multi-source deductions; keep off until matched ablation approval |

All three switches use strict boot parsing; an unrecognized boolean value stops
startup instead of silently changing which provider-calling operations run.

With the split disabled, hourly and manual dream-time continue to call the
legacy `Reasoner.reason` contract exactly once. Enabling the split selects the
operation set below; it does not itself enable synthesis. The two operations use separate schemas and independently authored prompt
versions. Both may cite only exact ids from the bounded authorized working set.
Update cannot create statements; synthesis requires contributors backed by at
least two distinct message or document-version observations and cannot
classify contradictions. Two knowledge rows from one observation do not satisfy
that rule. They converge on the same
governance writer transaction, so one operation failure commits no effects and
advances no watermark. Neither contract permits model-directed deletion.
Synthesis deductions persist `reason-synthesis-1` in the existing durable
prompt-version field, and typed lineage reports `reasoning_synthesis` from that
identity without exposing the prompt or model rationale.

## Operational retention

MemHouse removes terminal queue and operational-ledger rows on a fixed schedule. It never prunes
messages, knowledge items, audit events, or dream-time watermarks.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_RETENTION_OBAN_JOBS_DAYS` | `7` | Terminal Oban job history |
| `MEMHOUSE_RETENTION_PIPELINE_RUNS_DAYS` | `30` | Completed, cancelled, or discarded pipeline runs |
| `MEMHOUSE_RETENTION_USAGE_EVENTS_DAYS` | `400` | Exact usage and model-cost history |
| `MEMHOUSE_RETENTION_GATE_DECISIONS_DAYS` | `3650` | Governance decision history |
| `MEMHOUSE_RETENTION_LIFECYCLE_EVENTS_DAYS` | `3650` | Knowledge transition history |
| `MEMHOUSE_RETENTION_BATCH_SIZE` | `10000` | Maximum rows removed from each ledger per daily pass |

All values must be positive integers. A shorter horizon reduces storage but also shortens the
history available to usage summaries and governance history views.

## Governance

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_GOVERNANCE_UNATTENDED` | `false` | Declares this whole deployment process has no human governance participant |

When true, personal knowledge above peer level receives an automatic subject
consent record. Normally only the subject's verified grant permits widening;
GateRule cannot waive it. Use this only for benchmarks, evaluations, or
synthetic deployments without real subjects. MemHouse logs it at boot and
reports it on `GET /api/ready`.

It also widens Gate B: an `auto_place` matrix cell then places personal
knowledge without a human. Restricted knowledge is never placed automatically.
When this variable is true, MemHouse rejects a restricted proposal with reason
`restricted_unattended_policy` and creates no curator queue row. The default is
unchanged: leave this false and restricted or personal work can wait for a
person.

`GET /api/ready` reports `pending_human_reviews` and `restricted_withheld` in
its `governance` object. Use these counts to detect policy mismatches in a
headless deployment.

An individual Account can be marked the same way without touching the whole
deployment — see [Governance](../concepts/governance.md) for the
account-level `consent_mode` setting, which an account administrator
controls from within that Account rather than from the environment.

## Observability

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_OTEL_ENABLED` | `false` | Enable batch OTLP/HTTP trace export |
| `MEMHOUSE_ENVIRONMENT` | `development` | Environment label |
| `OTEL_SERVICE_NAME` | `memhouse-dev` | Service name in traces |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:14318` | Collector endpoint |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http_protobuf` | |
| `OTEL_TRACES_SAMPLER` / `_ARG` | always-on, `1.0` | Sampling |
| `MEMHOUSE_OTEL_*_SPANS_ENABLED` | see [Observability](../operations/observability.md) | Per-category span switches |
| `MEMHOUSE_OTEL_DB_STATEMENT_ENABLED` | `false` | SQL text in spans — off because statements can carry sensitive values |
| `MEMHOUSE_EXPERIMENT_NAME` / `_RUN_ID` | | Evaluation run labels |
| `MEMHOUSE_RETRIEVAL_VARIANT` | `poc-baseline` | Historical label kept for comparability with recorded runs |

## Web

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `4000` | HTTP port |
| `PHX_HOST` | `localhost` | Public hostname |
| `PHX_SERVER` | `false` | Start the endpoint (set by the release launchers) |
| `DNS_CLUSTER_QUERY` | — | Clustering DNS query |

## Retrieval profiles

Profiles are configured in application config rather than the environment,
because they are behaviour rather than infrastructure. The shipped values:

| Profile | Strategies | Weights | `rrf_k` | Rerank | Deadline |
| --- | --- | --- | --- | --- | --- |
| `fast` | semantic, salience-recency | 1.0, 0.8 | 15 | no | 100 ms |
| `balanced` | semantic, lexical, temporal, entity-match | 1.0, 1.0, 0.7, 0.9 | 15 | no | 300 ms |
| `thorough` | the above plus salience-recency and relation-expand | +0.8, 0.6 | 15 | yes | 1500 ms |
| `minimal` | independently bounded direct and derived semantic lanes, lexical | semantic dual-lane 1.0, lexical 1.0 | 15 | no | 300 ms |

### Experimental minimal recall

`MEMHOUSE_EXPERIMENTAL_MINIMAL_RECALL` defaults to `false` and enables the
reversible `minimal` profile above. The profile executes no temporal,
salience-recency, entity-match, relation-expansion, context-projection, or
rerank read stage. Its direct and derived semantic shortlists are independently
capped at 10 before stable interleave; the ordinary per-request candidate
budget is still the final cap. Direct and derived results are one
`semantic_dual_lane` fusion strategy and therefore share its 1.0 weight; the
separate lexical strategy also has weight 1.0. These reviewed caps are compiled profile
behaviour, not environment overrides. It remains opt-in until matched offline
evaluation meets the quality, citation, isolation, latency, and maintenance
gates. Disabling it loses no data and immediately restores the existing profile
choices.

Fusion normalizes each strategy's returned scores and uses reciprocal rank as a
5% tie-break. `enabled_strategies` is a deployment-level allowlist: a strategy
absent from it never runs, whatever a profile asks for.
`MEMHOUSE_RETRIEVAL_STRATEGY_TIMEOUT_MS` defaults to `750`.
It caps each strategy independently and is clamped to the remaining
strategy-phase budget. Rerank reservation may further reduce the budget used by
`MemHouse.Retrieval.Engine.retrieve/3`. A deadline-free evaluation run does not
use this cap.

`MEMHOUSE_RETRIEVAL_RERANK_TIMEOUT_MS` defaults to `120`.
It is the most time reranking may use, but the request's remaining profile
deadline always wins when it is smaller. Raising it can improve thorough-search
ranking at the cost of tail latency; it cannot extend the 1500 ms hard ceiling.
A request that sets `deadline` to `"disabled"` is not capped by it either,
because such a run exists to measure the reranked ordering.

`MEMHOUSE_RETRIEVAL_RERANK_RESERVED_MS` defaults to `120` and is how much of a
reranking profile's deadline is withheld from its strategies. It is clamped to
half the profile deadline, so it cannot starve retrieval of candidates to rank.
Set it to `0` to let the strategies spend the whole deadline, which makes a slow
strategy able to cost the reranker its allowance.

`MEMHOUSE_ANSWER_CONTEXT_LIMIT` defaults to `12` and is clamped to `1..50`.
It limits only the final ranked candidates sent to the `ask` answer model.
Search still returns its full requested candidate list.

`MEMHOUSE_RETRIEVAL_EXPAND_SEED_LIMIT` defaults to `10`. It limits every
expand-stage strategy to the head of the rank-interleaved seed lists.
`MEMHOUSE_RETRIEVAL_RELATION_PER_SEED_CAP` defaults to `10`. It limits the
shared-entity neighbours that one seed can add. Shared-entity expansion also
ignores an entity mentioned by more than
`MEMHOUSE_RETRIEVAL_RELATION_FREQUENCY_CEILING` of the authorized visible
corpus (default `0.5`) once that corpus reaches
`MEMHOUSE_RETRIEVAL_RELATION_CEILING_MIN_STATEMENTS` (default `20`).

### Entity-match selectivity

The `entity_match` strategy weights each entity a query names by how much that
entity narrows the scope. Three settings bound it:

| Variable | Default | Effect |
| --- | --- | --- |
| `MEMHOUSE_RETRIEVAL_ENTITY_FREQUENCY_CEILING` | `0.5` | Share of a scope's visible statements an entity may be mentioned by before the strategy refuses to rank on it. Clamped to `0..1` |
| `MEMHOUSE_RETRIEVAL_ENTITY_CEILING_MIN_STATEMENTS` | `20` | Visible statements a scope needs before the ceiling applies |
| `MEMHOUSE_RETRIEVAL_ENTITY_PER_ENTITY_CAP` | `25` | Most statements one entity may contribute to a single list |

In a scope about two people, both names appear in nearly every statement, so
matching on them ranks the scope rather than the question. Lower the ceiling to
demand more selectivity, at the cost of recall on common names. When every
entity a query names sits above the ceiling, the strategy contributes nothing
and `disagreement.query_dependent_empty` reports that no strategy resolved the
question — that is the intended result, not a failure.

The minimum-statements setting exists because frequency over a handful of
statements measures nothing: in a four-statement scope every entity looks
ubiquitous. Below it the ceiling is skipped and recall is preserved.

Profile changes require product review; PostgreSQL location changes do not.
