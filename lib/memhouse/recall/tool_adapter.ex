# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Recall.ToolAdapter do
  @moduledoc """
  Adapts governed `MemHouse.Memory` reads to the bounded recall planner.

  This is the single owner of the planner's tool allowlist, evidence shapes,
  source and lineage permission gates, and initial call accounting. Every tool
  is read-only. The Memory facade supplies one private exact-id callback so the
  lineage tool reuses its Account, reader, scope, lifecycle, and RLS boundary;
  this module never reconstructs authority from request attributes.

  It adds no HTTP, Ash, MCP, or model-facing operation. Retrieved text remains
  evidence, and the planner still applies its independent item, token, model,
  tool-call, iteration, and elapsed budgets before answer generation.
  """

  alias MemHouse.Memory
  alias MemHouse.Recall.Planner

  @doc """
  Runs the governed read-only tool adapter for one adaptive Ask request.

  `attrs` carries the already resolved Memory request authority, `question` and
  `effort` select the planner pass, and `candidates` are the initial governed
  knowledge evidence. `opts` must provide the selected retrieval profile and version, the answer
  context limit, and the exact-id visible-knowledge callback owned by
  `MemHouse.Memory`. Medium and high effort reserve bounded answer headroom for
  genuinely new tool evidence; unused headroom is refilled from the original
  ranked candidates after planning.

  Returns `{evidence, diagnostics}`. Evidence remains subject to independent
  item, token, model-call, tool-call, iteration, and elapsed budgets. Named
  efforts add bounded profile, lineage, and knowledge tools. Lineage is enabled
  by default and `_include_lineage_recall` can disable it; source recall remains
  explicitly opt-in. Diagnostics contain counts and profile identities only,
  never query or evidence text.
  """
  def run(attrs, question, effort, candidates, opts)
      when is_map(attrs) and is_binary(question) and is_list(candidates) and is_list(opts) do
    visible_knowledge = Keyword.fetch!(opts, :visible_knowledge)
    retrieval_profile = Keyword.fetch!(opts, :retrieval_profile)
    retrieval_profile_version = Keyword.fetch!(opts, :retrieval_profile_version)
    answer_context_limit = Keyword.fetch!(opts, :answer_context_limit)

    unless is_function(visible_knowledge, 1) and is_binary(retrieval_profile) and
             is_binary(retrieval_profile_version) and is_integer(answer_context_limit) and
             answer_context_limit > 0 do
      raise ArgumentError, "invalid recall tool adapter options"
    end

    source_recall_permitted? = Map.get(attrs, "include_source_recall", false) == true
    lineage_recall_permitted? = Map.get(attrs, "_include_lineage_recall", true) == true

    tools =
      base_tools(attrs, retrieval_profile, visible_knowledge)
      |> maybe_put_lineage(attrs, lineage_recall_permitted?, visible_knowledge)
      |> maybe_put_source(attrs, source_recall_permitted?)

    base_keys = MapSet.new(candidates, &evidence_key/1)

    result =
      Planner.run(question, effort, tools,
        initial_evidence: Enum.map(candidates, &mark_knowledge_evidence/1),
        initial_item_limit: initial_item_limit(effort, answer_context_limit),
        initial_tool_calls: 1,
        initial_model_calls: 1
      )

    answer_evidence = Enum.take(result.evidence, answer_context_limit)

    diagnostics =
      result.diagnostics
      |> stringify_nested()
      |> Map.put("used", true)
      |> Map.put("retrieval_profile", retrieval_profile)
      |> Map.put("retrieval_profile_version", retrieval_profile_version)
      |> Map.put("source_recall_permitted", source_recall_permitted?)
      |> Map.put("lineage_recall_permitted", lineage_recall_permitted?)
      |> Map.put("answer_context_items", length(answer_evidence))
      |> Map.put(
        "answer_context_adaptive_items",
        Enum.count(answer_evidence, &(not MapSet.member?(base_keys, evidence_key(&1))))
      )

    {result.evidence, diagnostics}
  end

  defp base_tools(attrs, retrieval_profile, visible_knowledge) do
    %{
      profile: fn _query, _state -> identity_profile(attrs, visible_knowledge) end,
      knowledge: %{
        model_calls: 1,
        run: fn query, _state -> knowledge_search(attrs, query, retrieval_profile) end
      }
    }
  end

  defp maybe_put_lineage(tools, _attrs, false, _visible_knowledge), do: tools

  defp maybe_put_lineage(tools, attrs, true, visible_knowledge) do
    Map.put(tools, :lineage, fn _query, state ->
      lineage(attrs, state, visible_knowledge)
    end)
  end

  defp maybe_put_source(tools, _attrs, false), do: tools

  defp maybe_put_source(tools, attrs, true) do
    tools
    |> Map.put(:source_exact, fn query, _state -> source_search(attrs, query, "exact") end)
    |> Map.put(:source_semantic, %{
      model_calls: 1,
      run: fn query, _state -> source_search(attrs, query, "semantic") end
    })
  end

  defp identity_profile(attrs, visible_knowledge) do
    items =
      attrs
      |> Memory.stable_identity_profile()
      |> Map.get("items", [])

    visible_by_id =
      items
      |> Enum.map(& &1["knowledge_id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> visible_knowledge.()
      |> Map.new(&{&1["id"], &1})

    evidence =
      Enum.flat_map(items, fn item ->
        case Map.get(visible_by_id, item["knowledge_id"]) do
          nil ->
            []

          %{"source_references" => []} ->
            []

          row ->
            [
              row
              |> mark_knowledge_evidence()
              |> Map.put("candidate_type", "knowledge")
              |> Map.put("profile_category", item["category"])
              |> Map.put("profile_conflict", item["conflict"])
            ]
        end
      end)

    {:ok, evidence}
  end

  defp knowledge_search(attrs, query, retrieval_profile) do
    result =
      attrs
      |> Map.put("query", query)
      |> Map.put("profile", retrieval_profile)
      |> Map.put("_retrieval_target", "knowledge")
      |> Memory.search()

    {:ok, Enum.map(result["candidates"], &mark_knowledge_evidence/1)}
  end

  defp lineage(attrs, state, visible_knowledge) do
    case first_knowledge_id(state.evidence) do
      nil ->
        {:ok, []}

      root_id ->
        attrs
        |> Map.put("target_type", "knowledge")
        |> Map.put("target_id", root_id)
        |> Map.put("max_depth", 2)
        |> Map.put("max_fan_out", 4)
        |> Map.put("max_nodes", min(state.remaining_items + 1, 12))
        |> Memory.evidence_lineage()
        |> lineage_evidence(root_id, state.remaining_items, visible_knowledge)
    end
  end

  defp first_knowledge_id(evidence) do
    Enum.find_value(evidence, fn item ->
      type = item["evidence_type"] || item["candidate_type"]
      if type == "knowledge", do: item["id"]
    end)
  end

  defp lineage_evidence({:ok, lineage}, root_id, remaining_items, visible_knowledge) do
    ids =
      lineage["nodes"]
      |> Enum.filter(&(&1["type"] == "knowledge" and &1["id"] != root_id))
      |> Enum.map(& &1["id"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(remaining_items)

    {:ok, Enum.map(visible_knowledge.(ids), &as_lineage_knowledge_evidence/1)}
  end

  defp lineage_evidence({:error, reason}, _root_id, _remaining_items, _visible_knowledge),
    do: {:error, reason}

  defp source_search(attrs, query, mode) do
    result =
      attrs
      |> Map.put("query", query)
      |> Map.put("mode", mode)
      |> Memory.search_sources()

    if result["status"] == "failed" do
      {:error, result["failure_class"] || "source_search_failed"}
    else
      {:ok, Enum.map(result["results"], &as_source_evidence/1)}
    end
  end

  defp mark_knowledge_evidence(row), do: Map.put(row, "evidence_type", "knowledge")

  defp as_lineage_knowledge_evidence(row) do
    row
    |> mark_knowledge_evidence()
    |> Map.put("candidate_type", "knowledge")
  end

  defp as_source_evidence(row) do
    row
    |> Map.put("evidence_type", "source_message")
    |> Map.put("candidate_type", "source_message")
    |> Map.put("statement", row["excerpt"])
    |> Map.put("source_message_ids", [row["id"]])
    |> Map.put("relevant_from", nil)
    |> Map.put("relevant_until", nil)
  end

  # Preserve a meaningful ranked base slice while reserving more exploration
  # space for high effort than medium effort. The full initial page remains
  # reserved for deduplication and later refill by the planner.
  defp initial_item_limit(effort, answer_context_limit)
       when effort in [:medium, "medium"] and answer_context_limit > 1,
       do: min(div(answer_context_limit * 2 + 2, 3), answer_context_limit - 1)

  defp initial_item_limit(effort, answer_context_limit)
       when effort in [:high, "high"] and answer_context_limit > 1,
       do: min(div(answer_context_limit + 1, 2), answer_context_limit - 1)

  defp initial_item_limit(_effort, answer_context_limit), do: answer_context_limit

  defp evidence_key(item) do
    type = item["evidence_type"] || item["candidate_type"] || "knowledge"
    {type, item["id"]}
  end

  defp stringify_nested(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_nested(nested)} end)
  end

  defp stringify_nested(value) when is_list(value), do: Enum.map(value, &stringify_nested/1)

  defp stringify_nested(value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value),
       do: Atom.to_string(value)

  defp stringify_nested(value), do: value
end
