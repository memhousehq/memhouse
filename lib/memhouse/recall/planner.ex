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

  Each tool is either `fn query, state -> result end` or a map with `:run` and
  the maximum `:model_calls` it can spend. Unknown tools are ignored rather
  than made callable. Options may seed already retrieved evidence and its
  charged tool- and model-call counts. `:initial_item_limit` may admit only the
  ranked head before tools run; the remaining initial items are still reserved
  for deduplication and refill unused capacity after planning.
  """
  def run(question, effort, tools, opts \\ []) when is_binary(question) and is_map(tools) do
    effort = normalize_effort(effort)
    limits = :memhouse |> Application.fetch_env!(:recall_planner) |> Keyword.fetch!(effort)
    started_at = Clock.monotonic_ms()
    initial = Keyword.get(opts, :initial_evidence, [])

    {initial, deferred_initial, seen, evidence_tokens, initial_exhausted} =
      admit_initial(initial, limits, Keyword.get(opts, :initial_item_limit, limits.max_items))

    state = %{
      evidence: initial,
      deferred_initial: deferred_initial,
      seen: seen,
      calls: Keyword.get(opts, :initial_tool_calls, 0),
      model_calls: Keyword.get(opts, :initial_model_calls, 0),
      query_tokens: 0,
      evidence_tokens: evidence_tokens,
      outcomes: [],
      seen_calls: MapSet.new(),
      exhausted: initial_exhausted,
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

    state = refill_deferred_initial(state)

    elapsed_ms = Clock.monotonic_ms() - started_at

    diagnostics = %{
      effort: Atom.to_string(effort),
      playbook: Atom.to_string(state.playbook),
      tool_calls: state.calls,
      model_calls: state.model_calls,
      query_tokens: state.query_tokens,
      evidence_tokens: state.evidence_tokens,
      tokens: state.query_tokens + state.evidence_tokens,
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
        evidence_tokens: diagnostics.evidence_tokens,
        tokens: diagnostics.tokens,
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

      step.tool not in @tools or is_nil(tool_entry(tools[step.tool])) ->
        {:cont, state}

      true ->
        execute_allowed(step, tool_entry(tools[step.tool]), state)
    end
  end

  defp execute_allowed(step, {tool, cost}, state) do
    call_key = {step.tool, step.query}
    tokens = estimate_tokens(step.query)

    cond do
      MapSet.member?(state.seen_calls, call_key) ->
        {:cont, state}

      state.query_tokens + tokens > state.limits.max_query_tokens ->
        {:halt, exhaust(state, "query_tokens")}

      state.query_tokens + state.evidence_tokens + tokens > state.limits.max_total_tokens ->
        {:halt, exhaust(state, "tokens")}

      state.model_calls + cost.model_calls > state.limits.max_model_calls ->
        {:halt, exhaust(state, "model_calls")}

      true ->
        started_at = Clock.monotonic_ms()

        remaining_ms =
          max(state.limits.max_elapsed_ms - (started_at - state.started_at), 1)

        public_state = %{
          evidence: state.evidence,
          remaining_items: state.limits.max_items - length(state.evidence),
          remaining_model_calls: state.limits.max_model_calls - state.model_calls,
          remaining_tokens:
            state.limits.max_total_tokens - state.query_tokens - state.evidence_tokens
        }

        {result, timed_out?} = call_tool(tool, step.query, public_state, remaining_ms)
        elapsed_ms = Clock.monotonic_ms() - started_at

        state = %{
          state
          | calls: state.calls + 1,
            model_calls: state.model_calls + cost.model_calls,
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
    {evidence, seen, admitted, evidence_tokens, token_limited?} =
      Enum.reduce(
        items,
        {state.evidence, state.seen, 0, state.evidence_tokens, false},
        fn item, {evidence, seen, count, evidence_tokens, token_limited?} ->
          key = evidence_key(item)
          item_tokens = estimate_tokens(item)

          cond do
            is_nil(key) or MapSet.member?(seen, key) ->
              {evidence, seen, count, evidence_tokens, token_limited?}

            length(evidence) >= state.limits.max_items ->
              {evidence, seen, count, evidence_tokens, token_limited?}

            state.query_tokens + evidence_tokens + item_tokens > state.limits.max_total_tokens ->
              {evidence, seen, count, evidence_tokens, true}

            true ->
              {evidence ++ [item], MapSet.put(seen, key), count + 1,
               evidence_tokens + item_tokens, token_limited?}
          end
        end
      )

    outcome = outcome(step, "completed", nil, elapsed_ms, admitted)

    state = %{
      state
      | evidence: evidence,
        seen: seen,
        evidence_tokens: evidence_tokens,
        outcomes: [outcome | state.outcomes]
    }

    cond do
      length(evidence) >= state.limits.max_items -> {:halt, exhaust(state, "items")}
      token_limited? -> {:halt, exhaust(state, "tokens")}
      true -> {:cont, state}
    end
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
      Regex.match?(~r/\b(latest|current|change|changed|update|new|now)\b/, normalized) ->
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

  defp admit_initial(items, limits, initial_item_limit)
       when is_integer(initial_item_limit) and initial_item_limit >= 0 do
    items
    |> Enum.reduce({[], [], MapSet.new(), 0, []}, fn item,
                                                     {items, deferred, seen, tokens, exhausted} ->
      key = evidence_key(item)
      item_tokens = estimate_tokens(item)

      cond do
        is_nil(key) or MapSet.member?(seen, key) ->
          {items, deferred, seen, tokens, exhausted}

        length(items) >= limits.max_items ->
          {items, deferred, MapSet.put(seen, key), tokens, ["items" | exhausted]}

        length(items) >= initial_item_limit ->
          {items, deferred ++ [item], MapSet.put(seen, key), tokens, exhausted}

        tokens + item_tokens > limits.max_total_tokens ->
          {items, deferred, MapSet.put(seen, key), tokens, ["tokens" | exhausted]}

        true ->
          {items ++ [item], deferred, MapSet.put(seen, key), tokens + item_tokens, exhausted}
      end
    end)
  end

  defp admit_initial(_items, _limits, initial_item_limit) do
    raise ArgumentError,
          "initial_item_limit must be a non-negative integer, got: #{inspect(initial_item_limit)}"
  end

  # Initial candidates outside the ranked head remain reserved in `seen` while
  # tools execute. A rewritten knowledge query therefore cannot reclassify the
  # same base-page item as adaptive evidence. Once planning stops, the deferred
  # tail fills only capacity that tools did not use and remains subject to the
  # same item and total-token ceilings.
  defp refill_deferred_initial(state) do
    Enum.reduce_while(state.deferred_initial, state, fn item, state ->
      item_tokens = estimate_tokens(item)

      cond do
        length(state.evidence) >= state.limits.max_items ->
          {:halt, exhaust(state, "items")}

        state.query_tokens + state.evidence_tokens + item_tokens > state.limits.max_total_tokens ->
          {:halt, exhaust(state, "tokens")}

        true ->
          {:cont,
           %{
             state
             | evidence: state.evidence ++ [item],
               evidence_tokens: state.evidence_tokens + item_tokens
           }}
      end
    end)
  end

  defp evidence_key(item) when is_map(item) do
    id = item["id"] || item[:id]
    type = item["evidence_type"] || item[:evidence_type] || item["candidate_type"] || "knowledge"
    if is_binary(id), do: {to_string(type), id}
  end

  defp evidence_key(_item), do: nil

  defp estimate_tokens(value) when is_binary(value),
    do: max(div(byte_size(value) + 3, 4), 1)

  defp estimate_tokens(value),
    do: value |> Jason.encode!() |> estimate_tokens()

  defp tool_entry(tool) when is_function(tool, 2), do: {tool, %{model_calls: 0}}

  defp tool_entry(%{run: tool, model_calls: model_calls})
       when is_function(tool, 2) and is_integer(model_calls) and model_calls >= 0,
       do: {tool, %{model_calls: model_calls}}

  defp tool_entry(_tool), do: nil

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
