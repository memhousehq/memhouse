# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model do
  @moduledoc """
  Provider-neutral model capabilities and versioned per-Account role configuration.

  Every call goes through this module or `MemHouse.Model.Gateway` for
  provenance, metering, provider substitution, and deterministic tests. The four
  Account-level roles are:

  - `:embedder` — pinned vector generation. Defaults to a local ONNX model.
  - `:ingest_extractor` — fast structured extraction of observations.
  - `:dream_reasoner` — slow background reasoning, and reranking.
  - `:dialectic_agent` — grounded structured answers to questions.

  Roles do not vary by scope. Account-aware calls require `:account_id` and
  `:actor`; offline calls may use runtime defaults but skip durable metering.
  Providers are called only through the gateway. Propagate failures so jobs can
  retry, and persist credential references rather than raw secrets.
  """

  use Ash.Domain

  resources do
    resource MemHouse.Model.ModelRoleConfig
  end

  @doc """
  Resolves the pinned configuration for one model role.

  Accepts a role atom or one of the short aliases, and the caller context map.
  Returns a `MemHouse.Model.Config.Role` struct describing provider, model,
  versions, and options. Raises `ArgumentError` for an unknown role name.
  """
  defdelegate role_config(role, context), to: MemHouse.Model.Config, as: :resolve

  @doc """
  Runs one structured generation with bounded validate-and-repair.

  `schema` is a module implementing `MemHouse.Model.Schema`; its JSON schema is
  sent to the provider and its `cast/2` validates what comes back. Returns
  `{:ok, casted_value, provenance_map}` where the provenance map carries
  provider, model, model version, prompt version, and pipeline version for
  stamping onto whatever the caller persists.

  Returns `{:error, {:structured_validation_failed, errors}}` when the model
  cannot produce schema-valid output within the repair budget, or
  `{:error, reason}` for a provider failure. Malformed output is never coerced
  into knowledge.
  """
  defdelegate generate_structured(role, messages, schema, context, opts \\ []),
    to: MemHouse.Model.StructuredGenerator,
    as: :generate

  @doc """
  Runs one free-text chat completion for a role.

  Returns `{:ok, text, provenance_map}` or `{:error, reason}`. Prefer
  `generate_structured/5` for anything whose output is parsed: unconstrained
  text has no validation gate behind it.
  """
  defdelegate chat(role, messages, context, opts \\ []), to: MemHouse.Model.Gateway

  @doc """
  Embeds a list of texts with the Account's pinned `:embedder` role.

  Returns `{:ok, %MemHouse.Model.Embedding.Result{}}` carrying the vectors
  together with the provider, model, version, and dimension identity that
  produced them; a caller storing vectors must store that identity alongside
  them. Pass `:stored_identity` in `opts` when re-using existing vectors so a
  changed embedder is reported as `{:error, {:reembed_required, plan}}` instead
  of silently mixing incompatible vector spaces.
  """
  defdelegate embed(texts, context, opts \\ []), to: MemHouse.Model.Embedding

  @doc """
  Reranks candidate documents against a query using the `:dream_reasoner` role.

  Returns `{:ok, ranked, provenance_map}` where `ranked` is the provider's
  result list, or `{:error, reason}`. Reranking is an optional quality step:
  callers are expected to keep their pre-rerank ordering when this errors rather
  than failing the whole retrieval.
  """
  defdelegate rerank(query, documents, context, opts \\ []), to: MemHouse.Model.Gateway
end

defmodule MemHouse.Model.ValidateSecretReferences do
  @moduledoc """
  Ash validation that keeps raw credentials out of persisted model role options.

  Durable role configuration may hold credential references, never credentials. This validation
  rejects secret-like keys anywhere in the `options` map.

  Key names are lowercased with dashes and underscores removed, catching `api_key`, `API-KEY`,
  and `apiKey`. Reference keys such as `api_key_ref` remain valid. Values are never inspected.
  """

  use Ash.Resource.Validation

  # Normalized (lowercased, dash/underscore-stripped) key names that indicate a
  # live credential rather than a reference to one.
  @raw_secret_keys ~w(apikey authorization password secret token accesstoken authtoken bearer)

  @doc """
  Validation setup callback. Options are unused and returned unchanged.
  """
  @impl true
  def init(opts), do: {:ok, opts}

  @doc """
  Returns `:ok` when the changeset's `options` map holds no raw-credential key,
  and an error on `:options` otherwise. A missing `options` map is treated as
  empty and passes.
  """
  @impl true
  def validate(changeset, _opts, _context) do
    options = Ash.Changeset.get_attribute(changeset, :options) || %{}

    if raw_secret_key?(options) do
      {:error, field: :options, message: "must contain secret references, never raw credentials"}
    else
      :ok
    end
  end

  # Descends through nested maps and lists: a secret pasted one level down, for
  # example under a per-provider sub-map, must be caught just the same.
  defp raw_secret_key?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      normalized =
        key
        |> to_string()
        |> String.downcase()
        |> String.replace(~r/[-_]/, "")

      normalized in @raw_secret_keys or raw_secret_key?(value)
    end)
  end

  defp raw_secret_key?(values) when is_list(values), do: Enum.any?(values, &raw_secret_key?/1)
  defp raw_secret_key?(_value), do: false
end

defmodule MemHouse.Model.ModelRoleConfig do
  @moduledoc """
  One durable, versioned model-role configuration row for an Account.

  The highest active version overrides runtime defaults for one of four roles: `embedder`,
  `ingest_extractor`, `dream_reasoner`, or `dialectic_agent`.

  ## Versioning rather than mutation

  Publish a higher version instead of rewriting a row. Older rows explain existing artifacts.

  ## Fields that are contract identities

  `model_version`, `prompt_version`, and `pipeline_version` are copied to provenance, usage, and
  evaluation records. `pipeline_version` defaults to `"f5-1"`, the health endpoint's extractor
  contract. Changing it requires a changelog entry and refreshed contract evidence.

  For `embedder`, provider, model, `model_version`, and `embedding_dimensions` form the vector
  identity. Change the model version with the artifact, tokenizer, pooling, or width.

  ## Mistakes to avoid

  - Never store a live API key in `options`. Store a reference such as the name
    of the environment variable holding it; a validation enforces this.
  - Do not edit a row in place to "just try another model" in a deployment that
    already has stored vectors or extracted knowledge. Insert a new version so
    provenance stays truthful.
  """

  use MemHouse.Resource, domain: MemHouse.Model, table: "model_role_configs"

  # Every action is tenant-filtered; requests cannot select another Account's configuration.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # `role` is create-only, so a row cannot be repurposed.
    create :create do
      accept [
        :scope_id,
        :role,
        :provider,
        :model,
        :model_version,
        :prompt_version,
        :pipeline_version,
        :embedding_dimensions,
        :options,
        :version,
        :active
      ]

      # Reject unknown roles instead of creating an unreachable row.
      validate attribute_in(:role, ~w(embedder ingest_extractor dream_reasoner dialectic_agent))
      # Options may hold credential references only, never credentials.
      validate MemHouse.Model.ValidateSecretReferences
    end

    # `role`, `account_id`, and `scope_id` are immutable row identity.
    update :update do
      # Non-atomic because the secret-reference validation must inspect the
      # merged `options` map in Elixir rather than as a database expression.
      require_atomic? false

      accept [
        :provider,
        :model,
        :model_version,
        :prompt_version,
        :pipeline_version,
        :embedding_dimensions,
        :options,
        :version,
        :active
      ]

      validate attribute_in(:role, ~w(embedder ingest_extractor dream_reasoner dialectic_agent))
      validate MemHouse.Model.ValidateSecretReferences
    end
  end

  policies do
    # Applies to every action including reads: an actor may only ever touch rows
    # belonging to its own Account.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Choosing which provider and model an Account uses is an administrative
    # decision. Ordinary members and readers may not change it; the internal
    # `:system` actor may, which is what lets an archive import restore a row.
    policy action_type([:create, :update, :destroy]) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    # Reserved for future per-scope overrides. Resolution today reads only rows
    # where this is nil, so a non-nil value is stored but never selected.
    attribute :scope_id, :uuid

    attribute :role, :string, allow_nil?: false, public?: true

    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :model, :string, allow_nil?: false, public?: true
    # Provenance strings. "unversioned" is the honest default for hosted
    # aggregators that expose no stable build id; "none" means the role uses no
    # prompt template at all, which is the normal case for an embedder.
    attribute :model_version, :string, allow_nil?: false, default: "unversioned", public?: true
    attribute :prompt_version, :string, allow_nil?: false, default: "none", public?: true
    # Contract identity value: "f5-1" versions the extractor and pipeline
    # identity reported by the health endpoint. Changing it requires a changelog
    # entry and refreshed contract evidence.
    attribute :pipeline_version, :string, allow_nil?: false, default: "f5-1", public?: true
    # Vector width, in floats per vector. Meaningful for the embedder role only,
    # and must equal both the model's real output width and the width of the
    # installed vector indexes.
    attribute :embedding_dimensions, :integer, constraints: [min: 1], public?: true
    # Provider-specific settings such as a base URL, request limits, local
    # artifact paths, and credential *references*. Never raw credentials.
    attribute :options, :map, allow_nil?: false, default: %{}
    # Monotonic publication counter. Resolution takes the highest active
    # version, so superseded rows stay readable as provenance.
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Unique on Account, scope, role, and version — the Account column comes
    # from the attribute multitenancy above. Nulls count as distinct in the
    # generated index, so it does not constrain the unscoped rows that
    # resolution actually reads.
    identity :scope_role_version, [:scope_id, :role, :version]
  end
end
