# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

# Boot-time environment configuration. Process variables override `.env`; strict
# security and topology settings raise instead of guessing.
#
# Database mode changes only where PostgreSQL runs. Both modes use the same release,
# migrations, and guarantees. Credentials remain runtime-only; persisted model settings
# hold environment-variable references, never secret values.

import Config
import Dotenvy

# Later sources win, so the process environment overrides `.env`.
env = source!([".env", System.get_env()])
env_get = fn key, default -> Map.get(env, key, default) end

# Lenient parsers use defaults; bang parsers reject unsafe ambiguity.

# Absent or unparseable means false.
env_true? = fn key ->
  String.downcase(env_get.(key, "false")) in ~w(true 1 yes on)
end

env_bool = fn key, default ->
  value = if default, do: "true", else: "false"
  String.downcase(env_get.(key, value)) in ~w(true 1 yes on)
end

# Parses comma-separated headers without logging collector credentials.
env_headers = fn key ->
  key
  |> env_get.("")
  |> String.split(",", trim: true)
  |> Enum.flat_map(fn header ->
    case String.split(header, "=", parts: 2) do
      [name, value] -> [{String.trim(name), String.trim(value)}]
      _ -> []
    end
  end)
end

# Unknown OTLP protocols fall back to HTTP/protobuf.
env_protocol = fn key, default ->
  case env_get.(key, default) do
    "grpc" -> :grpc
    "http_protobuf" -> :http_protobuf
    _ -> :http_protobuf
  end
end

env_float = fn key, default ->
  case Float.parse(env_get.(key, default)) do
    {value, ""} -> value
    _ -> String.to_float(default)
  end
end

env_integer = fn key, default ->
  case Integer.parse(env_get.(key, default)) do
    {value, ""} -> value
    _other -> String.to_integer(default)
  end
end

# Rejects partially parsed ports and pool sizes.
env_integer! = fn key, default ->
  value = env_get.(key, default)

  case Integer.parse(value) do
    {integer, ""} -> integer
    _other -> raise "#{key} must be an integer, got: #{inspect(value)}"
  end
end

# A connection-pool capacity of zero or less would make every hosted model call
# wait forever. Reject it at boot, before ReqLLM starts its shared Finch pool.
env_positive_integer! = fn key, default ->
  value = env_integer!.(key, default)

  if value > 0 do
    value
  else
    raise "#{key} must be a positive integer, got: #{inspect(value)}"
  end
end

# Rejects ambiguous switches such as auto-migrate.
env_bool! = fn key, default ->
  value = env_get.(key, if(default, do: "true", else: "false"))

  case String.downcase(value) do
    truthy when truthy in ~w(true 1 yes on) -> true
    falsy when falsy in ~w(false 0 no off) -> false
    _other -> raise "#{key} must be true or false, got: #{inspect(value)}"
  end
end

# Parent-based sampling preserves incoming decisions; ratios range from 0.0 to 1.0.
env_sampler = fn ->
  sampler = env_get.("OTEL_TRACES_SAMPLER", "parentbased_always_on")

  case sampler do
    "always_on" ->
      :always_on

    "always_off" ->
      :always_off

    "traceidratio" ->
      {:trace_id_ratio_based, env_float.("OTEL_TRACES_SAMPLER_ARG", "1.0")}

    "parentbased_always_off" ->
      {:parent_based, %{root: :always_off}}

    "parentbased_traceidratio" ->
      {:parent_based,
       %{root: {:trace_id_ratio_based, env_float.("OTEL_TRACES_SAMPLER_ARG", "1.0")}}}

    _ ->
      {:parent_based, %{root: :always_on}}
  end
end

# How a background job's span relates to the request that enqueued it.
# `:child` nests the job under the originating request trace, which is usually
# what an operator wants to see. `:link` keeps the job in its own trace with a
# reference back — better when jobs run long after the request has finished, so
# one trace does not stay open for hours. `:none` severs the connection.
env_oban_span_relationship = fn ->
  case env_get.("MEMHOUSE_OTEL_OBAN_SPAN_RELATIONSHIP", "child") do
    "link" -> :link
    "none" -> :none
    _ -> :child
  end
end

# Exporter target. The generic endpoint applies to all signals; the traces-
# specific endpoint is added only when set, so an unset variable cannot put a
# nil in front of the generic one.
env_otlp_config = fn ->
  config = [
    otlp_protocol: env_protocol.("OTEL_EXPORTER_OTLP_PROTOCOL", "http_protobuf"),
    otlp_traces_protocol: env_protocol.("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "http_protobuf"),
    otlp_endpoint: env_get.("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318"),
    otlp_headers: env_headers.("OTEL_EXPORTER_OTLP_HEADERS"),
    otlp_traces_headers: env_headers.("OTEL_EXPORTER_OTLP_TRACES_HEADERS")
  ]

  case env_get.("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", nil) do
    nil -> config
    endpoint -> Keyword.put(config, :otlp_traces_endpoint, endpoint)
  end
end

# A `mix release` build does not start the web server unless told to, so that
# `bin/memhouse eval` and `bin/migrate` can run the same release without
# binding a port. `bin/server`, the launcher shipped in the release overlay,
# exports it.
#
#     PHX_SERVER=true bin/memhouse start
if System.get_env("PHX_SERVER") do
  config :memhouse, MemHouseWeb.Endpoint, server: true
end

# HTTP listener port. Strict parse: a typo must fail loudly rather than land the
# node on port 0 or a neighbouring service's port.
config :memhouse, MemHouseWeb.Endpoint, http: [port: env_integer!.("PORT", "4000")]

# Set by the release boot scripts to the unpacked release directory; falls back
# to the working directory when running from source. Used to locate the pg0
# binary shipped inside the release.
release_root = System.get_env("RELEASE_ROOT") || File.cwd!()
database_mode = env_get.("MEMHOUSE_DATABASE_MODE", "external")

# Tests read a separate variable on purpose. A developer shell almost always has
# DATABASE_URL pointing at the development database, and honouring it here would
# let `mix test` truncate real local data.
database_url =
  if config_env() == :test do
    System.get_env("MEMHOUSE_TEST_DATABASE_URL")
  else
    env_get.("DATABASE_URL", nil)
  end

# Connection details for the supervised instance. These are also the credentials
# pg0 initialises the cluster with on first start, so changing the username or
# password after the data directory exists will not re-create the role.
pg0_port = env_integer!.("MEMHOUSE_PG0_PORT", "5432")
pg0_database = env_get.("MEMHOUSE_PG0_DATABASE", "memhouse")
pg0_username = env_get.("MEMHOUSE_PG0_USERNAME", "postgres")
pg0_password = env_get.("MEMHOUSE_PG0_PASSWORD", "postgres")

if database_mode not in ~w(pg0 external) do
  raise "MEMHOUSE_DATABASE_MODE must be pg0 or external"
end

# Refuse an ambiguous instruction instead of picking one. Supplying both says
# "run your own database" and "use this other one"; guessing either way risks
# writing to, or migrating, the wrong server.
if database_mode == "pg0" and database_url not in [nil, ""] do
  raise "DATABASE_URL conflicts with MEMHOUSE_DATABASE_MODE=pg0"
end

# In pg0 mode the URL is synthesised rather than supplied. Each component is
# percent-encoded because a password containing `@`, `/`, or `:` would otherwise
# split the URL at the wrong place and produce a confusing connection failure.
# The host is fixed to loopback: the supervised instance is never exposed.
effective_database_url =
  if database_mode == "pg0" do
    "ecto://#{URI.encode_www_form(pg0_username)}:#{URI.encode_www_form(pg0_password)}@" <>
      "127.0.0.1:#{pg0_port}/#{URI.encode_www_form(pg0_database)}"
  else
    database_url
  end

# Applied only when a URL exists. Leaving the Repo untouched otherwise is what
# lets a source checkout fall back to the username/hostname settings in
# `config/dev.exs` or `config/test.exs`.
if effective_database_url not in [nil, ""] do
  config :memhouse, MemHouse.Repo,
    url: effective_database_url,
    # Database connections held open by this node. Sizing it above the server's
    # max_connections divided by the node count causes connection errors under
    # load rather than at boot.
    pool_size: env_integer!.("POOL_SIZE", "10"),
    socket_options: if(env_true?.("ECTO_IPV6"), do: [:inet6], else: [])
end

# Only a production node in external mode is required to have been given a URL.
# Elsewhere a missing URL is legitimate: pg0 mode builds its own, and source
# checkouts have per-environment Repo credentials.
config :memhouse, :require_database_url, config_env() == :prod and database_mode == "external"

config :memhouse, :database,
  mode: database_mode,
  database_url: effective_database_url,
  # The database role the running node's connections switch to, and which the
  # row-level security policies are actually enforced against. It is created
  # with NOSUPERUSER NOBYPASSRLS and granted no ownership, because PostgreSQL
  # skips those policies entirely for a superuser. Renaming it is only useful
  # where the default name collides with an existing role in a shared cluster;
  # the name is interpolated into DDL, so it must be a plain lowercase
  # identifier.
  app_role: env_get.("MEMHOUSE_DATABASE_APP_ROLE", "memhouse_app"),
  # Escape hatch for a deployment that cannot yet provide a role which is
  # neither a superuser nor granted BYPASSRLS. Turning it on lets the node boot
  # with the database half of cross-Account isolation inert, logging the
  # condition at error level on every start. It exists so an upgrade cannot
  # strand a running install, not as a supported way to operate one.
  allow_unrestricted_role: env_bool!.("MEMHOUSE_ALLOW_UNRESTRICTED_DATABASE_ROLE", false),
  # Migrations run as a supervised startup step before the endpoint accepts
  # traffic. Defaulted on for pg0 because that install is meant to be turnkey,
  # and off for external Postgres where change control usually requires
  # migrating as a separate, reviewable step with `bin/migrate`.
  auto_migrate: env_bool!.("MEMHOUSE_AUTO_MIGRATE", database_mode == "pg0"),
  pg0: [
    # The pg0 executable shipped inside the release. It is downloaded and
    # checksum-verified at packaging time, not at runtime, so the running node
    # never fetches a database binary from the network. Startup validation
    # rejects a relative path or a file that is not readable and executable.
    binary: env_get.("MEMHOUSE_PG0_BINARY", Path.join(release_root, "bin/pg0")),
    name: env_get.("MEMHOUSE_PG0_NAME", "memhouse"),
    # Must match the PostgreSQL version of the pinned asset. A mismatch means
    # the data directory cannot be opened by the binary that ships with it.
    postgres_version: env_get.("MEMHOUSE_PG0_POSTGRES_VERSION", "18.1.0"),
    installation_root: Path.expand("~/.pg0/installation"),
    vectorscale_dir: Path.join(release_root, "pgvectorscale"),
    # The durable cluster. This directory is the system of record in pg0 mode:
    # it must be backed up, must survive upgrades, and must never point at a
    # temp path in a real install.
    data_dir:
      env_get.(
        "MEMHOUSE_PG0_DATA_DIR",
        Path.expand("~/.memhouse/pg0/instances/memhouse/data")
      ),
    port: pg0_port,
    username: pg0_username,
    password: pg0_password,
    database: pg0_database
  ]

# Ingest is the only queue whose normal concurrency needs an operator-facing
# control. Its workers make hosted model calls, so raising this limit also
# requires enough ReqLLM Finch connections below. Start from a measured provider
# limit rather than assuming the upstream can sustain arbitrary parallelism.
oban_queues =
  Application.fetch_env!(:memhouse, Oban)
  |> Keyword.fetch!(:queues)
  |> Keyword.put(:ingest, env_positive_integer!.("MEMHOUSE_INGEST_QUEUE_LIMIT", "10"))

config :memhouse, Oban, queues: oban_queues

# Entity-card summaries are the other place one job makes many hosted model
# calls: a scope rebuild needs one call per qualifying entity cluster. They run
# inside the projection lane rather than a queue of their own, so this bounds
# how many overlap within a single rebuild. Raising it also requires enough
# ReqLLM Finch connections above, because the projection and ingest lanes share
# that pool. Tests stay serial: the SQL sandbox owns one database connection.
config :memhouse,
       :entity_card_summary_concurrency,
       env_positive_integer!.(
         "MEMHOUSE_CONTEXT_SUMMARY_CONCURRENCY",
         if(config_env() == :test, do: "1", else: "4")
       )

update_auto =
  case env_get.("MEMHOUSE_AUTO_UPDATE", "off") do
    "minor" -> :minor
    "off" -> :off
    value -> raise "MEMHOUSE_AUTO_UPDATE must be off or minor, got: #{inspect(value)}"
  end

architecture = to_string(:erlang.system_info(:system_architecture))

update_platform =
  case :os.type() do
    {:win32, _} ->
      "windows-x86_64"

    {:unix, :darwin} ->
      if(String.contains?(architecture, "aarch64"),
        do: "macos-arm64",
        else: "macos-x86_64"
      )

    _ ->
      if String.contains?(architecture, "aarch64") or String.contains?(architecture, "arm64") do
        "linux-arm64"
      else
        "linux-x86_64"
      end
  end

config :memhouse, :update,
  enabled: env_bool!.("MEMHOUSE_UPDATE_CHECK", true),
  database_mode: database_mode,
  source:
    env_get.(
      "MEMHOUSE_UPDATE_SOURCE",
      "https://api.github.com/repos/memhousehq/memhouse/releases/latest"
    ),
  public_key:
    env_get.("MEMHOUSE_UPDATE_PUBLIC_KEY", "rgklaZ7eR1NlTXW5SPNdKlbvVmMyyAiJ6H3rfFvnZxM="),
  auto_update: update_auto,
  interval_hours: env_integer!.("MEMHOUSE_UPDATE_CHECK_INTERVAL_HOURS", "24"),
  install_root: env_get.("MEMHOUSE_UPDATE_INSTALL_ROOT", nil),
  platform: update_platform

# Secret used to sign authentication tokens. It is deliberately independent of
# the Phoenix `SECRET_KEY_BASE`: rotating one must not invalidate the other, and
# a leak of one must not compromise the other. Production refuses to boot
# without at least 64 bytes rather than falling back to something guessable;
# development and test borrow the endpoint's committed key so a checkout runs
# with no setup.
auth_signing_secret =
  case env_get.("MEMHOUSE_AUTH_SIGNING_SECRET", nil) do
    secret when is_binary(secret) and byte_size(secret) >= 64 ->
      secret

    _missing_or_short ->
      if config_env() == :prod do
        raise """
        environment variable MEMHOUSE_AUTH_SIGNING_SECRET must contain at least
        64 bytes. Generate an independent random secret.
        """
      else
        :memhouse
        |> Application.fetch_env!(MemHouseWeb.Endpoint)
        |> Keyword.fetch!(:secret_key_base)
      end
  end

# The single community Account this node bootstraps. These name the Account; they
# do not select it for a request. Which Account a request operates on is derived
# from the caller's verified credential, so no deployment variable can be used to
# reach another Account's data.
config :memhouse, :identity,
  account_key: env_get.("MEMHOUSE_FREE_ACCOUNT_KEY", "local"),
  account_name: env_get.("MEMHOUSE_FREE_ACCOUNT_NAME", "Local MemHouse"),
  signing_secret: auth_signing_secret

# Tests never contact a provider, even when the developer's shell exports a real
# key. Clearing it here is what makes the suite deterministic and free.
model_api_key = if(config_env() == :test, do: nil, else: env_get.("OPENROUTER_API_KEY", nil))
requested_provider = env_get.("MEMHOUSE_MODEL_PROVIDER", "openrouter")
local_fallback? = env_bool.("MEMHOUSE_MODEL_LOCAL_FALLBACK", config_env() != :prod)

# The deterministic provider is a local, offline stand-in that returns
# schema-valid but non-intelligent output. It is selected only up front, and only
# when all three conditions hold: the hosted provider was requested, no key was
# supplied, and the fallback is permitted. Production defaults the fallback off,
# and nothing here can switch to it after a live provider call fails — a failed
# call must surface as an error and leave the job retryable, never be answered
# with fabricated content.
generation_provider =
  if requested_provider == "openrouter" and model_api_key in [nil, ""] and local_fallback? do
    "deterministic"
  else
    requested_provider
  end

# When the deterministic provider is active the configured model names are
# meaningless, so the recorded identity says so plainly rather than claiming
# output came from a model that was never called. Provenance must not lie.
generation_model = fn role_key, default ->
  if generation_provider == "deterministic" do
    "local-structured-fallback"
  else
    env_get.(role_key, default)
  end
end

# Version string recorded with everything the generation roles produce. Hosted
# aggregators do not expose a stable model build id, hence "unversioned" as the
# honest default; set it explicitly when a deployment pins one, because quality
# comparisons between runs are only meaningful with the exact versions recorded.
generation_version =
  if generation_provider == "deterministic",
    do: "1",
    else: env_get.("MEMHOUSE_MODEL_VERSION", "unversioned")

# Note what is stored: the *name of the variable* holding the credential, not
# the credential. Role configuration is durable and exportable, so a raw key
# must never enter it.
#
# Three settings exist together to keep a reasoning model (e.g. the default
# openai/gpt-oss-120b) from turning one ingest call into a blown context window
# or a killed request instead of a normal response:
#
# - reasoning_effort bounds how much of the call a model spends on internal
#   reasoning tokens *before* it ever emits output. This is the primary lever:
#   without it, a model can spend an unbounded share of its context on
#   reasoning regardless of how small the input is — observed in practice as a
#   single-sentence extraction call whose usage was ~600 input/tool tokens
#   against ~131k requested output tokens, almost all of it reasoning.
# - max_tokens is the hard backstop once reasoning is bounded: it caps total
#   output so a call that still runs long fails with an ordinary, retryable
#   validation error instead of a provider 400 for exceeding the whole context
#   window.
# - receive_timeout exists because ReqLLM's own long-running "thinking"
#   timeout only applies to model ids it recognizes as reasoning models
#   (o-series, gpt-5, codex); "openai/gpt-oss-120b" and other reasoning models
#   from other vendors do not match that pattern, so without an explicit
#   override here they get ReqLLM's plain 30-second chat timeout, which a
#   genuinely slow reasoning call can exceed even with the two settings above.
# - request_timeout caps the whole HTTP exchange. Unlike receive_timeout, it
#   does not reset whenever a provider streams another chunk or keep-alive.
generation_options = %{
  "api_key_ref" => "env:OPENROUTER_API_KEY",
  "base_url" => env_get.("MEMHOUSE_OPENAI_COMPAT_BASE_URL", "https://openrouter.ai/api/v1"),
  "max_tokens" => env_integer.("MEMHOUSE_MODEL_MAX_TOKENS", "8192"),
  "reasoning_effort" => env_get.("MEMHOUSE_MODEL_REASONING_EFFORT", "low"),
  "receive_timeout" => env_integer.("MEMHOUSE_MODEL_RECEIVE_TIMEOUT_MS", "120000"),
  "request_timeout" => env_positive_integer!.("MEMHOUSE_MODEL_REQUEST_TIMEOUT_MS", "300000"),
  "pool_timeout" => env_positive_integer!.("MEMHOUSE_MODEL_POOL_TIMEOUT_MS", "120000")
}

# ReqLLM shares this Finch pool across every hosted generation role. Finch
# chooses a shard randomly when `count` exceeds one, so capacity belongs in
# `size`: one 16-connection shard handles the normal ten-worker ingest queue
# without random one-connection-shard collisions. `count` is an escape hatch
# for a measured single-shard bottleneck, not a capacity knob.
model_stream_pool_size = env_positive_integer!.("MEMHOUSE_MODEL_STREAM_POOL_SIZE", "16")
model_stream_pool_count = env_positive_integer!.("MEMHOUSE_MODEL_STREAM_POOL_COUNT", "1")
model_pool_timeout = env_positive_integer!.("MEMHOUSE_MODEL_POOL_TIMEOUT_MS", "120000")

config :req_llm,
  stream_pool_size: model_stream_pool_size,
  stream_pool_count: model_stream_pool_count,
  stream_pool_timeout: model_pool_timeout

# The four model roles. Any OpenAI-compatible endpoint, including a self-hosted
# one, can serve the generation roles by pointing the base URL at it — no role is
# tied to a specific vendor.
#
# `pipeline_version` is a contract identity value: "f5-1" versions the extractor
# and pipeline identity reported by the health endpoint. Changing that string is
# a deliberate contract transition that obliges a maintainer to add a changelog
# entry and update the contract regression evidence, which is why it is a literal
# here rather than an environment lookup.
config :memhouse, :model_roles,
  embedder: %{
    # Ortex runs an ONNX model from files on this machine: no network call and
    # no download, so embedding works offline once the artifact paths below are
    # set. Without them the embedder errors rather than fetching anything.
    provider: env_get.("MEMHOUSE_EMBEDDING_PROVIDER", "ortex"),
    model: env_get.("MEMHOUSE_EMBEDDING_MODEL", "Qwen/Qwen3-Embedding-0.6B"),
    # Bump this whenever the artifacts, pooling, or dimensions change. Provider,
    # model, version, and dimensions together form the identity stamped on every
    # stored vector; a mismatch forces an explicit re-embed and a vector is never
    # silently reused across identities.
    model_version: env_get.("MEMHOUSE_EMBEDDING_VERSION", "onnx-1-qwen3-1024"),
    prompt_version: "none",
    pipeline_version: "f5-1",
    # Must equal the model's real output width and a shipped DiskANN index.
    # This release supports 1024 dimensions only.
    embedding_dimensions: env_integer.("MEMHOUSE_EMBEDDING_DIMENSIONS", "1024"),
    options: %{
      "api_key_ref" => "env:MEMHOUSE_EMBEDDING_API_KEY",
      "base_url" => env_get.("MEMHOUSE_EMBEDDING_BASE_URL", nil),
      # Filesystem paths to operator-supplied ONNX artifacts, each of which must
      # already exist. Nothing downloads them; the embedder fails rather than
      # fetching a model from the network.
      "model_path" => env_get.("MEMHOUSE_ORTEX_MODEL_PATH", nil),
      "tokenizer_path" => env_get.("MEMHOUSE_ORTEX_TOKENIZER_PATH", nil),
      # How token vectors are reduced to one sentence vector. Must match how the
      # model was trained, and changing it changes the embedding identity.
      "pooling" => env_get.("MEMHOUSE_ORTEX_POOLING", "last_token"),
      # Decoder exports do not accept token_type_ids. Qwen3 uses its final
      # unmasked token and applies this asymmetric instruction to queries only.
      "input_order" => ["input_ids", "attention_mask"],
      "query_instruction" =>
        env_get.(
          "MEMHOUSE_ORTEX_QUERY_INSTRUCTION",
          "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: "
        ),
      # Comma-separated ONNX Runtime execution providers, in preference order.
      "execution_providers" =>
        env_get.("MEMHOUSE_ORTEX_EXECUTION_PROVIDERS", "cpu")
        |> String.split(",", trim: true)
    }
  },
  # Turns raw observations into structured candidate knowledge. Its output still
  # passes validation and governance before anything becomes usable memory.
  ingest_extractor: %{
    provider: generation_provider,
    model: generation_model.("MEMHOUSE_MODEL_INGEST", "openai/gpt-oss-120b"),
    model_version: generation_version,
    prompt_version: "extract-5",
    pipeline_version: "f5-1",
    options: generation_options
  },
  # Background reasoning over already-governed knowledge. It also serves two
  # foreground uses: reranking the fused retrieval head and entity resolution.
  dream_reasoner: %{
    provider: generation_provider,
    model: generation_model.("MEMHOUSE_MODEL_DREAM", "openai/gpt-oss-120b"),
    model_version: generation_version,
    prompt_version: "reason-1",
    pipeline_version: "f5-1",
    options: generation_options
  },
  # Answer composition for the question-answering surface.
  dialectic_agent: %{
    provider: generation_provider,
    model: generation_model.("MEMHOUSE_MODEL_ASK", "openai/gpt-oss-120b"),
    model_version: generation_version,
    prompt_version: "dialectic-1",
    pipeline_version: "f5-1",
    options: generation_options
  }

config :memhouse, :diskann,
  storage_layout: env_get.("MEMHOUSE_DISKANN_STORAGE_LAYOUT", "memory_optimized"),
  num_neighbors: env_integer.("MEMHOUSE_DISKANN_NUM_NEIGHBORS", "50"),
  search_list_size: env_integer.("MEMHOUSE_DISKANN_SEARCH_LIST_SIZE", "100"),
  max_alpha: env_float.("MEMHOUSE_DISKANN_MAX_ALPHA", "1.2"),
  num_dimensions: env_integer.("MEMHOUSE_DISKANN_NUM_DIMENSIONS", "0"),
  query_search_list_size: env_integer.("MEMHOUSE_DISKANN_QUERY_SEARCH_LIST_SIZE", "100"),
  query_rescore: env_integer.("MEMHOUSE_DISKANN_QUERY_RESCORE", "50")

# Deployment overrides for retrieval. Only two things are tunable from the
# environment: which strategies may run at all, the three profile deadlines,
# and the reranker timeout inside those deadlines.
# Strategy membership and fusion weights per profile are not environment-tunable,
# because changing them changes result quality and needs review.
retrieval_strategy_names = %{
  "semantic" => :semantic,
  "lexical" => :lexical,
  "temporal" => :temporal,
  "salience_recency" => :salience_recency,
  "entity_match" => :entity_match,
  "relation_expand" => :relation_expand
}

retrieval_profiles = Application.fetch_env!(:memhouse, :retrieval_profiles)

# An unknown name raises rather than being ignored. Silently dropping a
# misspelled strategy would quietly degrade recall with no visible symptom.
enabled_retrieval_strategies =
  "MEMHOUSE_RETRIEVAL_ENABLED_STRATEGIES"
  |> env_get.(
    retrieval_profiles
    |> Keyword.fetch!(:enabled_strategies)
    |> Enum.map_join(",", &Atom.to_string/1)
  )
  |> String.split(",", trim: true)
  |> Enum.map(fn name ->
    Map.get(retrieval_strategy_names, String.trim(name)) ||
      raise "unsupported retrieval strategy: #{inspect(name)}"
  end)
  |> Enum.uniq()

# Each deadline is a hard wall-clock ceiling in milliseconds covering strategy
# execution plus any reranking. Strategies that miss it are dropped from the
# result and reported as dropped; they are never retried. Raising a deadline
# buys recall at the cost of tail latency, and the fast deadline in particular
# is on the live context path, where it bounds how long a cache miss can stall
# a caller. Each `update!` only replaces `deadline_ms`, leaving the profile's
# strategies, weights, rerank flag, and contract version untouched.
retrieval_profiles =
  retrieval_profiles
  |> Keyword.put(:enabled_strategies, enabled_retrieval_strategies)
  |> Keyword.put(
    :rerank_timeout_ms,
    env_integer.(
      "MEMHOUSE_RETRIEVAL_RERANK_TIMEOUT_MS",
      Integer.to_string(Keyword.fetch!(retrieval_profiles, :rerank_timeout_ms))
    )
  )
  |> Keyword.update!(
    :fast,
    &Map.put(
      &1,
      :deadline_ms,
      env_integer.("MEMHOUSE_RETRIEVAL_FAST_DEADLINE_MS", Integer.to_string(&1.deadline_ms))
    )
  )
  |> Keyword.update!(
    :balanced,
    &Map.put(
      &1,
      :deadline_ms,
      env_integer.(
        "MEMHOUSE_RETRIEVAL_BALANCED_DEADLINE_MS",
        Integer.to_string(&1.deadline_ms)
      )
    )
  )
  |> Keyword.update!(
    :thorough,
    &Map.put(
      &1,
      :deadline_ms,
      env_integer.(
        "MEMHOUSE_RETRIEVAL_THOROUGH_DEADLINE_MS",
        Integer.to_string(&1.deadline_ms)
      )
    )
  )

config :memhouse, :retrieval_profiles, retrieval_profiles

# Legacy single-credential configuration, predating per-role settings. The
# ReqLLM provider still consults it, and an `api_key` set here would win over a
# role's own reference — so it stays nil by design. The reference only names
# where the credential lives; the provider reads the variable at call time, so
# no key is copied into application configuration.
config :memhouse, :models,
  base_url: generation_options["base_url"],
  api_key: nil,
  api_key_ref: "env:OPENROUTER_API_KEY"

# Token admission limits per calendar day, supplied as a JSON object such as
# {"input_tokens":1000000,"output_tokens":250000}. Only these three metrics
# exist; an unknown key or a negative value raises at boot rather than producing
# a limit nobody enforces, and an absent metric means unlimited. Reaching a limit
# refuses only the background dream-time lane: ingest and governed reads keep
# working, so a budget can never make the system unable to answer.
budget_key_map = %{
  "input_tokens" => :input_tokens,
  "output_tokens" => :output_tokens,
  "embedding_tokens" => :embedding_tokens
}

budget_limits =
  "MEMHOUSE_BUDGET_LIMITS_JSON"
  |> env_get.("{}")
  |> Jason.decode!()
  |> Map.new(fn {key, value} ->
    metric =
      Map.get(budget_key_map, key) ||
        raise "unsupported budget metric in MEMHOUSE_BUDGET_LIMITS_JSON: #{inspect(key)}"

    unless is_integer(value) and value >= 0 do
      raise "budget limit #{key} must be a non-negative integer"
    end

    {metric, value}
  end)

# Operator-declared prices in USD per million tokens, keyed by model role and
# then by metric, for example
# {"ingest_extractor":{"input":0.5,"output":1.5},"embedder":{"embedding":0.02}}.
# There is no built-in vendor price list and no hidden billing state: an omitted
# role or metric simply contributes zero to the reported estimate. Exact token
# counts are recorded separately as durable usage events; this map only turns
# them into money.
cost_key_map = %{"input" => :input, "output" => :output, "embedding" => :embedding}

model_costs =
  "MEMHOUSE_MODEL_COSTS_JSON"
  |> env_get.("{}")
  |> Jason.decode!()
  |> Map.new(fn {role, rates} ->
    unless is_map(rates), do: raise("model cost rates for #{role} must be an object")

    normalized =
      Map.new(rates, fn {metric, rate} ->
        cost_metric =
          Map.get(cost_key_map, metric) ||
            raise "unsupported cost metric in MEMHOUSE_MODEL_COSTS_JSON: #{inspect(metric)}"

        unless is_number(rate) and rate >= 0,
          do: raise("model cost rate #{role}.#{metric} must be non-negative")

        # Multiplying by 1.0 coerces a JSON integer to a float so downstream
        # arithmetic stays float-only and never hits integer division.
        {cost_metric, rate * 1.0}
      end)

    {role, normalized}
  end)

config :memhouse, :budget_limits, budget_limits
config :memhouse, :model_cost_per_million, model_costs

# Where original document bytes are stored. This is an infrastructure seam:
# swapping the adapter changes where blobs live and nothing else. Supersession,
# tombstones, checksum-verified export, and erasure behave identically either
# way. An unknown value raises rather than defaulting to local storage, which
# would put data somewhere the operator did not intend.
blob_adapter =
  case env_get.("MEMHOUSE_BLOB_ADAPTER", "local") do
    "local" -> MemHouse.Documents.BlobStore.Local
    "s3" -> MemHouse.Documents.BlobStore.S3
    invalid -> raise "unsupported MEMHOUSE_BLOB_ADAPTER: #{inspect(invalid)}"
  end

# Production defaults to a durable system path; other environments get a
# per-environment temp directory so a `mix test` run cannot clobber development
# blobs. A temp default in production would lose original documents on reboot,
# which is why it is not used there.
default_blob_root =
  if config_env() == :prod,
    do: "/var/lib/memhouse/blobs",
    else: Path.join(System.tmp_dir!(), "memhouse-blobs-#{config_env()}")

config :memhouse, :documents,
  blob_adapter: blob_adapter,
  # Must be absolute; startup validation rejects a relative path. Blobs stored
  # here are content-addressed and are part of the backup set, not a cache.
  blob_root: env_get.("MEMHOUSE_BLOB_ROOT", default_blob_root),
  # Required when the adapter is s3; startup validation refuses to boot without
  # it rather than failing later on the first upload.
  s3_bucket: env_get.("MEMHOUSE_S3_BUCKET", nil),
  s3_prefix: env_get.("MEMHOUSE_S3_PREFIX", "memhouse"),
  # Chunk geometry in characters; the overlap keeps a sentence that straddles a
  # boundary retrievable from either chunk. Chunks and their embeddings are
  # rebuildable caches, so changing these values does not re-chunk documents
  # already ingested — they keep their old boundaries until ingested again.
  chunk_size: env_integer.("MEMHOUSE_DOCUMENT_CHUNK_SIZE", "1200"),
  chunk_overlap: env_integer.("MEMHOUSE_DOCUMENT_CHUNK_OVERLAP", "160"),
  # Upper bound in characters of extracted text per document version. Guards one
  # pathological file from exhausting node memory; text past the limit is not
  # extracted, so raising it raises peak memory during parsing.
  max_extract_length: env_integer.("MEMHOUSE_DOCUMENT_MAX_EXTRACT_LENGTH", "500000"),
  connector_adapters: %{}

config :ex_aws,
  http_client: ExAws.Request.Req,
  region: env_get.("AWS_REGION", "us-east-1")

# Only set when an S3-compatible endpoint is in use (MinIO, Ceph, a regional
# gateway). Left unset, ExAws talks to AWS S3 with its own defaults. Credentials
# are not configured here: ExAws reads them from the standard AWS environment.
case env_get.("MEMHOUSE_S3_HOST", nil) do
  host when is_binary(host) and host != "" ->
    config :ex_aws, :s3,
      scheme: env_get.("MEMHOUSE_S3_SCHEME", "https://"),
      host: host,
      port: env_integer.("MEMHOUSE_S3_PORT", "443")

  _unset ->
    :ok
end

# Off by default, and it should stay off outside a debugging session: a SQL
# statement span can carry literal column values, which would put user content
# into traces.
otel_db_statement =
  if env_true?.("MEMHOUSE_OTEL_DB_STATEMENT_ENABLED"), do: :enabled, else: :disabled

# Span category switches. Spans record ids, counts, profile and strategy names,
# model names, timings, token counts, and error classes — never message text,
# prompts, answers, restricted knowledge, or credentials. The defaults enable the
# categories that describe a workflow end to end and leave Ecto off, because
# per-query spans bury the meaningful ones in noise.
config :memhouse, :observability,
  db_statement: otel_db_statement,
  http_spans: env_bool.("MEMHOUSE_OTEL_HTTP_SPANS_ENABLED", true),
  phoenix_spans: env_bool.("MEMHOUSE_OTEL_PHOENIX_SPANS_ENABLED", true),
  ecto_spans: env_bool.("MEMHOUSE_OTEL_ECTO_SPANS_ENABLED", false),
  oban_spans: env_bool.("MEMHOUSE_OTEL_OBAN_SPANS_ENABLED", true),
  oban_span_relationship: env_oban_span_relationship.(),
  memory_spans: env_bool.("MEMHOUSE_OTEL_MEMORY_SPANS_ENABLED", true),
  model_spans: env_bool.("MEMHOUSE_OTEL_MODEL_SPANS_ENABLED", true),
  document_spans: env_bool.("MEMHOUSE_OTEL_DOCUMENT_SPANS_ENABLED", true)

# Resource attributes stamped on every span. The three experiment attributes
# exist so traces from different evaluation runs can be told apart and compared
# after the fact: name groups runs, run id identifies one, and the retrieval
# variant records which retrieval configuration produced them. Their defaults are
# plain labels, not behaviour switches — setting them changes nothing about how
# the node answers, only how its spans are tagged. The default variant label
# "poc-baseline" names the frozen behaviour baseline that later runs are compared
# against; change it when a run uses a different retrieval configuration, or the
# comparison silently mixes two variants together.
config :opentelemetry,
  resource: %{
    :service => %{
      name: env_get.("OTEL_SERVICE_NAME", "memhouse-dev"),
      namespace: "memhouse"
    },
    :deployment => %{
      environment: env_get.("MEMHOUSE_ENVIRONMENT", "development")
    },
    "memhouse.experiment.name" => env_get.("MEMHOUSE_EXPERIMENT_NAME", "local-dev"),
    "memhouse.experiment.run_id" => env_get.("MEMHOUSE_EXPERIMENT_RUN_ID", "manual"),
    "memhouse.retrieval.variant" => env_get.("MEMHOUSE_RETRIEVAL_VARIANT", "poc-baseline")
  },
  sampler: env_sampler.()

# Export is opt-in. Without this flag the node produces no outbound telemetry at
# all, which is the right default for a self-hosted install that may never have a
# collector. Batching is used when enabled so exporting never blocks a request.
if env_true?.("MEMHOUSE_OTEL_ENABLED") do
  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp

  config :opentelemetry_exporter, env_otlp_config.()
else
  config :opentelemetry, traces_exporter: :none
end

# Declares this process has no human governance participant, so
# MemHouse.Governance.Engine auto-grants the subject-consent step it would
# otherwise block on for personal knowledge aimed above peer level, for every
# Account in this process. Off by default; the per-Account
# consent_mode: "auto" attribute is the narrower alternative when only some
# Accounts in a shared deployment are synthetic.
unattended? = env_true?.("MEMHOUSE_GOVERNANCE_UNATTENDED")
config :memhouse, :governance, unattended: unattended?

if unattended? do
  require Logger

  Logger.warning(
    "MEMHOUSE_GOVERNANCE_UNATTENDED=true: every Account in this process will have " <>
      "subject consent auto-granted for personal knowledge above peer level. This " <>
      "removes a real privacy protection and is intended only for benchmark, " <>
      "evaluation, or synthetic-data deployments."
  )
end

if config_env() == :prod do
  # Phoenix's own signing/encryption key for cookies and sessions. It falls back
  # to the authentication signing secret only so a minimal deployment can boot
  # with one secret; a real deployment should set both to independent random
  # values, so that rotating or leaking one does not affect the other.
  secret_key_base = env_get.("SECRET_KEY_BASE", auth_signing_secret)

  # Used to build absolute URLs. The placeholder default is intentionally wrong
  # so a forgotten setting shows up in generated links rather than silently
  # producing links to the container's internal name.
  host = env_get.("PHX_HOST", "example.com")

  # Optional DNS-based clustering for multi-node deployments. Unset means the
  # node runs alone; clustering is not required for either database mode.
  config :memhouse, :dns_cluster_query, env_get.("DNS_CLUSTER_QUERY", nil)

  config :memhouse, MemHouseWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # TLS is normally terminated by a proxy in front of this node, and the
  # production build already redirects plain HTTP based on the forwarded
  # protocol header. To terminate TLS in the release itself instead, add an
  # `https` key to the endpoint configuration:
  #
  #     config :memhouse, MemHouseWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # `cipher_suite: :strong` allows only current ciphers and will refuse old
  # clients; `:compatible` widens support at the cost of weaker ciphers.
  #
  # `:keyfile` and `:certfile` take an absolute path, or a path relative to
  # `priv`, for example "priv/ssl/server.key".
end
