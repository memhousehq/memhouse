# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Report do
  @moduledoc """
  Validates evaluation provenance and committed release floors.

  Deterministic correctness and citation floors are gates; quality, latency, token efficiency,
  and degradation remain reported frontiers unless thresholds are deliberately changed. Report
  identity is versioned independently from the application.
  """

  # The five Account-level model roles. All of them must be identified in a report, even
  # the ones a given benchmark never invokes, because the configuration as a whole is what
  # was under test.
  @roles ~w(embedder reranker ingest_extractor dream_reasoner dialectic_agent)

  # Overall metrics that must be present and numeric for a report to be usable. Anything
  # missing here means the report cannot be compared against another one.
  @metric_keys ~w(
    accuracy
    abstention_accuracy
    citation_hit_rate
    mean_citation_recall
    mean_groundedness
    mean_context_relevance
    mean_answer_relevance
    mean_end_to_end_tokens
    mean_full_context_tokens
    mean_token_efficiency_ratio
  )

  @doc """
  Checks one report's provenance and returns every problem it has, not just the first.

  Returns `:ok`, or `{:error, messages}` where `messages` lists the failures in the order
  the fields are checked. Collecting all of them matters: a report is usually rebuilt by
  fixing what produced it, and one round trip per missing field would be needless.

  A non-map argument is itself an error, not a crash.
  """
  def validate(report) when is_map(report) do
    # Errors accumulate onto the head of the list as the checks run, so the final reverse
    # restores field order for a human reading the failure message.
    []
    |> require_schema(report)
    |> require_semver(report, version_key(report))
    |> require_datetime(report, "generated_at")
    |> require_non_empty(report, "benchmark")
    |> require_non_empty(report, "profile")
    |> require_profile_version(report)
    |> require_member(report, "deadline", ~w(enabled disabled fixed))
    |> require_strategies(report)
    |> require_limits(report)
    |> require_dataset(report)
    |> require_model_roles(report)
    |> require_judge(report)
    |> require_metrics(report)
    |> require_accounting(report)
    |> require_lifecycle(report)
    |> require_reasoning(report)
    |> require_durability(report)
    |> Enum.reverse()
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate(_report), do: {:error, ["report must be an object"]}

  # f11-1 is immutable historical evidence from the Cartulary name. Current
  # f11-2 and later reports use the MemHouse field without rewriting stored reports.
  defp version_key(%{"report_schema" => "f11-1"}), do: "cartulary_version"
  defp version_key(_report), do: "memhouse_version"

  @doc """
  Returns the report unchanged when it validates, and raises `ArgumentError` otherwise.

  The raised message lists every failure. Use this on the path that produces a report, so
  an unusable one never reaches a file or a release check.
  """
  def validate!(report) do
    case validate(report) do
      :ok ->
        report

      {:error, errors} ->
        raise ArgumentError, "invalid eval report: #{Enum.join(errors, "; ")}"
    end
  end

  @doc """
  Validates a whole matrix envelope and every report inside it, or raises `ArgumentError`.

  The envelope must declare the suite schema identity and hold a non-empty report list. An
  empty suite is rejected deliberately: a release check that accepted one would treat "the
  matrix never ran" as "the matrix found no problems".

  Returns the suite unchanged when it and all of its reports validate.
  """
  def validate_suite!(%{"report_schema" => "f11-suite-1", "reports" => reports} = suite)
      when is_list(reports) and reports != [] do
    Enum.each(reports, &validate!/1)
    suite
  end

  # The "F11" in this message is a frozen legacy tag with no current meaning; it survives only
  # because the wording of a raised message is observable behaviour and this is a documentation
  # pass. Read it as "evaluation suite".
  def validate_suite!(_suite) do
    raise ArgumentError, "invalid F11 eval suite: expected non-empty f11-suite-1 reports"
  end

  @doc """
  Asserts a report's overall metrics against the committed floors, or raises.

  `thresholds` is the decoded floors document: minimum values under a `"benchmarks"` key,
  then by benchmark, then by profile, then by metric name. Only the report's overall
  metrics are checked; per-category and per-scale rollups are reported, never gated,
  because small groups are noisy.

  Returns the report unchanged when every floor holds. Raises `ArgumentError` when no floor
  is configured for this benchmark and profile, and when any checked metric is missing,
  non-numeric, or below its minimum; the message names every metric that failed. Raises
  `KeyError` when the report states no benchmark or profile, and `FunctionClauseError` when
  `thresholds` is not a map — validate a report before asserting floors on it.
  """
  def assert_thresholds!(report, thresholds) when is_map(thresholds) do
    benchmark = Map.fetch!(report, "benchmark")
    profile = Map.fetch!(report, "profile")
    metrics = get_in(report, ["metrics", "overall"]) || %{}

    # An unconfigured combination is a failure, not a pass. Otherwise adding a benchmark to
    # the matrix without adding its floor would silently create an ungated release lane.
    expected =
      get_in(thresholds, ["benchmarks", benchmark, profile]) ||
        raise ArgumentError, "no deterministic threshold for #{benchmark}/#{profile}"

    # A missing or non-numeric metric fails the same way a low one does: the guardrail must
    # not be satisfiable by omitting the measurement it checks.
    failures =
      for {metric, minimum} <- expected,
          actual = Map.get(metrics, metric),
          not is_number(actual) or actual < minimum,
          do: "#{benchmark}/#{profile} #{metric}=#{inspect(actual)} is below #{minimum}"

    case failures do
      [] -> report
      _failures -> raise ArgumentError, "eval regression: #{Enum.join(failures, "; ")}"
    end
  end

  # f11-1 is retained as a read-only compatibility format for committed evidence. New
  # reports use f11-2 or later, whose accounting block is checked below. Historical JSON is never
  # rewritten merely to make the validator stricter.
  defp require_schema(errors, report) do
    if Map.get(report, "report_schema") in ["f11-1", "f11-2", "f11-3"],
      do: errors,
      else: ["report_schema must equal f11-1, f11-2, or f11-3" | errors]
  end

  # Semantic version syntax with an optional pre-release suffix and no build metadata. The
  # application version is how a report is tied to the code that produced it, so a
  # free-form string such as "dev" or "latest" is not acceptable evidence.
  defp require_semver(errors, report, key) do
    case Map.get(report, key) do
      value when is_binary(value) ->
        if Regex.match?(
             ~r/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/,
             value
           ),
           do: errors,
           else: ["#{key} must be semantic version syntax" | errors]

      _value ->
        ["#{key} must be semantic version syntax" | errors]
    end
  end

  defp require_datetime(errors, report, key) do
    case Map.get(report, key) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, _datetime, _offset} -> errors
          _error -> ["#{key} must be an ISO 8601 datetime" | errors]
        end

      _value ->
        ["#{key} must be an ISO 8601 datetime" | errors]
    end
  end

  defp require_non_empty(errors, report, key) do
    case Map.get(report, key) do
      value when is_binary(value) and value != "" -> errors
      _value -> ["#{key} must be a non-empty string" | errors]
    end
  end

  # Exactly one profile version, as a string. The runner leaves a list here when its
  # questions ran under different retrieval profile versions, and that list fails this
  # check on purpose: a mixed-version run must not be quoted as one measurement.
  defp require_profile_version(errors, report) do
    case Map.get(report, "profile_version") do
      value when is_binary(value) and value != "" -> errors
      _value -> ["profile_version must identify exactly one profile version" | errors]
    end
  end

  defp require_member(errors, report, key, allowed) do
    if Map.get(report, key) in allowed,
      do: errors,
      else: ["#{key} must be one of #{Enum.join(allowed, ", ")}" | errors]
  end

  # Null means an ordinary named-profile run; a non-empty list of names means the run was
  # measured with an internal strategy override and is not a product-shaped result. An
  # empty list or any other value is rejected so the two cases stay distinguishable.
  defp require_strategies(errors, %{"strategies" => nil}), do: errors

  defp require_strategies(errors, %{"strategies" => strategies})
       when is_list(strategies) and strategies != [] do
    if Enum.all?(strategies, &(is_binary(&1) and &1 != "")),
      do: errors,
      else: ["strategies must contain non-empty names" | errors]
  end

  defp require_strategies(errors, _report) do
    ["strategies must be null for a named profile or a non-empty internal override" | errors]
  end

  # All three limit keys must be present, each either null or a positive integer. Presence
  # is required even when nothing was truncated, so that "ran in full" is stated rather
  # than inferred from a missing field.
  defp require_limits(errors, report) do
    case Map.get(report, "limits") do
      %{
        "cases" => cases,
        "messages_per_case" => messages,
        "questions_per_case" => questions
      } ->
        if Enum.all?([cases, messages, questions], &(is_nil(&1) or (is_integer(&1) and &1 > 0))),
          do: errors,
          else: ["limits must be null or positive integers" | errors]

      _limits ->
        ["limits must identify cases, messages_per_case, and questions_per_case" | errors]
    end
  end

  # The digest is what lets someone else re-run the exact same input. Lowercase 64-hex is
  # enforced rather than merely "a string", because a truncated or uppercase digest would
  # compare unequal against a correctly recorded one and quietly break reproduction.
  defp require_dataset(errors, report) do
    case Map.get(report, "dataset") do
      %{"id" => id, "sha256" => sha256, "split" => split}
      when is_binary(id) and id != "" and is_binary(sha256) and is_binary(split) and split != "" ->
        if Regex.match?(~r/^[0-9a-f]{64}$/, sha256),
          do: errors,
          else: ["dataset.sha256 must be a lowercase SHA-256" | errors]

      _dataset ->
        ["dataset must include non-empty id, lowercase sha256, and split" | errors]
    end
  end

  # Every role needs its full identity: which provider, which model, which model version,
  # which prompt version, and which pipeline version. Two of those five changing is enough
  # to move a score, so a partial identity cannot support a comparison between reports.
  defp require_model_roles(errors, report) do
    roles = Map.get(report, "model_roles", %{})

    Enum.reduce(@roles, errors, fn role, acc ->
      case Map.get(roles, role) do
        %{
          "provider" => provider,
          "model" => model,
          "version" => version,
          "prompt_version" => prompt_version,
          "pipeline_version" => pipeline_version
        }
        when provider != "" and model != "" and version != "" and prompt_version != "" and
               pipeline_version != "" ->
          acc

        _role ->
          [
            "model_roles.#{role} must include exact provider/model/version/prompt/pipeline identity"
            | acc
          ]
      end
    end)
  end

  # A deterministic judge only has to name its method, because the method fully determines
  # the numbers. A model judge additionally has to name the provider, model, and model
  # version that graded the answers, since the same prompt scores differently across them.
  defp require_judge(errors, report) do
    case Map.get(report, "judge") do
      %{"kind" => "deterministic", "method" => method}
      when is_binary(method) and method != "" ->
        errors

      %{
        "kind" => "model",
        "method" => method,
        "provider" => provider,
        "model" => model,
        "model_version" => version
      }
      when method != "" and provider != "" and model != "" and version != "" ->
        errors

      _judge ->
        ["judge must identify method and exact provider/model/version when model-based" | errors]
    end
  end

  # Abstention accuracy is the only metric allowed to be null, and only because a run whose
  # questions all expect an answer genuinely has nothing to measure there. Everything else
  # must be a number; a missing metric is a broken report, not a zero.
  defp require_metrics(errors, report) do
    overall = get_in(report, ["metrics", "overall"]) || %{}

    Enum.reduce(@metric_keys, errors, fn key, acc ->
      value = Map.get(overall, key)

      if is_number(value) or (key == "abstention_accuracy" and is_nil(value)),
        do: acc,
        else: ["metrics.overall.#{key} must be numeric" | acc]
    end)
  end

  defp require_accounting(errors, %{"report_schema" => "f11-1"}), do: errors

  defp require_accounting(
         errors,
         %{"report_schema" => schema, "accounting" => accounting} = report
       )
       when schema in ["f11-2", "f11-3"] and is_map(accounting) do
    statuses = ~w(evaluated skipped failed cancelled)

    with true <- Enum.all?(statuses, &non_negative_integer?(Map.get(accounting, &1))),
         true <- non_negative_integer?(Map.get(accounting, "available")),
         true <- non_negative_integer?(Map.get(accounting, "sampled")),
         true <- non_negative_integer?(Map.get(accounting, "attempted")),
         items when is_list(items) <- Map.get(accounting, "items"),
         true <- top_level_counts_match?(report, accounting),
         true <- balanced_counts?(accounting, items, statuses),
         :ok <- valid_items?(items, statuses) do
      errors
    else
      _ ->
        [
          "accounting must balance available, sampled, attempted, statuses, and unique items"
          | errors
        ]
    end
  end

  defp require_accounting(errors, %{"report_schema" => schema}) when schema in ["f11-2", "f11-3"],
    do: ["#{schema} reports require accounting" | errors]

  # Keep validation total for pre-f11 reports that can still be decoded for inspection. They
  # will receive the normal schema/provenance errors rather than crashing the compatibility
  # reader while it reports why they are not quotable evidence.
  defp require_accounting(errors, _report), do: errors

  defp require_lifecycle(errors, %{"report_schema" => "f11-1"}), do: errors
  defp require_lifecycle(errors, %{"report_schema" => "f11-2"}), do: errors

  defp require_lifecycle(errors, %{"report_schema" => "f11-3", "lifecycle" => lifecycle})
       when is_map(lifecycle) do
    states = MemHouse.Knowledge.Lifecycle.states()
    final_states = Map.get(lifecycle, "final_states")
    absent_final = Map.get(lifecycle, "absent_final_states")
    exercised = Map.get(lifecycle, "exercised_states")
    unexercised = Map.get(lifecycle, "unexercised_states")
    unexercised_reasons = Map.get(lifecycle, "unexercised_reasons")
    transitions = Map.get(lifecycle, "transitions")
    audit_transitions = Map.get(lifecycle, "audit_transitions")
    events = Map.get(lifecycle, "lifecycle_events")
    audits = Map.get(lifecycle, "lifecycle_audit_events")

    transition_states =
      if is_list(transitions) do
        transitions
        |> Enum.flat_map(&[&1["from_state"], &1["to_state"]])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
      else
        []
      end

    valid? =
      Map.get(lifecycle, "visibility") == "internal_account_scope_all_states" and
        valid_final_state_distribution?(states, final_states, absent_final) and
        valid_exercise_distribution?(
          states,
          exercised,
          unexercised,
          unexercised_reasons,
          transition_states
        ) and
        valid_transition_evidence?(transitions, audit_transitions, events, audits)

    if valid?,
      do: errors,
      else: ["lifecycle must balance all states, transition counts, and audit events" | errors]
  end

  defp require_lifecycle(errors, %{"report_schema" => "f11-3"}),
    do: ["f11-3 reports require lifecycle evidence" | errors]

  defp require_lifecycle(errors, _report), do: errors

  defp valid_final_state_distribution?(states, final_states, absent_final) do
    is_map(final_states) and Enum.sort(Map.keys(final_states)) == Enum.sort(states) and
      Enum.all?(final_states, fn {_state, count} -> non_negative_integer?(count) end) and
      is_list(absent_final) and
      Enum.sort(absent_final) ==
        states |> Enum.filter(&(Map.get(final_states, &1) == 0)) |> Enum.sort()
  end

  defp valid_exercise_distribution?(
         states,
         exercised,
         unexercised,
         unexercised_reasons,
         transition_states
       ) do
    is_list(exercised) and Enum.sort(exercised) == Enum.sort(transition_states) and
      is_list(unexercised) and Enum.sort(unexercised) == Enum.sort(states -- exercised) and
      is_map(unexercised_reasons) and
      Enum.sort(Map.keys(unexercised_reasons)) == Enum.sort(unexercised) and
      Enum.all?(unexercised_reasons, fn {_state, reason} ->
        is_binary(reason) and reason != ""
      end)
  end

  defp valid_transition_evidence?(transitions, audit_transitions, events, audits) do
    is_list(transitions) and Enum.all?(transitions, &valid_transition_count?/1) and
      audit_transitions == transitions and non_negative_integer?(events) and events == audits and
      events == Enum.sum(Enum.map(transitions, & &1["count"]))
  end

  defp valid_transition_count?(%{
         "from_state" => from_state,
         "to_state" => to_state,
         "reason" => reason,
         "count" => count
       }) do
    valid_edge? =
      if is_nil(from_state) do
        to_state == MemHouse.Knowledge.Lifecycle.initial_state()
      else
        MemHouse.Knowledge.Lifecycle.allowed_transition?(from_state, to_state)
      end

    valid_edge? and is_binary(reason) and reason != "" and
      is_integer(count) and count > 0
  end

  defp valid_transition_count?(_transition), do: false

  # Dream-time is optional for the ordinary release matrix. When an evaluation
  # claims to have run it, this block makes its terminal accounting and replay
  # result quotable instead of leaving them as unstructured task output.
  defp require_reasoning(errors, %{"reasoning" => nil}), do: errors

  defp require_reasoning(errors, report) when not is_map_key(report, "reasoning"), do: errors

  defp require_reasoning(errors, %{"reasoning" => reasoning}) when is_map(reasoning) do
    integers = ~w(
      attempted completed throttled failed replayed replay_durable_effects
      knowledge_before knowledge_after superseded conflict_validation_items
    )

    reasoner = Map.get(reasoning, "reasoner", %{})

    if Map.get(reasoning, "enabled") == true and
         Enum.all?(integers, &non_negative_integer?(Map.get(reasoning, &1))) and
         Map.get(reasoning, "attempted") ==
           Map.get(reasoning, "completed") + Map.get(reasoning, "throttled") +
             Map.get(reasoning, "failed") and
         Map.get(reasoning, "replay_durable_effects") == 0 and
         count_map?(Map.get(reasoning, "relations")) and
         count_map?(Map.get(reasoning, "deductions")) and
         count_map?(Map.get(reasoning, "corroboration")) and
         count_map?(Map.get(reasoner, "error_classes")) and
         Enum.all?(
           ~w(calls input_tokens output_tokens latency_ms),
           &non_negative_integer?(Map.get(reasoner, &1))
         ) do
      errors
    else
      ["reasoning must balance terminal passes and show a zero-effect replay" | errors]
    end
  end

  defp require_reasoning(errors, _report),
    do: ["reasoning must be null or valid accounting" | errors]

  defp require_durability(errors, %{"durability" => nil}), do: errors
  defp require_durability(errors, report) when not is_map_key(report, "durability"), do: errors

  defp require_durability(errors, %{"durability" => durability}) when is_map(durability) do
    categories = Map.get(durability, "categories")
    message_counts = Map.get(durability, "messages")
    available = Map.get(durability, "available")
    sampled = Map.get(durability, "sampled")
    durable = Map.get(durability, "durable")
    noise = Map.get(durability, "noise")

    if non_negative_integer?(available) and non_negative_integer?(sampled) and
         sampled <= available and
         is_binary(Map.get(durability, "sample_seed")) and valid_durability_judge?(durability) and
         valid_durability_categories?(categories, sampled, durable, noise) and
         valid_message_yield?(message_counts) do
      errors
    else
      ["durability must contain balanced, content-safe audit counts" | errors]
    end
  end

  defp require_durability(errors, _report),
    do: ["durability must be null or valid audit accounting" | errors]

  defp valid_durability_judge?(%{
         "method" => "deterministic-durability-f11-1",
         "judge" => %{"kind" => "deterministic", "method" => "deterministic-durability-f11-1"}
       }),
       do: true

  defp valid_durability_judge?(%{"method" => "model-durability-f11-1", "judge" => judge})
       when is_map(judge) do
    Map.get(judge, "kind") == "model" and Map.get(judge, "method") == "model-durability-f11-1" and
      Enum.all?(
        ~w(provider model model_version prompt_version pipeline_version),
        &(is_binary(Map.get(judge, &1)) and Map.get(judge, &1) != "")
      )
  end

  defp valid_durability_judge?(_durability), do: false

  defp valid_durability_categories?(categories, sampled, durable, noise)
       when is_map(categories) do
    required =
      ~w(durable greeting_or_small_talk question speech_act_transcription subjectless_generic other_non_durable)

    Enum.all?(required, &non_negative_integer?(Map.get(categories, &1))) and
      Enum.sort(Map.keys(categories)) == Enum.sort(required) and
      Enum.sum(Enum.map(required, &Map.fetch!(categories, &1))) == sampled and
      durable == Map.get(categories, "durable") and noise == sampled - durable
  end

  defp valid_durability_categories?(_categories, _sampled, _durable, _noise), do: false

  defp valid_message_yield?(%{"zero" => zero, "one" => one, "multiple" => multiple}),
    do: Enum.all?([zero, one, multiple], &non_negative_integer?/1)

  defp valid_message_yield?(_counts), do: false

  defp count_map?(map) when is_map(map),
    do: Enum.all?(map, fn {key, value} -> is_binary(key) and non_negative_integer?(value) end)

  defp count_map?(_map), do: false

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp top_level_counts_match?(report, accounting) do
    Enum.all?(~w(available sampled attempted evaluated skipped failed cancelled), fn key ->
      Map.get(report, key) == Map.get(accounting, key)
    end)
  end

  defp balanced_counts?(accounting, items, statuses) do
    Map.get(accounting, "available") >= Map.get(accounting, "sampled") and
      Map.get(accounting, "sampled") == length(items) and
      Map.get(accounting, "sampled") == Enum.sum(Enum.map(statuses, &Map.get(accounting, &1))) and
      Map.get(accounting, "attempted") ==
        Map.get(accounting, "evaluated") + Map.get(accounting, "failed") +
          Map.get(accounting, "cancelled") and
      Enum.all?(statuses, fn status ->
        Enum.count(items, &(Map.get(&1, "status") == status)) == Map.get(accounting, status)
      end)
  end

  defp valid_items?(items, statuses) do
    ids = Enum.map(items, &Map.get(&1, "id"))
    reasons = ~w(filtered adapter_error runtime_error cancelled)

    Enum.uniq(ids) == ids and
      Enum.all?(items, fn
        %{"id" => id, "status" => status} = item when is_binary(id) and id != "" ->
          status in statuses and
            (status == "evaluated" or
               Map.get(item, "reason") in reasons)

        _item ->
          false
      end)
      |> then(fn valid -> if valid, do: :ok, else: :error end)
  end
end
