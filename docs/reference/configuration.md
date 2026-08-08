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
| `MEMHOUSE_CONTEXT_SUMMARY_CONCURRENCY` | `4` | Entity-card summary calls that overlap inside one scope rebuild |

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

There are exactly five Account-level model roles: `embedder`, `reranker`,
`ingest_extractor`, `dream_reasoner`, and `dialectic_agent`. Only secret
*references* are persisted, never secret values.

When `MEMHOUSE_MODEL_PROVIDER=openrouter`, structured extraction and reasoning
use OpenRouter's strict JSON-schema response format. This is automatic; it
avoids models that intermittently ignore forced tool calls.

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
| `MEMHOUSE_EMBEDDING_DIMENSIONS` | `1024` | Vector width |
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
| `MEMHOUSE_DISKANN_QUERY_SEARCH_LIST_SIZE` | `100` | Approximate candidates visited per query; `1` to `10000` |
| `MEMHOUSE_DISKANN_QUERY_RESCORE` | `50` | Candidates rescored from full heap vectors; `0` to `1000` |

The five build settings require an index rebuild to take effect. Query settings
are transaction-local and apply to each semantic retrieval call.

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
| `MEMHOUSE_MODEL_COSTS_JSON` | Operator rates in USD per million tokens, per role |

Dream-time is throttled first when a limit bites.

## Governance

| Variable | Default | Meaning |
| --- | --- | --- |
| `MEMHOUSE_GOVERNANCE_UNATTENDED` | `false` | Declares this whole deployment process has no human governance participant |

When true, personal knowledge above peer level receives an automatic subject
consent record. Normally only the subject's verified grant permits widening;
GateRule cannot waive it. Use this only for benchmarks, evaluations, or
synthetic deployments without real subjects. MemHouse logs it at boot and
reports it on `GET /api/ready`.

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

| Profile | Strategies | Weights | Rerank | Deadline |
| --- | --- | --- | --- | --- |
| `fast` | semantic, salience-recency | 1.0, 0.8 | no | 100 ms |
| `balanced` | semantic, lexical, temporal, entity-match | 1.0, 1.0, 0.7, 0.9 | no | 300 ms |
| `thorough` | the above plus salience-recency and relation-expand | +0.8, 0.6 | yes | 1500 ms |

Fusion uses reciprocal rank with `k = 60`. `enabled_strategies` is a
deployment-level allowlist: a strategy absent from it never runs, whatever a
profile asks for. `MEMHOUSE_RETRIEVAL_RERANK_TIMEOUT_MS` defaults to `120`.
It is the most time reranking may use, but the request's remaining profile
deadline always wins when it is smaller. Raising it can improve thorough-search
ranking at the cost of tail latency; it cannot extend the 1500 ms hard ceiling.

Profile changes require product review; PostgreSQL location changes do not.
