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
  Runs bounded adaptive recall through the governed read-tool allowlist.

  `attrs` carries the already resolved Memory request authority, `question` and
  `effort` select the planner pass, and `candidates` are the initial governed
  knowledge evidence. Options must provide the resolved minimal-profile flag
  and an exact-id visibility callback owned by the Memory facade.

  Returns `{evidence, diagnostics}`. Evidence is still subject to the planner's
  item, token, call, iteration, and elapsed budgets; source and lineage reads
  run only when their explicit permission gates are present.
  """
  def run(attrs, question, effort, candidates, opts)
      when is_map(attrs) and is_binary(question) and is_list(candidates) and is_list(opts) do
    minimal_recall? = Keyword.fetch!(opts, :minimal_recall?)
    visible_knowledge = Keyword.fetch!(opts, :visible_knowledge)

    unless is_boolean(minimal_recall?) and is_function(visible_knowledge, 1) do
      raise ArgumentError, "invalid recall tool adapter options"
    end

    source_recall_permitted? = Map.get(attrs, "include_source_recall", false) == true
    lineage_recall_permitted? = Map.get(attrs, "_include_lineage_recall", true) == true

    tools =
      base_tools(attrs, minimal_recall?)
      |> maybe_put_lineage(attrs, lineage_recall_permitted?, visible_knowledge)
      |> maybe_put_source(attrs, source_recall_permitted?)

    result =
      Planner.run(question, effort, tools,
        initial_evidence: Enum.map(candidates, &mark_knowledge_evidence/1),
        initial_tool_calls: 1,
        initial_model_calls: 1
      )

    diagnostics =
      result.diagnostics
      |> stringify_nested()
      |> Map.put("used", true)
      |> Map.put("source_recall_permitted", source_recall_permitted?)
      |> Map.put("lineage_recall_permitted", lineage_recall_permitted?)

    {result.evidence, diagnostics}
  end

  defp base_tools(attrs, minimal_recall?) do
    %{
      profile: fn _query, _state -> identity_profile(attrs) end,
      knowledge: %{
        model_calls: 1,
        run: fn query, _state -> knowledge_search(attrs, query, minimal_recall?) end
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

  defp identity_profile(attrs) do
    evidence =
      attrs
      |> Memory.stable_identity_profile()
      |> Map.get("items", [])
      |> Enum.map(fn item ->
        %{
          "id" => item["knowledge_id"],
          "evidence_type" => "knowledge",
          "candidate_type" => "knowledge",
          "statement" => item["statement"],
          "relevant_from" => nil,
          "relevant_until" => nil,
          "profile_category" => item["category"],
          "profile_conflict" => item["conflict"]
        }
      end)

    {:ok, evidence}
  end

  defp knowledge_search(attrs, query, minimal_recall?) do
    result =
      attrs
      |> Map.put("query", query)
      |> Map.put("profile", if(minimal_recall?, do: "minimal", else: "balanced"))
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
    |> Map.put("relevant_from", nil)
    |> Map.put("relevant_until", nil)
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
