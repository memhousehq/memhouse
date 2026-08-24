# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Config do
  @moduledoc """
  Resolves the one pinned configuration in force for each model role.

  It resolves the provider, model, versions, provenance, and embedding identity for five
  Account-level roles: `:embedder`, `:reranker`, `:ingest_extractor`, `:dream_reasoner`, and
  `:dialectic_agent`.

  Resolution order is fixed:

  1. The highest-versioned active `ModelRoleConfig` row for the caller's
     Account, when the context supplies both an `:account_id` and an `:actor`.
  2. Otherwise the compiled runtime defaults under the application's
     `:model_roles` key.

  Only unscoped rows resolve; per-scope overrides are not implemented.

  ## Invariants

  - A resolved role always carries provider, model, model version, prompt
    version, and pipeline version, so nothing the model produces can be stored
    without a complete provenance stamp.
  - For the embedder, provider, model, version, and dimensions together form the
    embedding identity. All four must match a stored vector before that vector
    may be reused.
  - Persisted configuration holds credential *references* only; nothing here
    reads or returns a secret value.

  ## Mistakes to avoid

  - Do not add an unreviewed role name. The resource validates the closed role
    set on create and update, `normalize_role/1` raises on anything else, and
    startup configuration validation requires every role to be present.
  - Do not treat a `"deterministic"` provider as a usable production model. It
    is an offline stand-in for tests and local development; ask
    `local_fallback?/1` before letting its output stand in for a real answer.
  """

  alias MemHouse.Model.ModelRoleConfig

  require Ash.Query

  @roles ~w(embedder reranker ingest_extractor dream_reasoner dialectic_agent)a

  # Call-site conveniences, not extra roles.
  @aliases %{
    ingest: :ingest_extractor,
    dream: :dream_reasoner,
    ask: :dialectic_agent,
    rerank: :reranker
  }

  defmodule Role do
    @moduledoc """
    A resolved provider call and provenance configuration.

    All fields except `:embedding_dimensions` are required. `:config_version` is the row version,
    or 1 for runtime defaults. `:options` has string keys regardless of its source.

    `:options` may hold credential references, never credentials, and must not be logged wholesale.
    """

    @enforce_keys [
      :role,
      :provider,
      :model,
      :model_version,
      :prompt_version,
      :pipeline_version,
      :config_version,
      :options
    ]
    @typedoc "A resolved model role: provider, model, versions, and options."
    @type t :: %__MODULE__{}
    defstruct [
      :role,
      :provider,
      :model,
      :model_version,
      :prompt_version,
      :pipeline_version,
      :embedding_dimensions,
      :config_version,
      :options
    ]
  end

  @doc """
  The canonical role atoms, in a stable order.

  Used by startup configuration validation, which refuses to boot a deployment
  that is missing a role or a role's provider, model, or version strings.
  """
  def roles, do: @roles

  @doc """
  Maps a role atom or a short alias onto one of the four canonical role atoms.

  Raises `ArgumentError` for anything else. Raising rather than defaulting is
  intentional: a typo must not quietly send a call to the wrong model with the
  wrong budget.
  """
  def normalize_role(role) when role in @roles, do: role
  def normalize_role(role) when is_map_key(@aliases, role), do: Map.fetch!(@aliases, role)
  def normalize_role(role), do: raise(ArgumentError, "unknown model role: #{inspect(role)}")

  @doc """
  Returns the `Role` struct in force for `role` in the caller's Account.

  `context` should carry `:account_id` and `:actor`; with both present the
  Account's own highest-versioned active configuration is read under that
  Account's tenant, so no caller can resolve another Account's configuration.
  With either missing — offline tooling, archive export, tests — the compiled
  runtime defaults are used instead.

  Raises `ArgumentError` for an unknown role name, and raises if the deployment
  has no runtime default for a role that also has no stored row.
  """
  def resolve(role, context) when is_map(context) do
    role = normalize_role(role)

    case persisted(role, context) do
      nil -> runtime(role)
      %{provider: "ortex"} when role == :reranker -> runtime(role)
      record -> from_record(role, record)
    end
  end

  @doc """
  True when this role is served by the offline deterministic stand-in provider.

  Callers use this to decide whether model output can be presented as a real
  answer. The deterministic provider returns schema-valid but non-intelligent
  text, so a caller that would otherwise show its output should fall back to a
  grounded, non-model path instead. It is selected only by explicit
  configuration up front; nothing switches to it after a live provider fails,
  because answering a failed call with fabricated content would be worse than
  returning the error.
  """
  def local_fallback?(%Role{provider: "deterministic"}), do: true
  def local_fallback?(_config), do: false

  @doc """
  The provenance stamp for a resolved role.

  Returns a map with `:provider`, `:model`, `:model_version`, `:prompt_version`,
  and `:pipeline_version`. Callers merge this into knowledge, provenance rows,
  and usage events so any stored artifact can be traced to exactly what produced
  it. It contains no content and no credentials, and is therefore safe to put in
  telemetry.
  """
  def provenance(%Role{} = config) do
    %{
      provider: config.provider,
      model: config.model,
      model_version: config.model_version,
      prompt_version: config.prompt_version,
      pipeline_version: config.pipeline_version
    }
  end

  @doc """
  The four-part identity of the vector space this embedder produces.

  Returns `%{provider:, model:, version:, dimensions:}`. Every stored vector must
  be stored with this identity, and a stored vector may only be reused when all
  four parts match the currently configured embedder. A mismatch takes the
  explicit re-embed path; vectors are never reused or substituted across
  identities, because two embedders' coordinates are not comparable even at the
  same width.

  The version covers everything that changes the coordinates — the model
  artifact, the tokenizer, and the pooling strategy — so any of those changing
  requires a version bump.

  Only defined for the `:embedder` role; passing another role raises
  `FunctionClauseError`.
  """
  def embedding_identity(%Role{role: :embedder} = config) do
    %{
      provider: config.provider,
      model: config.model,
      version: config.model_version,
      dimensions: config.embedding_dimensions
    }
  end

  # Reads the winning stored row for a role. Filters to unscoped rows only,
  # because per-scope overrides are stored but deliberately not resolved yet,
  # and takes the highest version so republishing supersedes without deleting.
  # The tenant is set from the caller's Account, so this can only ever see that
  # Account's rows.
  defp persisted(role, %{account_id: account_id, actor: actor})
       when is_binary(account_id) and not is_nil(actor) do
    # Scoped here rather than by the caller because resolution runs during a provider call,
    # which is deliberately made with no transaction open. Without the Account setting this
    # read matches nothing and resolution falls back to the compiled defaults — a silently
    # wrong answer, since everything the call produces would then be stamped with a provider
    # and model that never ran.
    MemHouse.DataLayer.in_account_transaction(account_id, fn ->
      ModelRoleConfig
      |> Ash.Query.filter(role == ^Atom.to_string(role) and active == true and is_nil(scope_id))
      |> Ash.Query.sort(version: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)
    end)
  end

  # No Account or no actor means there is nobody to read rows on behalf of, so
  # there is nothing to look up rather than something to look up unfiltered.
  defp persisted(_role, _context), do: nil

  # Compiled deployment defaults. `fetch_env!`/`fetch!` on the role, provider,
  # and model are deliberate: a deployment missing any of them must crash at
  # first use rather than run with a silently absent capability. The version
  # fields do have fallbacks, because an honest placeholder is better than a
  # crash — "unversioned" says the provider exposes no stable build id, "none"
  # says the role uses no prompt template, and "f5-1" is the contract identity
  # value for the extractor and pipeline, whose change obliges a maintainer to
  # add a changelog entry and refresh the contract evidence.
  defp runtime(role) do
    roles = Application.fetch_env!(:memhouse, :model_roles)
    values = roles |> Keyword.fetch!(role) |> Map.new()

    %Role{
      role: role,
      provider: Map.fetch!(values, :provider),
      model: Map.fetch!(values, :model),
      model_version: Map.get(values, :model_version, "unversioned"),
      prompt_version: Map.get(values, :prompt_version, "none"),
      pipeline_version: Map.get(values, :pipeline_version, "f5-1"),
      embedding_dimensions: Map.get(values, :embedding_dimensions),
      config_version: Map.get(values, :config_version, 1),
      options: values |> Map.get(:options, %{}) |> stringify_keys()
    }
  end

  defp from_record(role, record) do
    %Role{
      role: role,
      provider: record.provider,
      model: record.model,
      model_version: record.model_version,
      prompt_version: record.prompt_version,
      pipeline_version: record.pipeline_version,
      embedding_dimensions: record.embedding_dimensions,
      config_version: record.version,
      options: stringify_keys(record.options)
    }
  end

  # Options arrive with atom keys from compiled config and string keys from the
  # database. Normalizing to strings here means provider adapters can look up
  # one key shape and never have to try both.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
