# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ComponentBindings do
  @moduledoc """
  Resolves the closed execute-time component contract for one evaluation variant.

  Bindings are derived from the same variant fields that drive `MemHouse.Eval.Runner`.
  They are not descriptive labels: an unknown key or a value that differs from the
  executable behavior makes the definition invalid before any durable work starts.
  """

  @keys ~w(
    retrieval_profile
    retrieval_strategies
    retrieval_seeds
    retrieval_rerank
    retrieval_deadline
    extraction_batching
    adaptive_recall_effort
    source_recall
    lineage_recall
    semantic_index_refresh
    recall_projection_refresh
    idle_dream_scheduling
    dream_time
    durability_audit
  )

  @efforts ~w(fixed low medium high)

  @doc "Returns the only component keys accepted by execute definitions."
  def keys, do: @keys

  @doc "Returns the exact executable component map for `variant`."
  def resolve!(variant) when is_map(variant) do
    profile = profile_configuration!(variant["profile"])
    strategies = effective_strategies!(variant, profile)
    effort = Map.get(variant, "recall_effort", "fixed")
    deadline = Map.get(variant, "deadline", "disabled")

    unless deadline in ["enabled", "disabled"] do
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} deadline must be enabled or disabled"
    end

    unless effort in @efforts do
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} recall_effort must be one of #{Enum.join(@efforts, ", ")}"
    end

    extraction_batching = boolean!(variant, "extraction_batching", false)
    source_recall = boolean!(variant, "source_recall", false)
    lineage_recall = boolean!(variant, "lineage_recall", effort != "fixed")
    idle_dream_scheduling = boolean!(variant, "idle_dream_scheduling", false)
    dream_time = boolean!(variant, "dream_time", false)
    durability_audit = boolean!(variant, "durability_audit", false)

    if effort == "fixed" and (source_recall or lineage_recall) do
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} cannot enable source or lineage recall with fixed effort"
    end

    semantic_default = Enum.any?(strategies, &semantic_strategy?/1)
    projection_default = "semantic_dual_lane" in strategies

    %{
      "retrieval_profile" => variant["profile"],
      "retrieval_strategies" => strategies,
      "retrieval_seeds" => seed_strategies(strategies),
      "retrieval_rerank" => profile.rerank,
      "retrieval_deadline" => deadline,
      "extraction_batching" => extraction_batching(extraction_batching),
      "adaptive_recall_effort" => effort,
      "source_recall" => source_recall,
      "lineage_recall" => lineage_recall,
      "semantic_index_refresh" => boolean!(variant, "semantic_index_refresh", semantic_default),
      "recall_projection_refresh" =>
        boolean!(variant, "recall_projection_refresh", projection_default),
      "idle_dream_scheduling" => idle_dream_scheduling(idle_dream_scheduling),
      "dream_time" => dream_time,
      "durability_audit" => durability_audit
    }
  end

  @doc "Rejects a component map that is not exactly the executable map."
  def validate!(variant) when is_map(variant) do
    expected = resolve!(variant)
    actual = variant["components"]

    if actual != expected do
      unsupported = if is_map(actual), do: Map.keys(actual) -- @keys, else: []

      detail =
        if unsupported == [],
          do: "must equal #{inspect(expected)}",
          else: "declares unsupported component keys #{inspect(Enum.sort(unsupported))}"

      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} component bindings #{detail}"
    end

    expected
  end

  defp boolean!(variant, key, default) do
    value = Map.get(variant, key, default)

    if is_boolean(value) do
      value
    else
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} #{key} must be boolean"
    end
  end

  defp extraction_batching(enabled?) do
    configured = MemHouse.Pipeline.ExtractionAdmission.config() |> Map.new()

    %{
      "enabled" => enabled?,
      "identity" => configured.identity,
      "tokenizer" => configured.tokenizer,
      "target_tokens" => configured.target_tokens,
      "max_anchors" => configured.max_anchors,
      "context_limit_tokens" => configured.context_limit_tokens,
      "reserved_output_tokens" => configured.reserved_output_tokens,
      "safety_margin_tokens" => configured.safety_margin_tokens,
      "claim_timeout_seconds" => configured.claim_timeout_seconds
    }
  end

  defp idle_dream_scheduling(enabled?) do
    configured = Application.fetch_env!(:memhouse, :dream_time_gates) |> Map.new()

    %{
      "enabled" => enabled?,
      "min_changes" => configured.min_changes,
      "idle_seconds" => configured.idle_seconds,
      "min_interval_seconds" => configured.min_interval_seconds,
      "max_delta_items" => configured.max_delta_items,
      "max_working_set_items" => configured.max_working_set_items,
      "max_elapsed_ms" => configured.max_elapsed_ms
    }
  end

  defp seed_strategies(strategies) do
    Enum.filter(strategies, fn name ->
      module = MemHouse.Retrieval.Profile.module(name)
      module.stage() == :seed
    end)
  end

  defp effective_strategies!(variant, profile) do
    strategies = variant["strategies"] || Enum.map(profile.strategies, &Atom.to_string/1)
    registered = Enum.map(MemHouse.Retrieval.Profile.strategy_names(), &Atom.to_string/1)

    case strategies -- registered do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown retrieval strategies: #{inspect(unknown)}"
    end

    enabled =
      :memhouse
      |> Application.fetch_env!(:retrieval_profiles)
      |> Keyword.fetch!(:enabled_strategies)
      |> Enum.map(&Atom.to_string/1)

    case strategies -- enabled do
      [] ->
        strategies

      disabled ->
        raise ArgumentError,
              "execute variant #{inspect(variant["id"])} requires deployment-disabled strategies #{inspect(disabled)}"
    end
  end

  defp semantic_strategy?(strategy), do: strategy in ["semantic", "semantic_dual_lane"]

  defp profile_configuration!(name) do
    name = profile_name!(name)

    :memhouse
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(name)
    |> Map.new()
  end

  defp profile_name!("fast"), do: :fast
  defp profile_name!("balanced"), do: :balanced
  defp profile_name!("thorough"), do: :thorough
  defp profile_name!("minimal"), do: :minimal

  defp profile_name!(name),
    do: raise(ArgumentError, "unknown retrieval profile: #{inspect(name)}")
end
