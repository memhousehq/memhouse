# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Runner do
  @moduledoc """
  Runs normalized evaluation cases against the real memory API.

  Runs preserve dataset and model provenance, profile and deadline settings, strategy overrides,
  limits, and deterministic ordering. Failures remain explicit rather than being silently
  dropped from aggregate metrics.
  """

  alias MemHouse.Clock
  alias MemHouse.Eval.{ModelJudge, Reasoning, Scorer}
  alias MemHouse.Memory

  @doc """
  Runs every case in `dataset` and returns the complete evaluation report.

  `dataset` is normalized by `MemHouse.Eval.Adapter`. Options set profile, scratch
  Account, run id, deadline, strategy override, split, judge, and run limits; every choice
  is recorded in the string-keyed report.

  Non-success ingest tuples remain scored failures. Raised memory errors or invalid model
  judge results abort the run rather than producing incomplete evidence.
  """
  def run(dataset, opts \\ []) do
    profile = Keyword.get(opts, :profile, "balanced")
    account_key = Keyword.get(opts, :account_key, "eval-benchmark")
    run_id = Keyword.get(opts, :run_id) || default_run_id()
    benchmark = dataset.benchmark
    scope_root = "/bench/#{benchmark}/#{run_id}"
    deadline = Keyword.get(opts, :deadline, "disabled")

    available_cases = length(dataset.cases)

    cases =
      dataset.cases
      |> take_limit(Keyword.get(opts, :limit_cases))
      |> Enum.map(&run_case(&1, dataset, scope_root, account_key, profile, deadline, opts))

    question_results = Enum.flat_map(cases, & &1.question_results)

    accounting = accounting(available_cases, cases)

    reasoning =
      if Keyword.get(opts, :dream_time, false),
        do: cases |> Enum.map(& &1.reasoning) |> Enum.reject(&is_nil/1) |> Reasoning.merge(),
        else: nil

    %{
      "report_schema" => "f11-2",
      "memhouse_version" => memhouse_version(),
      "generated_at" => Clock.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "benchmark" => benchmark,
      "source_format" => dataset.source_format,
      "dataset" => %{
        "id" => Map.get(dataset, :dataset_id, "#{benchmark}-in-memory"),
        "sha256" => Map.get(dataset, :dataset_sha256, in_memory_fingerprint(dataset)),
        "split" => Keyword.get(opts, :split, "evaluation")
      },
      "profile" => profile,
      "profile_version" => profile_version(question_results),
      "strategies" => Keyword.get(opts, :strategies),
      "deadline" => deadline,
      "model_roles" => model_role_versions(),
      "judge" => judge_identity(opts),
      "account_key" => account_key,
      "run_id" => run_id,
      "scope_root" => scope_root,
      "limits" => limits(opts),
      "retrieval_cutoffs" => Keyword.get(opts, :retrieval_cutoffs, [10, 20, 50]),
      "accounting" => accounting,
      "available" => accounting["available"],
      "sampled" => accounting["sampled"],
      "attempted" => accounting["attempted"],
      "evaluated" => accounting["evaluated"],
      "skipped" => accounting["skipped"],
      "failed" => accounting["failed"],
      "cancelled" => accounting["cancelled"],
      "messages_attempted" => cases |> Enum.map(& &1.messages_attempted) |> Enum.sum(),
      "messages_ingested" => cases |> Enum.map(& &1.messages_ingested) |> Enum.sum(),
      "questions_attempted" => length(question_results),
      "reasoning" => reasoning,
      "metrics" => Scorer.summarize(question_results),
      "cases" => Enum.map(cases, &case_report/1)
    }
  end

  defp run_case(case, dataset, scope_root, account_key, profile, deadline, opts) do
    case Map.get(case, :metadata, %{}) |> Map.get("evaluation_status") do
      "skipped" ->
        terminal_case(case, "skipped", "filtered")

      "cancelled" ->
        terminal_case(case, "cancelled", "cancelled")

      _status ->
        try do
          run_evaluated_case(case, dataset, scope_root, account_key, profile, deadline, opts)
        rescue
          _error -> terminal_case(case, "failed", "runtime_error")
        end
    end
  end

  defp run_evaluated_case(case, dataset, scope_root, account_key, profile, deadline, opts) do
    # Each case gets its own scope. Knowledge inherits downward, so two cases sharing a
    # scope would let one case's conversation answer another case's question and quietly
    # inflate the score.
    scope_path = "#{scope_root}/#{slug(case.id)}"

    messages =
      case.messages
      |> take_limit(Keyword.get(opts, :limit_messages))

    # Ingested strictly in list order, one at a time. Recency and belief-time both derive
    # from the order turns were written in, so parallelising this would change what the
    # system remembers, not just how fast the run goes.
    ingested =
      messages
      |> Enum.map(fn message ->
        attrs =
          message
          |> Map.take([:peer_key, :session_id, :role, :content, :occurred_at])
          # Session ids are namespaced by scope so that two cases reusing the same
          # benchmark session name do not land in one conversation.
          |> Map.update!(:session_id, &"#{scope_path}:#{&1}")
          |> Map.put(:scope_path, scope_path)
          |> Map.put(:account_key, account_key)

        result =
          with {:ok, stored} <- Memory.ingest_message(attrs),
               {:ok, _knowledge} <- Memory.extract_message(stored["id"], account_key) do
            {:ok, stored}
          end

        {message, result}
      end)

    reasoning =
      if Keyword.get(opts, :dream_time, false),
        do: Reasoning.run(account_key),
        else: nil

    ref_map = build_ref_map(ingested)

    questions =
      case.questions
      |> take_limit(Keyword.get(opts, :limit_questions))

    # The denominator of the token-efficiency ratio: what a naive agent would have paid by
    # putting this case's entire conversation into the prompt instead of retrieving.
    full_context_tokens =
      messages
      |> Enum.map(&token_count(&1.content))
      |> Enum.sum()

    question_results =
      questions
      |> Enum.map(fn question ->
        {latency_ms, answer} =
          timed(fn ->
            Memory.ask(%{
              "account_key" => account_key,
              "scope_path" => scope_path,
              "question" => question.question,
              "profile" => profile,
              "deadline" => deadline,
              "strategies" => Keyword.get(opts, :strategies)
            })
          end)

        cited_refs = cited_refs(answer, ref_map, question.evidence_granularity)
        ranked_refs = ranked_refs(answer, ref_map, question.evidence_granularity)
        retrieval_cutoffs = Keyword.get(opts, :retrieval_cutoffs, [10, 20, 50])

        deterministic_score =
          Scorer.score_question(question, answer, cited_refs,
            full_context_tokens: full_context_tokens,
            retrieval: Scorer.retrieval_score(question, ranked_refs, retrieval_cutoffs)
          )

        # The model judge only ever adds "model_"-prefixed keys, so merging it over the
        # deterministic score cannot overwrite a reproducible measurement.
        score =
          if Keyword.get(opts, :judge, "deterministic") == "model" do
            Map.merge(
              deterministic_score,
              ModelJudge.score(
                question.question,
                Map.get(answer, "answer", ""),
                Map.get(answer, "candidates", [])
              )
            )
          else
            deterministic_score
          end

        Map.merge(score, %{
          "benchmark" => dataset.benchmark,
          "case_id" => case.id,
          "id" => question.id,
          "question" => question.question,
          "expected" => question.expected,
          "category" => question.category || case.category,
          "scale" => case.scale,
          "answer" => Map.get(answer, "answer"),
          "citations" => Map.get(answer, "citations", []),
          "profile_version" => Map.get(answer, "profile_version"),
          "contributed_strategies" => Map.get(answer, "contributed_strategies", []),
          "dropped_strategies" => Map.get(answer, "dropped_strategies", []),
          "latency_ms" => latency_ms
        })
      end)

    %{
      id: case.id,
      category: case.category,
      scale: case.scale,
      scope_path: scope_path,
      messages_attempted: length(messages),
      messages_ingested:
        Enum.count(ingested, fn {_message, result} -> match?({:ok, _}, result) end),
      questions_attempted: length(questions),
      question_results: question_results,
      reasoning: reasoning,
      status: "evaluated",
      reason: nil
    }
  end

  defp terminal_case(case, status, reason) do
    %{
      id: case.id,
      category: case.category,
      scale: case.scale,
      scope_path: case.scope_path,
      messages_attempted: 0,
      messages_ingested: 0,
      questions_attempted: 0,
      question_results: [],
      reasoning: nil,
      status: status,
      reason: reason
    }
  end

  # Citation scoring compares the benchmark's own evidence labels, but an answer cites
  # durable database ids. This builds the translation back: durable message id to the
  # benchmark's turn reference, and durable message id to the session that turn came from.
  # Only successful ingests are entered, so a turn that failed to write cannot be scored as
  # a citation hit for something that was never stored.
  defp build_ref_map(ingested) do
    ingested
    |> Enum.reduce(%{message_by_db_id: %{}, session_by_db_id: %{}}, fn
      {source, {:ok, %{"id" => db_id}}}, acc ->
        source_session_ref =
          source
          |> Map.get(:metadata, %{})
          |> Map.get("source_session_id", source.session_id)

        acc
        |> put_in([:message_by_db_id, db_id], source.id)
        |> put_in([:session_by_db_id, db_id], source_session_ref)

      {_source, _error}, acc ->
        acc
    end)
  end

  # Fixtures label evidence at the granularity they were built with. LongMemEval names the
  # session that holds the answer, everything else names individual turns, so the same
  # citation is resolved through a different map depending on which vocabulary applies.
  defp cited_refs(answer, ref_map, "session") do
    answer
    |> cited_source_message_ids()
    |> Enum.map(&Map.get(ref_map.session_by_db_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp cited_refs(answer, ref_map, _granularity) do
    answer
    |> cited_source_message_ids()
    |> Enum.map(&Map.get(ref_map.message_by_db_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Retrieval rank is based on every returned candidate, not only the candidates the answer
  # chose to cite. This keeps retrieval coverage independent from answer generation.
  defp ranked_refs(answer, ref_map, granularity) do
    answer
    |> Map.get("candidates", [])
    |> Enum.map(fn candidate ->
      candidate
      |> Map.get("source_message_ids", [])
      |> Enum.map(fn id ->
        if granularity == "session",
          do: Map.get(ref_map.session_by_db_id, id),
          else: Map.get(ref_map.message_by_db_id, id)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end)
  end

  # An answer cites retrieval candidates, and each candidate remembers which raw messages it
  # was derived from. Walking through that provenance is what lets a citation of derived
  # knowledge be checked against a fixture's turn-level or session-level evidence label.
  defp cited_source_message_ids(answer) do
    cited_ids = answer |> Map.get("citations", []) |> MapSet.new()

    answer
    |> Map.get("candidates", [])
    |> Enum.filter(&(Map.get(&1, "id") in cited_ids))
    |> Enum.flat_map(&Map.get(&1, "source_message_ids", []))
    |> Enum.uniq()
  end

  # Per-case detail, including the scope it wrote to, so a surprising number can be traced
  # back to the actual rows that produced it. The case's metrics are the same aggregate the
  # run-level summary computes, restricted to this case's questions.
  defp case_report(case) do
    %{
      "id" => case.id,
      "category" => case.category,
      "scale" => case.scale,
      "scope_path" => case.scope_path,
      "messages_attempted" => case.messages_attempted,
      "messages_ingested" => case.messages_ingested,
      "questions_attempted" => case.questions_attempted,
      "reasoning" => case[:reasoning],
      "status" => case.status,
      "reason" => case[:reason],
      "metrics" => Scorer.summarize(case.question_results)["overall"],
      "questions" => case.question_results
    }
  end

  # One sampled case receives exactly one terminal status. Question metrics remain a separate
  # answer-quality view, so skipped or failed cases cannot disappear from the denominator.
  defp accounting(available, cases) do
    items =
      Enum.map(cases, fn case ->
        %{"id" => case.id, "status" => case.status}
        |> maybe_reason(case[:reason])
      end)

    counts = Enum.frequencies(Enum.map(items, & &1["status"]))
    evaluated = Map.get(counts, "evaluated", 0)
    skipped = Map.get(counts, "skipped", 0)
    failed = Map.get(counts, "failed", 0)
    cancelled = Map.get(counts, "cancelled", 0)

    %{
      "available" => available,
      "sampled" => length(items),
      "attempted" => evaluated + failed + cancelled,
      "evaluated" => evaluated,
      "skipped" => skipped,
      "failed" => failed,
      "cancelled" => cancelled,
      "items" => items
    }
  end

  defp maybe_reason(item, nil), do: item
  defp maybe_reason(item, reason), do: Map.put(item, "reason", reason)

  # Collapses to a single version string when every answer ran under the same retrieval
  # profile version. Disagreement deliberately leaves a list in place, which report
  # validation rejects: a run whose questions were answered by different profile versions
  # is not one measurement and must not be quoted as one.
  defp profile_version([]), do: nil

  defp profile_version(results) do
    results
    |> Enum.map(&Map.get(&1, "profile_version"))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [version] -> version
      versions -> versions
    end
  end

  # Wall-clock milliseconds around the whole answer call — retrieval, fusion, reranking and
  # generation together. Monotonic time is used so a clock adjustment mid-run cannot
  # produce a negative or wildly inflated latency sample.
  defp timed(fun) do
    started_at = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started_at, result}
  end

  # Limits arrive from command-line switches, so both integers and numeric strings are
  # accepted. Anything unparseable means "no limit" rather than an error, because the
  # applied limits are recorded in the report and a reader can see none was in force.
  defp take_limit(values, nil), do: values
  defp take_limit(values, ""), do: values

  defp take_limit(values, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(values, limit)

  defp take_limit(values, limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {integer, ""} when integer > 0 -> Enum.take(values, integer)
      _other -> values
    end
  end

  defp take_limit(values, _limit), do: values

  # Recorded in every report: a truncated run is not comparable with a full one, and a
  # reader who cannot see the truncation will compare them anyway.
  defp limits(opts) do
    %{
      "cases" => Keyword.get(opts, :limit_cases),
      "messages_per_case" => Keyword.get(opts, :limit_messages),
      "questions_per_case" => Keyword.get(opts, :limit_questions)
    }
  end

  # A second-resolution UTC timestamp stripped to digits plus the date/zone separators, so
  # it is safe inside a scope path. Two runs started in the same second collide; pass an
  # explicit run id when running them concurrently.
  defp default_run_id do
    Clock.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9TZ]+/, "")
  end

  # The version of the code that produced the numbers. "0.0.0" only appears when the
  # application is not loaded, which means the report did not come from a real release
  # build and must not be published as one.
  defp memhouse_version do
    case Application.spec(:memhouse, :vsn) do
      nil -> "0.0.0"
      version -> to_string(version)
    end
  end

  # All five model roles are recorded, including the ones a given benchmark never invokes.
  # The configuration as a whole is what was under test, and a later reader comparing two
  # reports needs to see that an unused role was also unchanged.
  defp model_role_versions do
    :memhouse
    |> Application.fetch_env!(:model_roles)
    |> Map.new(fn {role, config} ->
      {Atom.to_string(role),
       %{
         "provider" => to_string(config.provider),
         "model" => to_string(config.model),
         "version" => to_string(config.model_version),
         "prompt_version" => to_string(config.prompt_version),
         "pipeline_version" => to_string(config.pipeline_version)
       }}
    end)
  end

  # Who scored the run. "deterministic-lexical-f11-1" names the version of the reproducible
  # lexical scoring method; if that method's formulas change, the identity must change with
  # them, which obliges a changelog entry, regenerated stored evidence, and a note in the
  # closest architecture document. The model branch resolves the live judge configuration
  # and raises if it shares a provider and model with the role that produced the answers.
  defp judge_identity(opts) do
    if Keyword.get(opts, :judge, "deterministic") == "model" do
      ModelJudge.identity()
    else
      %{"kind" => "deterministic", "method" => "deterministic-lexical-f11-1"}
    end
  end

  # A dataset built in memory has no file to hash, but a report must still carry a dataset
  # digest to be valid. Hashing the term encoding distinguishes different in-memory
  # datasets; it is not comparable with the digest the same content would get on disk.
  defp in_memory_fingerprint(dataset) do
    dataset
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Whitespace token count over the same normalization the scorer uses, so the full-context
  # size and the measured context size are counted the same way and their ratio is
  # meaningful. It is not a provider tokenizer and does not claim to match billed tokens.
  defp token_count(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s]+/u, " ")
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  # Case ids become a scope path segment, so they are reduced to lowercase alphanumerics
  # and dashes. An id that reduces to nothing still needs a segment, hence "case".
  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "case"
      slug -> slug
    end
  end
end
