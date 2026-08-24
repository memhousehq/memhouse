# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.RuntimeConfig do
  @moduledoc """
  Validates node-local infrastructure configuration before supervision starts.

  Checks database location, blob storage, and model-role structure, with secret-free operator
  errors. Authorization belongs in resource policies. Database mode may control database
  supervision and migration only; it must never fork product behavior.
  """

  # Both database modes run the same release, schema, queues, and guarantees.
  @database_modes ~w(pg0 external)

  # Reject unknown storage modules before documents can be misplaced.
  @blob_adapters [MemHouse.Documents.BlobStore.Local, MemHouse.Documents.BlobStore.S3]
  # A migration creates these expression indexes. A configured embedder outside
  # this set would make semantic retrieval fall back to an unbounded scan.
  @indexed_embedding_dimensions [1024]
  import Bitwise, only: [band: 2]

  @doc """
  Validates every infrastructure setting this node needs, or raises.

  Returns `:ok` for valid active-mode database, blob, and model settings. Otherwise raises a
  secret-free `RuntimeError` naming the setting.

  Only the mode actually in use is checked, so leftover settings for the other
  database mode never block a boot.
  """
  def validate! do
    database = Application.fetch_env!(:memhouse, :database)
    mode = Keyword.fetch!(database, :mode)

    unless mode in @database_modes do
      raise "MEMHOUSE_DATABASE_MODE must be one of: #{Enum.join(@database_modes, ", ")}"
    end

    validate_database!(mode, database)
    validate_diskann!()
    validate_documents!()
    validate_models!()
    validate_ingest_provider_circuit!()
    validate_model_cost_profile!()
    validate_embedding_index!()
    :ok
  end

  @doc """
  Reports whether the configured embedder has a matching installed vector index.

  Returns only the embedding identity and dimension contract. It is safe for the
  unauthenticated readiness payload and does not inspect vectors or database metadata.
  """
  def embedding_index_check do
    config =
      :memhouse
      |> Application.fetch_env!(:model_roles)
      |> Keyword.fetch!(:embedder)
      |> Map.new()

    dimensions = Map.get(config, :embedding_dimensions)

    %{
      status: if(dimensions in @indexed_embedding_dimensions, do: "ok", else: "error"),
      provider: Map.get(config, :provider),
      model: Map.get(config, :model),
      version: Map.get(config, :model_version),
      configured_dimensions: dimensions,
      indexed_dimensions: @indexed_embedding_dimensions
    }
  end

  @doc """
  The configured database mode, `"pg0"` or `"external"`.

  Use only to control database supervision, never product behavior.
  """
  def database_mode do
    :memhouse
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:mode)
  end

  @doc """
  True when this node supervises its own embedded PostgreSQL server.

  The single legitimate use is deciding whether to start and stop that server.
  """
  def pg0?, do: database_mode() == "pg0"

  @doc """
  True when the node should run pending migrations itself during startup.

  Turnkey installs migrate on boot; operators under change control turn this off
  and run migrations as a separate, reviewed step before deploying.
  """
  def auto_migrate? do
    :memhouse
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:auto_migrate)
  end

  # Embedded mode requires usable absolute paths independent of working directory.
  # The paths are release configuration, not request input.
  # sobelow_skip ["Traversal.FileModule"]
  defp validate_database!("pg0", database) do
    pg0 = Keyword.fetch!(database, :pg0)
    binary = Keyword.fetch!(pg0, :binary)
    data_dir = Keyword.fetch!(pg0, :data_dir)
    installation_root = Keyword.fetch!(pg0, :installation_root)
    vectorscale_dir = Keyword.fetch!(pg0, :vectorscale_dir)
    port = Keyword.fetch!(pg0, :port)

    unless Path.type(binary) == :absolute do
      raise "MEMHOUSE_PG0_BINARY must be an absolute path"
    end

    unless File.regular?(binary) do
      raise "pinned pg0 binary is missing at #{binary}"
    end

    # `0o111` checks owner/group/other execute bits; packaged binaries must also be readable.
    case File.stat(binary) do
      {:ok, %{access: access, mode: mode}}
      when access in [:read_write, :read] and band(mode, 0o111) != 0 ->
        :ok

      _other ->
        raise "pinned pg0 binary is not readable and executable at #{binary}"
    end

    unless Path.type(data_dir) == :absolute do
      raise "MEMHOUSE_PG0_DATA_DIR must be an absolute path"
    end

    unless Path.type(installation_root) == :absolute do
      raise "pg0 installation root must be an absolute path"
    end

    unless Path.type(vectorscale_dir) == :absolute and
             File.regular?(Path.join(vectorscale_dir, "manifest.sha256")) and
             File.read(Path.join(vectorscale_dir, "VERSION")) == {:ok, "0.9.0\n"} do
      raise "packaged pgvectorscale files are missing at #{vectorscale_dir}"
    end

    unless port in 1..65_535 do
      raise "MEMHOUSE_PG0_PORT must be between 1 and 65535"
    end
  end

  # Require external URL only where production configuration marks it mandatory.
  defp validate_database!("external", database) do
    if Keyword.get(database, :database_url) in [nil, ""] and
         Application.get_env(:memhouse, :require_database_url, false) do
      raise "DATABASE_URL is required when MEMHOUSE_DATABASE_MODE=external"
    end
  end

  defp validate_diskann! do
    config = Application.fetch_env!(:memhouse, :diskann)

    unless Keyword.fetch!(config, :storage_layout) in ~w(memory_optimized plain) do
      raise "MEMHOUSE_DISKANN_STORAGE_LAYOUT must be memory_optimized or plain"
    end

    integer_in!(config, :num_neighbors, 10..1000)
    integer_in!(config, :search_list_size, 10..1000)
    integer_in!(config, :num_dimensions, 0..1024)
    integer_in!(config, :query_search_list_size, 1..10_000)
    integer_in!(config, :query_rescore, 0..1000)

    max_alpha = Keyword.fetch!(config, :max_alpha)

    unless is_number(max_alpha) and max_alpha >= 1.0 and max_alpha <= 5.0 do
      raise "MEMHOUSE_DISKANN_MAX_ALPHA must be between 1.0 and 5.0"
    end
  end

  defp integer_in!(config, key, range) do
    value = Keyword.fetch!(config, key)

    unless is_integer(value) and value in range do
      raise "#{key} must be between #{range.first} and #{range.last}"
    end
  end

  # Validate storage before the first upload: absolute local root or explicit S3 bucket.
  defp validate_documents! do
    documents = Application.fetch_env!(:memhouse, :documents)
    adapter = Keyword.fetch!(documents, :blob_adapter)

    unless adapter in @blob_adapters do
      raise "configured blob adapter is not supported"
    end

    case adapter do
      MemHouse.Documents.BlobStore.Local ->
        root = Keyword.fetch!(documents, :blob_root)

        unless Path.type(root) == :absolute do
          raise "MEMHOUSE_BLOB_ROOT must be an absolute path"
        end

      MemHouse.Documents.BlobStore.S3 ->
        if Keyword.get(documents, :s3_bucket) in [nil, ""] do
          raise "MEMHOUSE_S3_BUCKET is required when MEMHOUSE_BLOB_ADAPTER=s3"
        end
    end
  end

  # Require attribution identities for every role. This structural check stays offline and never
  # validates credentials or contacts providers.
  defp validate_models! do
    roles = Application.fetch_env!(:memhouse, :model_roles)
    expected = MemHouse.Model.Config.roles()

    missing = Enum.reject(expected, &Keyword.has_key?(roles, &1))
    if missing != [], do: raise("missing model role configuration: #{inspect(missing)}")

    Enum.each(expected, fn role ->
      config = roles |> Keyword.fetch!(role) |> Map.new()

      for key <- [:provider, :model, :model_version, :pipeline_version] do
        if Map.get(config, key) in [nil, ""] do
          raise "model role #{role} is missing #{key}"
        end
      end
    end)

    reranker = roles |> Keyword.fetch!(:reranker) |> Map.new()

    if Map.get(reranker, :provider) == "ortex" do
      raise "MEMHOUSE_RERANKER_PROVIDER=ortex was removed; unset legacy reranker overrides " <>
              "or set MEMHOUSE_RERANKER_PROVIDER=openrouter and " <>
              "MEMHOUSE_RERANKER_MODEL=voyageai/rerank-2.5"
    end
  end

  defp validate_ingest_provider_circuit! do
    config = Application.fetch_env!(:memhouse, :ingest_provider_circuit)

    unless is_boolean(Keyword.fetch!(config, :enabled)) do
      raise "MEMHOUSE_INGEST_CIRCUIT_ENABLED must be true or false"
    end

    for key <- [:failure_threshold, :open_ms] do
      unless is_integer(Keyword.fetch!(config, key)) and Keyword.fetch!(config, key) > 0 do
        raise "ingest provider circuit #{key} must be a positive integer"
      end
    end
  end

  defp validate_model_cost_profile! do
    profile = Application.fetch_env!(:memhouse, :model_cost_profile)

    unless is_map(profile) and profile[:kind] in ["planning_reference", "operator_override"] and
             is_binary(profile[:id]) and
             Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/, profile[:id]) do
      raise "model cost profile must have a safe id and known kind"
    end
  end

  defp validate_embedding_index! do
    %{
      status: status,
      configured_dimensions: configured_dimensions,
      indexed_dimensions: indexed_dimensions
    } = embedding_index_check()

    unless status == "ok" do
      raise "MEMHOUSE_EMBEDDING_DIMENSIONS must match an installed vector index; " <>
              "configured dimensions: #{inspect(configured_dimensions)}; " <>
              "indexed dimensions: #{Enum.join(indexed_dimensions, ", ")}"
    end
  end
end
