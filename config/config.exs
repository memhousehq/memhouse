# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

# Compile-time (build-time) configuration for the whole application.
#
# WHEN THIS FILE IS EVALUATED Once, by Mix, before any dependency is compiled and long before
# the application boots. Everything set here is frozen into the compiled artifact and into a
# `mix release` tarball. `config/runtime.exs` is evaluated again on every boot of that
# artifact and overrides most of these values from the process environment.
#
# WHAT BELONGS HERE 1. Settings that must exist before or during compilation: the JSON library
# and the Postgrex type module Postgrex builds while compiling. 2. Credential-free defaults
# for everything `config/runtime.exs` may later replace, so `mix test`, `iex -S mix`, and
# one-off Mix tasks can start with no environment file present.

# General application configuration
import Config

# Ash logs a warning when an action produces change notifications that nothing
# dispatches. MemHouse registers no Ash notifiers: projection-cache
# invalidation is broadcast explicitly over Phoenix PubSub instead. Those
# undispatched notifications are therefore expected, and the warning would be
# constant noise that hides real problems.
config :ash, :missed_notifications, :ignore

config :memhouse,
  ecto_repos: [MemHouse.Repo],
  # The ten domains below are the complete durable data boundary. Every durable
  # write goes through an Ash action on a resource owned by one of them; code
  # that writes to Postgres outside this list is a defect. AshOban also reads
  # this list to discover job triggers, so a domain missing here silently loses
  # its background jobs.
  ash_domains: [
    MemHouse.Accounts,
    MemHouse.Topology,
    MemHouse.Observations,
    MemHouse.Documents,
    MemHouse.Knowledge,
    MemHouse.Governance,
    MemHouse.Model,
    MemHouse.Retrieval,
    MemHouse.Skills,
    MemHouse.Operations
  ],
  generators: [timestamp_type: :utc_datetime]

# Custom Postgrex type module. It adds binary encode/decode for the pgvector
# `vector` column type on top of the stock Ecto Postgres extensions, so
# embeddings travel as real vectors rather than float arrays. This must be a
# compile-time setting: Postgrex builds the type module while compiling.
config :memhouse, MemHouse.Repo, types: MemHouse.PostgrexTypes

# Where Postgres lives. This is an infrastructure seam, not a behaviour switch:
# `"pg0"` means the release supervises its own checksum-pinned PostgreSQL
# process, `"external"` means an operator runs the server. Both modes are the
# same release, the same migrations, and the same product guarantees; only the
# location of the database differs. `config/runtime.exs` sets the real values
# from the environment on every boot. The defaults below exist so source
# checkouts and Mix tasks work against a developer's own local Postgres.
config :memhouse, :database,
  mode: "external",
  database_url: nil,
  # Whether the release runs pending migrations itself as a supervised startup
  # step. Off by default here so a Mix task never migrates a database behind the
  # developer's back; operators under change control keep it off and run
  # `bin/migrate` as a separate step.
  auto_migrate: false,
  # The role the running node's connections switch to, so that the row-level
  # security policies on every tenant table are enforced rather than skipped.
  # `config/runtime.exs` documents both settings in full.
  app_role: "memhouse_app",
  allow_unrestricted_role: false,
  pg0: [
    # Placeholder path only. Startup validation refuses to boot in pg0 mode
    # unless this points at a real, readable, executable file, and the packaged
    # release resolves it inside the unpacked release root instead.
    binary: "/private/tmp/pg0",
    name: "memhouse",
    # The PostgreSQL version the launcher is asked for. It must match the
    # version bundled in the pinned pg0 asset; that asset's own version and its
    # per-platform SHA-256 digests live in `rel/pg0/`.
    postgres_version: "18.1.0",
    installation_root: "/private/tmp/pg0-installation",
    vectorscale_dir: "/private/tmp/pgvectorscale",
    data_dir: Path.join(System.tmp_dir!(), "memhouse-pg0"),
    # TCP port for the supervised instance. When the launcher has to start a new
    # instance it refuses to boot if something already listens here rather than
    # attaching to a stranger's database; when this data directory already has a
    # live server, it attaches to that one.
    port: 5432,
    username: "postgres",
    password: "postgres",
    database: "memhouse"
  ]

# When true, booting in external mode without a DATABASE_URL is a hard failure
# instead of a fallback to the per-environment Repo settings. Only a production
# boot in external mode turns this on; dev and test rely on their own Repo
# credentials.
config :memhouse, :require_database_url, false

# The updater verifies release manifests with this embedded Ed25519 public key.
# It is deliberately not a runtime secret: the matching private key exists only
# in the protected release-publishing workflow secret.
config :memhouse, :update,
  enabled: true,
  database_mode: "external",
  source: "https://api.github.com/repos/memhousehq/memhouse/releases/latest",
  public_key: "rgklaZ7eR1NlTXW5SPNdKlbvVmMyyAiJ6H3rfFvnZxM=",
  auto_update: :off,
  interval_hours: 24,
  install_root: nil,
  platform: "linux-x86_64"

# The single community Account this node bootstraps and serves. `account_key` is
# the stable lookup key; Account identity for an HTTP request is still derived
# from the caller's verified credential, never from a request parameter, so
# changing these values does not change tenancy rules. `signing_secret` is added
# only at runtime and is never stored here.
config :memhouse, :identity,
  account_key: "local",
  account_name: "Local MemHouse"

config :memhouse, Oban,
  # The Postgres-backed engine is used in every deployment mode. Do not swap in
  # a lite/SQLite engine or an external broker: durable job insertion has to
  # commit in the same PostgreSQL transaction as the state change and the audit
  # entry that requested it.
  engine: Oban.Engines.Basic,
  repo: MemHouse.Repo,
  # Queue names are the lanes of the pipeline; the integer is the maximum number
  # of concurrently executing jobs of that lane per node. Ingest is the user-
  # facing lane and gets the widest concurrency; portability and reconciliation
  # are serialized to one at a time because they walk an entire Account.
  queues: [
    # message and document extraction
    ingest: 10,
    # background reasoning over already-governed knowledge
    dream: 2,
    # revalidation and expiry sweeps
    lifecycle: 2,
    # context/scope/session projection rebuilds and entity resolution
    projection: 2,
    # validation continuations and answer correlation
    governance: 2,
    # external connector polling and sync
    connector: 2,
    # logical archive import rebuild work
    portability: 1,
    # reconciliation of durable records whose job never ran
    reconciler: 1
  ],
  # AshOban triggers stay transactionally driven: every one declares
  # `scheduler_cron(false)`. This Cron entry is the narrow exception for work
  # with no request-side trigger. It starts an Account-scoped lifecycle
  # scheduler, which then creates ordinary replay-safe PipelineRun rows and
  # their jobs in one transaction. Do not add a trigger cron schedule here.
  #
  # There is intentionally no Pruner plugin. Operations retains Oban history
  # until a separate retention policy exists.
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", MemHouse.Operations.LifecycleScheduler}
     ]}
  ]

config :ash_oban,
  # Jobs run through Ash actions with authorization on, exactly like an HTTP
  # caller. A background job must not be a privilege-escalation path.
  authorize?: true,
  shared_context: [:job]

# Retrieval profiles. A profile is a named bundle of candidate strategies, their fusion
# weights, whether the fused head is reranked, and a wall-clock deadline. `search` defaults to
# `:balanced`, `ask` to `:thorough`, and `:fast` is the only profile allowed to run live when
# assembling context finds no cached projection.
#
# `version` is a contract identity value reported to callers alongside results. "f7-1"
# versions the retrieval-and-context profile contract. Changing that string is a deliberate
# contract transition: it obliges a maintainer to add a changelog entry and update the
# contract regression evidence. It is not a phase name and must not be edited for cosmetic
# reasons.
#
# `deadline_ms` is a hard wall-clock ceiling in milliseconds covering strategy execution and
# any reranking. Strategies that miss it are dropped from the result, never retried, and the
# response reports them as dropped. Raising a deadline trades tail latency for recall.
config :memhouse, :retrieval_profiles,
  fast: %{
    version: "f7-1",
    strategies: [:semantic, :salience_recency],
    weights: %{semantic: 1.0, salience_recency: 0.8},
    rerank: false,
    deadline_ms: 100
  },
  balanced: %{
    version: "f7-1",
    strategies: [:semantic, :lexical, :temporal, :entity_match],
    weights: %{semantic: 1.0, lexical: 1.0, temporal: 0.7, entity_match: 0.9},
    rerank: false,
    deadline_ms: 300
  },
  thorough: %{
    version: "f7-1",
    strategies: [
      :semantic,
      :lexical,
      :temporal,
      :salience_recency,
      :entity_match,
      :relation_expand
    ],
    weights: %{
      semantic: 1.0,
      lexical: 1.0,
      temporal: 0.7,
      salience_recency: 0.8,
      entity_match: 0.9,
      relation_expand: 0.6
    },
    # Only this profile pays for a model-backed rerank of the fused head, which
    # is why its deadline is several times larger.
    rerank: true,
    deadline_ms: 1500
  },
  # Deployment-level allowlist. A strategy absent here never runs, whatever a
  # profile asks for; operators use it to switch off an expensive lane.
  enabled_strategies: [
    :semantic,
    :lexical,
    :temporal,
    :salience_recency,
    :entity_match,
    :relation_expand
  ],
  # Reciprocal-rank-fusion constant, in rank units: a candidate at rank r in one
  # strategy's list contributes weight / (rrf_k + r). A large k flattens the
  # curve so the single top hit of one strategy cannot dominate the merge; 60 is
  # the conventional published value and is kept for comparability with the
  # recorded evaluation baselines.
  rrf_k: 60,
  # Not read by the application. The per-strategy and fused-list cap comes from
  # the request's `limit` (defaulting to 12 for search and 8 for context
  # assembly), not from this value.
  max_candidates: 50,
  # How many fused candidates are sent to the reranking model in the `:thorough`
  # profile. Bounds rerank token cost and latency; the tail below rank 20 keeps
  # its fusion order.
  rerank_head: 20,
  # Maximum milliseconds independently offered to reranking. The engine clamps
  # this to the request's remaining hard deadline, so it reserves useful model
  # time without ever extending the overall request ceiling.
  rerank_timeout_ms: 750,
  # After this many incremental delta merges, a projection is rebuilt in full
  # rather than merged again. Unit: delta updates. Bounds drift and unbounded
  # growth of merged projection content.
  projection_compaction_every: 20,
  # Default character budget for an assembled context payload when the caller
  # does not pass one. Budget is claimed in a fixed order — session summary,
  # peer profile slices, scope cards, then knowledge — and each section stops at
  # the first entry that does not fit, so shrinking it trims the tail.
  context_budget_chars: 8_000

# Inline peer validation. When a peer performs a read, the system may attach one
# pending question to the response so the peer can confirm or correct a claim.
# None of these values is load-bearing on correctness; together they trade queue
# drainage against how often a peer is interrupted.
config :memhouse, :governance,
  # Hard ceiling in milliseconds for the attach query, which runs after the read
  # result is already assembled. Exceeding it means no question is attached and
  # the read is returned unchanged. A question must never delay or break a read.
  attach_deadline_ms: 15,
  # Not read by the application. Question-to-topic matching is a word-overlap
  # test on the statement text, not a similarity score.
  relevance_floor: 0.62,
  # Interruption caps, per session and per rolling 24 hours, used as the
  # defaults of a peer's ask-preference row. A peer may lower them for itself;
  # nothing may raise them.
  max_per_session: 3,
  max_per_day: 10,
  # How many times a peer may answer "not now" for one question before it stops
  # being asked and the item is escalated to a curator.
  max_attempts: 2,
  # Hours that must pass after a question was last delivered before it may be
  # delivered again.
  attempt_cooldown_hours: 48,
  # How many transcript messages after the one that quoted the statement are
  # scanned for a reply from the peer.
  answer_window_turns: 6

# Maximum retries when a model returns structured output that fails schema
# validation; each repair re-prompts with the validation errors. The generator
# also hard-caps at 2 in code, so raising this number alone has no effect.
# Malformed output is never accepted.
config :memhouse, :model_layer, max_repairs: 2

# Token admission limits per metric, per calendar day. Empty means unlimited;
# real values arrive at runtime. Reaching a limit refuses only the background
# dream-time lane, never ingest or a governed read.
config :memhouse, :budget_limits, %{}

# Operator-supplied rates in USD per million tokens, keyed by model role. Empty
# means the cost report totals zero. There is no hidden billing state and no
# vendor price list: self-hosted cost visibility uses only what the operator
# declares here.
config :memhouse, :model_cost_per_million, %{}

# Use the same Req HTTP client the rest of the app uses rather than pulling in a
# second HTTP stack for S3 calls.
config :ex_aws, http_client: ExAws.Request.Req

config :memhouse, :documents,
  # Where document bytes live. Local content-addressed files by default; S3 (or
  # any S3-compatible endpoint) is the other supported adapter. This is an
  # infrastructure seam: adapter choice must not change supersession, tombstone,
  # or export semantics.
  blob_adapter: MemHouse.Documents.BlobStore.Local,
  # Development default only. A real deployment must set an absolute, durable
  # path; a temp directory loses original document bytes on reboot.
  blob_root: Path.join(System.tmp_dir!(), "memhouse-blobs"),
  # Chunk geometry in characters. The overlap keeps a sentence that straddles a
  # boundary retrievable from either chunk. Chunks and their embeddings are
  # rebuildable derived caches, so changing these values does not rewrite
  # existing rows: previously ingested documents keep their old boundaries until
  # they are ingested again.
  chunk_size: 1_200,
  chunk_overlap: 160,
  # Upper bound in characters on extracted text per document version. Protects
  # the node against one pathological file; text past the limit is not extracted.
  max_extract_length: 500_000,
  # Connector adapters are registered per deployment; none ship enabled.
  connector_adapters: %{}

# The four Account-level model roles. Every model call in the system is made on behalf of
# exactly one of them, through the single model gateway; no pipeline, retrieval, web, or
# governance module talks to a provider directly.
#
# The tuple provider + model + model_version (+ embedding_dimensions for the embedder) is the
# recorded identity of everything the role produces. For embeddings it is stored on each
# vector: a mismatch takes the explicit re-embed path, and a vector is never silently reused
# across identities.
#
# The `deterministic` provider is a local, offline, test-and-development fallback. Production
# must not select it, and must never fall back to it after a live provider fails, because its
# output is not a real model answer.
config :memhouse, :model_roles,
  embedder: %{
    # Ortex runs an ONNX model from operator-supplied files on this machine.
    # Nothing is downloaded and no text leaves the host; a missing artifact is
    # an error rather than a trigger to fetch one.
    provider: "ortex",
    model: "Qwen/Qwen3-Embedding-0.6B",
    model_version: "onnx-1-qwen3-1024",
    prompt_version: "none",
    pipeline_version: "f5-1",
    # Must equal the model's real output width. 1024 is the width the shipped
    # DiskANN indexes are built for; another width still stores and searches,
    # but on the unindexed query path.
    embedding_dimensions: 1024,
    options: %{
      "input_order" => ["input_ids", "attention_mask"],
      "pooling" => "last_token",
      "query_instruction" =>
        "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: "
    }
  },
  ingest_extractor: %{
    provider: "deterministic",
    model: "local-structured-fallback",
    model_version: "1",
    prompt_version: "extract-5",
    pipeline_version: "f5-1",
    options: %{}
  },
  dream_reasoner: %{
    provider: "deterministic",
    model: "local-structured-fallback",
    model_version: "1",
    prompt_version: "reason-1",
    pipeline_version: "f5-1",
    options: %{}
  },
  dialectic_agent: %{
    provider: "deterministic",
    model: "local-structured-fallback",
    model_version: "1",
    prompt_version: "dialectic-1",
    pipeline_version: "f5-1",
    options: %{}
  }

# StreamingDiskANN settings are infrastructure tuning, not retrieval semantics.
# Changing build settings requires an explicit index rebuild. Query settings are
# applied transaction-locally by the retrieval store and reset on checkout.
config :memhouse, :diskann,
  storage_layout: "memory_optimized",
  num_neighbors: 50,
  search_list_size: 100,
  max_alpha: 1.2,
  num_dimensions: 0,
  query_search_list_size: 100,
  query_rescore: 50

# Legacy single-credential configuration, predating per-role settings. The
# ReqLLM provider still consults it at call time, and an `api_key` set here
# wins over a role's own `api_key_ref`. It ships as nil, and only a *reference*
# to where a credential lives is configured, so no plaintext key is ever placed
# in configuration or persisted with a model role.
config :memhouse, :models, api_key: nil, api_key_ref: "env:OPENROUTER_API_KEY"

# Configure the endpoint
config :memhouse, MemHouseWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  # Errors render as JSON only. This is an API-first surface; there is no HTML
  # error view to fall back to, and adding one must not leak internals.
  render_errors: [
    formats: [json: MemHouseWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: MemHouse.PubSub,
  # A salt, not a secret: it namespaces LiveView session signing. The actual
  # signing strength comes from `secret_key_base`, which is per-environment and
  # never committed for production.
  live_view: [signing_salt: "GplcMfTh"]

# Configure Elixir's Logger
#
# The metadata allowlist is deliberate and content-safe: request and trace
# correlation and durable pipeline identifiers only. Adding a key here that can
# carry message text, prompts, answers, or credentials would put content into
# logs.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :trace_id,
    :span_id,
    :account_id,
    :scope_id,
    :pipeline_run_id,
    :target_type,
    :target_id,
    :message_id,
    :attempt_count,
    :error_class
  ]

# Tracing is off unless a deployment explicitly enables the OTLP exporter at
# runtime. A build must never export spans by default.
config :opentelemetry, traces_exporter: :none

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Request parameters whose values Phoenix redacts before logging. The match is a
# case-sensitive substring test on the parameter name, so "api_key" also covers
# "embedding_api_key". This list is a content-safety control, not cosmetics: it
# is what keeps raw messages, questions, answers, statements, and credentials
# out of logs and error reports. Any new request parameter that can carry user
# content or a secret must be added here in the same change.
config :phoenix, :filter_parameters, [
  "answer",
  "api_key",
  "authorization",
  "content",
  "messages",
  "password",
  "prompt",
  "question",
  "query",
  "secret",
  "statement",
  "token"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
