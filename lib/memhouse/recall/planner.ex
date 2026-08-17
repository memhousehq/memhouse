# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Recall.Planner do
  @moduledoc """
  Bounded read-only recall state machine used by difficult Ask requests.

  The planner has a closed tool allowlist and no write capability. Query
  playbooks are deterministic, independently named, and treat retrieved text as
  evidence rather than instructions. Stable `{type, id}` keys deduplicate all
  admitted evidence before it can be billed or supplied to answer generation.
  Every tool runs only for the whole-planner budget that remains; a late tool is
  killed and recorded as a content-free timeout rather than overrunning the
  selected effort.
  """

  alias MemHouse.Clock

  @tools [:knowledge, :source_exact, :source_semantic, :profile, :lineage]
  @stop_words MapSet.new(
                ~w(a an and are as at be by did do does for from how i in is it me my of on or our the to was what when where which who why with)
              )

  @doc """
  Runs one named effort preset against read-only tool functions.

  Each tool is `fn query, state -> {:ok, evidence} | {:error, reason} end`.
  Unknown tools are ignored rather than made callable. Options may seed already
  retrieved evidence and its charged tool-call count.
  """
  def run(question, effort, tools, opts \\ []) when is_binary(question) and is_map(tools) do
    effort = normalize_effort(effort)
    limits = :memhouse |> Application.fetch_env!(:recall_planner) |> Keyword.fetch!(effort)
    started_at = Clock.monotonic_ms()
    initial = Keyword.get(opts, :initial_evidence, [])

    state = %{
      evidence: dedupe(initial),
      seen: initial |> dedupe() |> MapSet.new(&evidence_key/1),
      calls: Keyword.get(opts, :initial_tool_calls, 0),
      query_tokens: 0,
      outcomes: [],
      seen_calls: MapSet.new(),
      exhausted: [],
      started_at: started_at,
      limits: limits,
      playbook: classify(question),
      effort: effort
    }

    state =
      question
      |> schedule(state.playbook)
      |> Enum.reduce_while(state, fn step, state ->
        case execute_step(step, tools, state) do
          {:cont, state} -> {:cont, state}
          {:halt, state} -> {:halt, state}
        end
      end)

    elapsed_ms = Clock.monotonic_ms() - started_at

    diagnostics = %{
      effort: Atom.to_string(effort),
      playbook: Atom.to_string(state.playbook),
      tool_calls: state.calls,
      model_calls: 0,
      query_tokens: state.query_tokens,
      elapsed_ms: elapsed_ms,
      item_count: length(state.evidence),
      exhausted: state.exhausted |> Enum.reverse() |> Enum.uniq(),
      outcomes: Enum.reverse(state.outcomes)
    }

    :telemetry.execute(
      [:memhouse, :recall, :planner],
      %{
        elapsed_ms: diagnostics.elapsed_ms,
        tool_calls: diagnostics.tool_calls,
        model_calls: diagnostics.model_calls,
        query_tokens: diagnostics.query_tokens,
        item_count: diagnostics.item_count
      },
      %{
        effort: diagnostics.effort,
        playbook: diagnostics.playbook,
        exhausted: diagnostics.exhausted,
        exhausted?: diagnostics.exhausted != []
      }
    )

    %{
      evidence: state.evidence,
      diagnostics: diagnostics
    }
  end

  defp execute_step(%{iteration: iteration} = step, tools, state) do
    cond do
      iteration > state.limits.max_iterations ->
        {:halt, exhaust(state, "iterations")}

      state.calls >= state.limits.max_tool_calls ->
        {:halt, exhaust(state, "tool_calls")}

      length(state.evidence) >= state.limits.max_items ->
        {:halt, exhaust(state, "items")}

      Clock.monotonic_ms() - state.started_at >= state.limits.max_elapsed_ms ->
        {:halt, exhaust(state, "elapsed")}

      step.tool not in @tools or not is_function(tools[step.tool], 2) ->
        {:cont, state}

      true ->
        execute_allowed(step, tools[step.tool], state)
    end
  end

  defp execute_allowed(step, tool, state) do
    call_key = {step.tool, step.query}
    tokens = estimate_tokens(step.query)

    cond do
      MapSet.member?(state.seen_calls, call_key) ->
        {:cont, state}

      state.query_tokens + tokens > state.limits.max_query_tokens ->
        {:halt, exhaust(state, "query_tokens")}

      true ->
        started_at = Clock.monotonic_ms()

        remaining_ms =
          max(state.limits.max_elapsed_ms - (started_at - state.started_at), 1)

        public_state = %{
          evidence: state.evidence,
          remaining_items: state.limits.max_items - length(state.evidence)
        }

        {result, timed_out?} = call_tool(tool, step.query, public_state, remaining_ms)
        elapsed_ms = Clock.monotonic_ms() - started_at

        state = %{
          state
          | calls: state.calls + 1,
            query_tokens: state.query_tokens + tokens,
            seen_calls: MapSet.put(state.seen_calls, call_key)
        }

        case {result, timed_out?} do
          {{:error, :timeout}, true} ->
            outcome = outcome(step, "failed", "timeout", elapsed_ms, 0)

            state =
              state
              |> Map.update!(:outcomes, &[outcome | &1])
              |> exhaust("elapsed")

            {:halt, state}

          {{:ok, items}, false} when is_list(items) ->
            admit(items, step, elapsed_ms, state)

          {{:error, reason}, false} ->
            outcome = outcome(step, "failed", classify_error(reason), elapsed_ms, 0)
            {:cont, %{state | outcomes: [outcome | state.outcomes]}}

          {_invalid, false} ->
            outcome = outcome(step, "failed", "invalid_result", elapsed_ms, 0)
            {:cont, %{state | outcomes: [outcome | state.outcomes]}}
        end
    end
  end

  defp call_tool(tool, query, public_state, timeout_ms) do
    [result] =
      Task.async_stream(
        [:run],
        fn :run -> tool.(query, public_state) end,
        max_concurrency: 1,
        ordered: true,
        timeout: timeout_ms,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    case result do
      {:ok, value} -> {value, false}
      {:exit, :timeout} -> {{:error, :timeout}, true}
      {:exit, _reason} -> {{:error, :tool_error}, false}
    end
  end

  defp admit(items, step, elapsed_ms, state) do
    {evidence, seen, admitted} =
      Enum.reduce(items, {state.evidence, state.seen, 0}, fn item, {evidence, seen, count} ->
        key = evidence_key(item)

        cond do
          is_nil(key) or MapSet.member?(seen, key) ->
            {evidence, seen, count}

          length(evidence) >= state.limits.max_items ->
            {evidence, seen, count}

          true ->
            {evidence ++ [item], MapSet.put(seen, key), count + 1}
        end
      end)

    outcome = outcome(step, "completed", nil, elapsed_ms, admitted)
    state = %{state | evidence: evidence, seen: seen, outcomes: [outcome | state.outcomes]}

    if length(evidence) >= state.limits.max_items,
      do: {:halt, exhaust(state, "items")},
      else: {:cont, state}
  end

  defp schedule(question, playbook) do
    exact = exact_terms(question)
    refinement = refinement(playbook, exact)

    [
      %{iteration: 1, tool: :profile, query: question},
      %{iteration: 1, tool: :source_exact, query: exact},
      %{iteration: 1, tool: :source_semantic, query: question},
      %{iteration: 2, tool: :knowledge, query: refinement},
      %{iteration: 2, tool: :lineage, query: question},
      %{iteration: 2, tool: :source_exact, query: refinement},
      %{iteration: 3, tool: :knowledge, query: exact},
      %{iteration: 3, tool: :source_semantic, query: refinement},
      %{iteration: 3, tool: :lineage, query: refinement}
    ]
  end

  defp classify(question) do
    normalized = String.downcase(question)

    cond do
      Regex.match?(~r/\b(latest|current|change|changed|update|new now)\b/, normalized) ->
        :updates

      Regex.match?(~r/\b(prefer|preference|favorite|favourite|likes?)\b/, normalized) ->
        :preferences

      Regex.match?(~r/\b(list|all|every|how many|which)\b/, normalized) ->
        :enumeration

      Regex.match?(~r/\b(summarize|summary|overview|recap)\b/, normalized) ->
        :summary

      Regex.match?(~r/\b(contradict|conflict|disagree|inconsistent)\b/, normalized) ->
        :contradictions

      Regex.match?(~r/\b(when|before|after|during|date|time|first|last)\b/, normalized) ->
        :temporal

      true ->
        :direct
    end
  end

  defp refinement(:updates, terms), do: "latest current " <> terms
  defp refinement(:preferences, terms), do: "preference prefers " <> terms
  defp refinement(:enumeration, terms), do: "all list " <> terms
  defp refinement(:summary, terms), do: "summary overview " <> terms
  defp refinement(:contradictions, terms), do: "contradiction conflicting " <> terms
  defp refinement(:temporal, terms), do: "when timeline " <> terms
  defp refinement(:direct, terms), do: terms

  defp exact_terms(question) do
    terms =
      question
      |> String.downcase()
      |> String.replace(~r/[^\p{L}\p{N}_-]+/u, " ")
      |> String.split()
      |> Enum.reject(&MapSet.member?(@stop_words, &1))
      |> Enum.uniq()
      |> Enum.take(8)

    case terms do
      [] -> String.trim(question)
      terms -> Enum.join(terms, " or ")
    end
  end

  defp dedupe(items) do
    items
    |> Enum.reduce({[], MapSet.new()}, fn item, {items, seen} ->
      key = evidence_key(item)

      if is_nil(key) or MapSet.member?(seen, key),
        do: {items, seen},
        else: {items ++ [item], MapSet.put(seen, key)}
    end)
    |> elem(0)
  end

  defp evidence_key(item) when is_map(item) do
    id = item["id"] || item[:id]
    type = item["evidence_type"] || item[:evidence_type] || item["candidate_type"] || "knowledge"
    if is_binary(id), do: {to_string(type), id}
  end

  defp evidence_key(_item), do: nil

  defp estimate_tokens(query), do: max(div(String.length(query) + 3, 4), 1)

  defp query_key(query) do
    :crypto.hash(:sha256, query)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp outcome(step, status, reason, elapsed_ms, admitted) do
    %{
      tool: Atom.to_string(step.tool),
      query_key: query_key(step.query),
      iteration: step.iteration,
      status: status,
      reason_class: reason,
      elapsed_ms: elapsed_ms,
      admitted_items: admitted
    }
  end

  defp exhaust(state, reason), do: %{state | exhausted: [reason | state.exhausted]}

  defp classify_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_error({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_error(_), do: "tool_error"

  defp normalize_effort(effort) when effort in [:low, "low"], do: :low
  defp normalize_effort(effort) when effort in [:medium, "medium"], do: :medium
  defp normalize_effort(effort) when effort in [:high, "high"], do: :high

  defp normalize_effort(effort),
    do: raise(ArgumentError, "unknown recall effort: #{inspect(effort)}")
end
