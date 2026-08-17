# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval do
  @moduledoc """
  The public boundary for reading governed memory, and the Ash domain that owns
  retrieval profiles.

  All multi-strategy candidate search enters here and returns a plain map.

  ## What retrieval guarantees

  * **Authorization is applied inside retrieval, never after it.** Every
    candidate source filters by Account, by the caller's authorized scope ids,
    and by lifecycle state before a single row of content leaves the database,
    and narrows `provisional` statements to the calling peer whenever the actor
    carries a peer id. There is no post-filtering step downstream, so a
    strategy that forgets a filter leaks data. Adding a new candidate source
    means adding those filters to it.
  * **Strategy scores are not comparable.** Cosine similarity, full-text rank,
    a time-relevance step function, a salience decay product, and mention
    confidence live on unrelated scales. Score-aware fusion normalizes each
    strategy's scores locally, then combines them using profile weights and
    the rrf_k rank tie-break constant.
  * **Entity and mention rows are private caches.** They exist only to widen
    recall. No canonical name, alias, surface form, or entity id may appear in
    anything this module returns.

  ## Entry points

  `retrieve/3` fuses profile strategies. `rebuild_scope/2` replay-safely regenerates vectors,
  entities, mentions, and context projections.
  """

  use Ash.Domain

  resources do
    resource MemHouse.Retrieval.RetrievalProfile
    resource MemHouse.Retrieval.RecallDocument
  end

  @doc """
  Runs one retrieval request and returns a fused, ranked candidate list.

  `query` is a `MemHouse.Retrieval.Query` struct that must already carry the
  Account id, the resolved actor, and the scope ids the actor may read;
  retrieval trusts those fields and filters by them, it does not re-derive
  them. `profile` is `:fast`, `:balanced`, `:thorough`, or the feature-gated
  experimental `:minimal` profile (the equivalent strings are accepted).
  `:minimal` raises unless `MEMHOUSE_EXPERIMENTAL_MINIMAL_RECALL=true`. `opts` may carry
  `:deadline?` to disable the time
  budget for evaluation runs, `:inherit?` to ignore stored profile overrides,
  `:internal?`, and `:strategies` to name strategies explicitly.

  Returns a map with the query text, the profile name and version, the measured
  latency, the strategies that contributed, ran empty, and were dropped, a
  pre-fusion disagreement summary, and the ranked candidates.

  Raises `ArgumentError` when the profile name is unknown, or when
  `:strategies` is supplied without `internal?: true` — hand-picked strategy
  lists are restricted to server-side and evaluation callers.
  """
  defdelegate retrieve(query, profile, opts \\ []), to: MemHouse.Retrieval.Engine

  @doc """
  Rebuilds every derived retrieval cache for one scope: knowledge embeddings,
  recall documents, entities, entity mentions, and context projections.

  Everything it writes is reconstructible from governed statements, so this is
  the recovery path after an import, an erasure, or an index change. It is
  replay-safe: running it twice produces the same caches.

  Returns `{:ok, map}` with per-stage counts, or the first error tuple from a
  stage. Raises if an underlying Ash read or write fails.
  """
  defdelegate rebuild_scope(account_id, scope_id), to: MemHouse.Retrieval.Rebuild, as: :scope

  @doc """
  Reports how many of each scope's retrievable statements carry an embedding and
  an entity mention, and under which embedding identity.

  Embeddings are written by the projection refresh alone. A scope whose refresh
  was cancelled keeps every statement and loses semantic and entity recall
  indefinitely, while full-text search — a generated column — keeps answering.
  This read is how that is noticed.

  `scope_ids` must already be authorized. `peer_id` is the reader whose view is
  being counted, and `internal_reader?` counts the whole corpus instead. Neither
  has a default, so no caller inherits system visibility by omission.

  Returns a map keyed by scope id, each value carrying `statement_count`,
  `embedded_count`, `mention_count`, `coverage`, and `embedding_identities`.
  """
  defdelegate index_coverage(account_id, scope_ids, peer_id, internal_reader?),
    to: MemHouse.Retrieval.Coverage,
    as: :scopes
end

defmodule MemHouse.Retrieval.RetrievalProfile do
  @moduledoc """
  One durable, operator-authored override of a built-in retrieval profile.

  A row overrides strategies, fusion weights, rank tie-break constant, reranking, and deadline
  for `fast`, `balanced`, or `thorough` at one scope or Account-wide when `scope_id` is nil.
  The experimental `minimal` profile is runtime-owned and deliberately cannot
  be overridden by a stored row while its rollback path is under evaluation.

  Overrides inherit down the scope tree and the nearest authorized scope wins;
  an Account-wide row is the fallback. Among the `active` rows that match a
  name and scope, the highest `version` is the one applied.

  These rows are configuration, not knowledge. `strategy_config` must not contain content or
  secrets because erasure does not inspect it.

  Changing a profile changes answers, so the version a caller sees is derived,
  not just copied: it combines the authored `version` integer with a digest of
  the strategies, weights, effective rrf_k rank constant, and rerank flag
  actually in force.
  """

  use MemHouse.Resource,
    domain: MemHouse.Retrieval,
    table: "retrieval_profiles"

  # Every read and write is rewritten to the tenant Account. There is no
  # cross-Account profile and no global default row in this table.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # `version` is accepted on create and not on update, so raising the version
    # of a tuning means inserting a row. `update` retunes an existing row's
    # strategies, weights, and deadline in place, or retires it via `active`.
    create :create do
      accept [:scope_id, :name, :version, :strategy_config, :deadline_ms, :active]
      validate MemHouse.Retrieval.ValidateRrfK
    end

    update :update do
      accept [:strategy_config, :deadline_ms, :active]
      require_atomic? false
      validate MemHouse.Retrieval.ValidateRrfK
    end
  end

  policies do
    # Cross-Account isolation: the actor's own Account id must match the row's,
    # for reads as well as writes. This policy applies to every action.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Retuning retrieval changes what every caller in the scope sees, so it is
    # an administrative act. Ordinary members and readers can only read.
    policy action_type([:create, :update, :destroy]) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    # Null means the row applies Account-wide; a value binds it to one scope.
    attribute :scope_id, :uuid
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :version, :integer, allow_nil?: false, public?: true
    # Optional keys: "strategies" (list), "weights" (map of strategy to float),
    # "rrf_k" (positive number), and "rerank" (boolean). Absent keys fall back
    # to the compiled defaults.
    attribute :strategy_config, :map, allow_nil?: false, default: %{}
    # Wall-clock ceiling in milliseconds for strategies plus reranking.
    attribute :deadline_ms, :integer, allow_nil?: false, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # One row per scope, profile name, and authored version. This is what makes
    # republishing a tuning require a version bump rather than silently
    # duplicating a competing configuration for the same scope.
    identity :scope_name_version, [:scope_id, :name, :version]
  end
end

defmodule MemHouse.Retrieval.ValidateRrfK do
  @moduledoc """
  Validates that strategy_config.rrf_k is a positive numeric value when present.

  Absent rrf_k values are permitted so compiled defaults continue to apply.
  Zero, negative, and non-numeric values are rejected before storage.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :strategy_config) do
      nil ->
        :ok

      config when is_map(config) ->
        validate_rrf_k(config)

      _other ->
        :ok
    end
  end

  defp validate_rrf_k(config) do
    case config do
      %{"rrf_k" => rrf_k} when is_number(rrf_k) and rrf_k > 0 ->
        :ok

      %{"rrf_k" => rrf_k} when is_number(rrf_k) ->
        {:error, field: :strategy_config, message: "rrf_k must be positive, got: #{rrf_k}"}

      %{"rrf_k" => rrf_k} ->
        {:error,
         field: :strategy_config,
         message: "rrf_k must be a positive number, got: #{inspect(rrf_k)}"}

      %{rrf_k: rrf_k} when is_number(rrf_k) and rrf_k > 0 ->
        :ok

      %{rrf_k: rrf_k} when is_number(rrf_k) ->
        {:error, field: :strategy_config, message: "rrf_k must be positive, got: #{rrf_k}"}

      %{rrf_k: rrf_k} ->
        {:error,
         field: :strategy_config,
         message: "rrf_k must be a positive number, got: #{inspect(rrf_k)}"}

      _no_rrf_k ->
        :ok
    end
  end
end
