# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Profile do
  @moduledoc """
  Resolves retrieval strategies, weights, reranking, deadline, and version.

  Starts with `:fast`, `:balanced`, or `:thorough` defaults, applies the nearest active scope
  override or Account fallback, then the deployment allowlist. Disabled strategies remain visible
  in the response. Explicit strategy lists and rerank overrides are internal-only and unknown names
  raise.

  Defaults report the `f7-1` retrieval/context contract. Overrides combine authored version with a
  settings digest for reproducibility; changing the base identity is a public contract transition.
  """

  alias MemHouse.Retrieval.RetrievalProfile

  require Ash.Query

  # Only registered strategies may run; registry changes alter behavior.
  @strategy_modules %{
    semantic: MemHouse.Retrieval.Strategies.Semantic,
    lexical: MemHouse.Retrieval.Strategies.Lexical,
    temporal: MemHouse.Retrieval.Strategies.Temporal,
    salience_recency: MemHouse.Retrieval.Strategies.SalienceRecency,
    entity_match: MemHouse.Retrieval.Strategies.EntityMatch,
    relation_expand: MemHouse.Retrieval.Strategies.RelationExpand
  }

  @doc """
  Resolves a profile name into the concrete settings one request will use.

  `name` is `:fast`, `:balanced`, or `:thorough` (strings accepted). `query`
  supplies the Account and the nearest-first scope list used to find a stored
  override. Options:

  * `:inherit?` (default true) — set false to ignore stored overrides and use
    the compiled defaults, which is what makes evaluation runs reproducible
    across Accounts.
  * `:strategies` — an explicit strategy list, permitted only together with
    `internal?: true`.
  * `:rerank` — forces reranking on or off, permitted only together with
    `internal?: true`. `nil` keeps whatever the resolved profile says, which is
    what every ordinary request uses.
  * `:internal?` (default false) — asserts the caller is server-side or an
    evaluation harness.

  Returns name, version, ordered strategies/modules, weights, rerank flag, deadline in
  milliseconds, and deployment-disabled strategies.

  Raises `ArgumentError` for an unknown profile name, an unknown strategy name,
  or a strategy list or rerank override from a non-internal caller. Raises `KeyError` if the
  profile configuration is missing a key. The override lookup reads through
  the resource layer as the query's actor, so it is Account-scoped and
  authorization-checked like any other read.
  """
  def resolve(name, query, opts \\ []) do
    name = normalize_name(name)
    base = runtime_profile(name)

    configured =
      if Keyword.get(opts, :inherit?, true) do
        inherited_profile(name, query)
      end

    profile = merge_persisted(base, configured)
    enabled = enabled_strategy_names()
    internal? = Keyword.get(opts, :internal?, false)

    requested =
      case {Keyword.get(opts, :strategies), internal?} do
        {nil, _internal?} ->
          profile.strategies

        {strategies, true} ->
          Enum.map(strategies, &normalize_strategy!/1)

        {_strategies, false} ->
          raise ArgumentError, "raw retrieval strategies are restricted to internal/eval callers"
      end

    rerank =
      case {Keyword.get(opts, :rerank), internal?} do
        {nil, _internal?} ->
          profile.rerank

        {rerank, true} when is_boolean(rerank) ->
          rerank

        _forbidden ->
          raise ArgumentError, "the rerank override is restricted to internal/eval callers"
      end

    # Deployment allowlisting is final; report removals as disabled.
    selected = Enum.filter(requested, &(&1 in enabled))
    disabled = requested -- selected

    Map.merge(profile, %{
      name: name,
      rerank: rerank,
      strategies: selected,
      strategy_modules: Enum.map(selected, &Map.fetch!(@strategy_modules, &1)),
      disabled_strategies: disabled
    })
  end

  @doc """
  Returns the module implementing a strategy name, accepting an atom or string.

  Raises `ArgumentError` for an unregistered name.
  """
  def module(name), do: Map.fetch!(@strategy_modules, normalize_strategy!(name))

  @doc "Returns every registered strategy name, for validation and reporting."
  def strategy_names, do: Map.keys(@strategy_modules)

  # Nearest scope's highest active version wins; Account-wide is fallback, not another layer.
  defp inherited_profile(name, query) do
    records =
      RetrievalProfile
      |> Ash.Query.filter(name == ^Atom.to_string(name) and active == true)
      |> Ash.Query.sort(version: :desc)
      |> Ash.Query.set_tenant(query.account_id)
      |> Ash.read!(actor: query.actor)

    Enum.find_value(query.scope_ids, fn scope_id ->
      Enum.find(records, &(&1.scope_id == scope_id))
    end) || Enum.find(records, &is_nil(&1.scope_id))
  end

  # Omitted tuning fields inherit defaults; persisted deadline is required.
  defp merge_persisted(base, nil), do: base

  defp merge_persisted(base, record) do
    config = stringify_keys(record.strategy_config)

    strategies =
      config
      |> Map.get("strategies", base.strategies)
      |> Enum.map(&normalize_strategy!/1)

    weights =
      config
      |> Map.get("weights", base.weights)
      |> Map.new(fn {key, value} -> {normalize_strategy!(key), value * 1.0} end)

    # A 10-hex-character (40-bit) tuning digest disambiguates authored versions.
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary({strategies, weights, config["rerank"]}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 10)

    %{
      base
      | version: "f7-#{record.version}-#{digest}",
        strategies: strategies,
        weights: weights,
        rerank: Map.get(config, "rerank", base.rerank),
        deadline_ms: record.deadline_ms
    }
  end

  # Missing profile configuration is a deployment error, never a silent default.
  defp runtime_profile(name) do
    config = Application.fetch_env!(:memhouse, :retrieval_profiles)
    values = config |> Keyword.fetch!(name) |> Map.new()

    %{
      name: name,
      version: Map.fetch!(values, :version),
      strategies: Map.fetch!(values, :strategies),
      weights: Map.fetch!(values, :weights),
      rerank: Map.fetch!(values, :rerank),
      deadline_ms: Map.fetch!(values, :deadline_ms)
    }
  end

  defp enabled_strategy_names do
    :memhouse
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(:enabled_strategies)
    |> Enum.map(&normalize_strategy!/1)
  end

  # Convert only known names; unknown input raises and cannot create atoms.
  defp normalize_name(name) when name in [:fast, :balanced, :thorough], do: name

  defp normalize_name(name) when is_binary(name) do
    case name do
      "fast" -> :fast
      "balanced" -> :balanced
      "thorough" -> :thorough
      _other -> raise ArgumentError, "unknown retrieval profile: #{inspect(name)}"
    end
  end

  defp normalize_name(name),
    do: raise(ArgumentError, "unknown retrieval profile: #{inspect(name)}")

  defp normalize_strategy!(name) when is_atom(name) and is_map_key(@strategy_modules, name),
    do: name

  defp normalize_strategy!(name) when is_binary(name) do
    Enum.find(Map.keys(@strategy_modules), &(Atom.to_string(&1) == name)) ||
      raise ArgumentError, "unknown retrieval strategy: #{inspect(name)}"
  end

  defp normalize_strategy!(name),
    do: raise(ArgumentError, "unknown retrieval strategy: #{inspect(name)}")

  # Normalize persisted atom/string keys recursively.
  defp stringify_keys(map) do
    Map.new(map || %{}, fn {key, value} ->
      {to_string(key), if(is_map(value), do: stringify_keys(value), else: value)}
    end)
  end
end
