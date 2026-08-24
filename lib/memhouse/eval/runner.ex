# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Runner do
  @moduledoc """
  Runs normalized evaluation cases against the real memory API.

  Runs preserve dataset and model provenance, profile and deadline settings, strategy overrides,
  adaptive-recall permissions, cache refreshes, limits, and deterministic ordering. Failures
  remain explicit rather than being silently dropped from aggregate metrics.
  """

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Eval.{Durability, Ingest, LifecycleEvidence, ModelJudge, Reasoning, Scorer}
  alias MemHouse.Memory
  alias MemHouse.Retrieval.{Indexer, RecallProjector, SourceIndexer}
  alias MemHouse.Topology.Scope

  require Ash.Query

  @doc """
  Runs every case in `dataset` and returns the complete evaluation report.

  `dataset` is normalized by `MemHouse.Eval.Adapter`. Options set profile, scratch
  Account, run id, deadline, strategy override, split, judge, and run limits; every choice
  is recorded in the string-keyed report. `:refresh_semantic_index`,
  `:refresh_source_semantic_index`, and `:refresh_recall_projection` synchronously rebuild their
  distinct caches before questions and are intended only for isolated profile experiments.
  `:idle_dream_scheduling` executes real generation-fenced pipeline work and therefore requires
  two active direct generations already present in each exact case scope. A question may set
  `metadata.peer_key` to evaluate the governed view and stable profile for that
  already-ingested Peer; omitting it retains the internal Account reader.

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
    refresh = merge_refresh(cases)

    accounting = accounting(available_cases, cases)
    lifecycle = LifecycleEvidence.snapshot(account_key, Enum.map(cases, & &1.scope_path))

    reasoning =
      if Keyword.get(opts, :dream_time, false),
        do: cases |> Enum.map(& &1.reasoning) |> Enum.reject(&is_nil/1) |> Reasoning.merge(),
        else: nil

    durability =
      if Keyword.get(opts, :durability_audit, false),
        do:
          cases
          |> Enum.flat_map(& &1.extractions)
          |> Durability.audit(
            judge: Keyword.get(opts, :durability_judge, "deterministic"),
            sample: Keyword.get(opts, :durability_sample),
            seed: Keyword.get(opts, :durability_seed, "durability-audit-v1")
          ),
        else: nil

    %{
      "report_schema" => "f11-3",
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
      "components" => Keyword.get(opts, :components, %{}),
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
      "refresh" => refresh,
      "durability" => durability,
      "lifecycle" => lifecycle,
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

    # Raw commits remain in fixture order. The experimental batch path may consume adjacent
    # durable extraction runs with one provider call, but it never reorders observations or
    # bypasses their ordinary governance writes.
    ingested = Ingest.run(messages, account_key, scope_path, opts)

    reasoning =
      cond do
        not Keyword.get(opts, :dream_time, false) ->
          nil

        Keyword.get(opts, :idle_dream_scheduling, false) ->
          Reasoning.run_scheduled(account_key, scope_path)

        true ->
          Reasoning.run(account_key)
      end

    refresh_semantic? = Keyword.get(opts, :refresh_semantic_index, false)
    refresh_source_semantic? = Keyword.get(opts, :refresh_source_semantic_index, false)
    refresh_projection? = Keyword.get(opts, :refresh_recall_projection, false)

    refresh =
      refresh_retrieval!(
        account_key,
        scope_path,
        refresh_semantic?,
        refresh_source_semantic?,
        refresh_projection?
      )

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
            %{
              "account_key" => account_key,
              "scope_path" => scope_path,
              "question" => question.question,
              "profile" => profile,
              "deadline" => deadline,
              "strategies" => Keyword.get(opts, :strategies),
              "effort" => Keyword.get(opts, :recall_effort, "fixed"),
              "include_source_recall" => Keyword.get(opts, :source_recall, false),
              "_include_lineage_recall" => Keyword.get(opts, :lineage_recall, false)
            }
            |> put_question_peer(question)
            |> Memory.ask()
          end)

        # Adaptive Ask answers are grounded in the planner's admitted evidence,
        # not only the base search page that remains under `candidates` for API
        # compatibility. Evaluate exactly that answer evidence so source
        # citations, retrieval rank, RAG context, and isolation checks measure
        # the behavior the answerer could actually consume.
        evaluation_answer = Map.put(answer, "candidates", answer_evidence(answer))

        cited_refs = cited_refs(evaluation_answer, ref_map, question.evidence_granularity)
        ranked_refs = ranked_refs(evaluation_answer, ref_map, question.evidence_granularity)
        isolation = isolation_counts(evaluation_answer, ref_map)
        retrieval_cutoffs = Keyword.get(opts, :retrieval_cutoffs, [10, 20, 50])

        deterministic_score =
          Scorer.score_question(question, evaluation_answer, cited_refs,
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
                Map.get(evaluation_answer, "candidates", [])
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
          "recall" => Map.get(answer, "recall", %{}),
          "isolation_candidates_checked" => isolation.candidates_checked,
          "isolation_leaks" => isolation.leaks,
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
        Enum.count(ingested, fn {_message, result} -> match?({:ok, _, _}, result) end),
      questions_attempted: length(questions),
      question_results: question_results,
      extractions:
        Enum.map(ingested, fn
          {_message, {:ok, _stored, knowledge}} -> knowledge
          {_message, _result} -> []
        end),
      reasoning: reasoning,
      refresh: refresh,
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
      extractions: [],
      reasoning: nil,
      refresh: empty_refresh(),
      status: status,
      reason: reason
    }
  end

  # Matched profile experiments need semantic retrieval to measure the corpus just ingested.
  # Ordinary benchmark runs retain their existing queue-shaped behavior; the explicit option
  # synchronously refreshes only the explicitly selected rebuildable caches for this isolated
  # case scope. Keeping the three switches separate makes projection maintenance measurable.
  defp refresh_retrieval!(_account_key, _scope_path, false, false, false),
    do: empty_refresh()

  defp refresh_retrieval!(account_key, scope_path, semantic?, source_semantic?, projection?) do
    {account_id, scope_id} =
      DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                   actor ->
        scope =
          Scope
          |> Ash.Query.filter(path == ^scope_path)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: actor)

        {account.id, scope.id}
      end)

    with {:ok, semantic} <- maybe_refresh_semantic(account_id, scope_id, semantic?),
         {:ok, source_semantic} <-
           maybe_refresh_source_semantic(account_id, scope_id, source_semantic?),
         {:ok, projection} <- maybe_refresh_projection(account_id, scope_id, projection?) do
      %{
        "semantic_index" => semantic,
        "source_semantic_index" => source_semantic,
        "recall_projection" => projection
      }
    else
      {:error, error} -> raise "evaluation retrieval refresh failed: #{inspect(error)}"
    end
  end

  defp maybe_refresh_semantic(account_id, scope_id, true) do
    case Indexer.refresh_scope(account_id, scope_id) do
      {:ok, %{indexed: count}} -> {:ok, completed_refresh(count)}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_refresh_semantic(_account_id, _scope_id, false), do: {:ok, skipped_refresh()}

  defp maybe_refresh_source_semantic(account_id, scope_id, true) do
    case SourceIndexer.refresh_scope(account_id, scope_id) do
      {:ok, %{indexed: count, embedding_identity: identity}} ->
        {:ok,
         completed_refresh(count)
         |> Map.put("embedding_identity", stringify_identity(identity))}

      {:error, error} ->
        {:error, error}
    end
  end

  defp maybe_refresh_source_semantic(_account_id, _scope_id, false),
    do: {:ok, skipped_refresh()}

  defp maybe_refresh_projection(account_id, scope_id, true) do
    {:ok, %{projected: projected}} = RecallProjector.refresh_scope(account_id, scope_id)
    {:ok, completed_refresh(projected)}
  end

  defp maybe_refresh_projection(_account_id, _scope_id, false), do: {:ok, skipped_refresh()}

  defp completed_refresh(count), do: %{"status" => "completed", "indexed" => count}
  defp skipped_refresh, do: %{"status" => "not_requested", "indexed" => 0}

  defp stringify_identity(identity) do
    Map.new(identity, fn {key, value} -> {to_string(key), value} end)
  end

  defp merge_refresh(cases) do
    names = ["semantic_index", "source_semantic_index", "recall_projection"]

    Map.new(names, fn name ->
      completed =
        cases
        |> Enum.map(&get_in(&1, [:refresh, name]))
        |> Enum.filter(&(&1["status"] == "completed"))

      result = %{
        "status" => if(completed == [], do: "not_requested", else: "completed"),
        "scopes" => length(completed),
        "indexed" => Enum.sum(Enum.map(completed, & &1["indexed"]))
      }

      identities =
        completed |> Enum.map(& &1["embedding_identity"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      result =
        case identities do
          [] -> result
          [identity] -> Map.put(result, "embedding_identity", identity)
          _many -> raise "evaluation refresh used multiple embedding identities"
        end

      {name, result}
    end)
  end

  defp empty_refresh do
    %{
      "semantic_index" => skipped_refresh(),
      "source_semantic_index" => skipped_refresh(),
      "recall_projection" => skipped_refresh()
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
      {source, {:ok, %{"id" => db_id}, _knowledge}}, acc ->
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

  defp answer_evidence(%{"recall" => %{"used" => true} = recall} = answer) do
    evidence = Map.get(answer, "recall_evidence", [])
    Enum.take(evidence, Map.get(recall, "answer_context_items", length(evidence)))
  end

  defp answer_evidence(answer), do: Map.get(answer, "candidates", [])

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

  # Retrieval rank is based on every candidate in the evaluated answer evidence, not only the
  # candidates the answer chose to cite. For adaptive recall that is the same bounded head the
  # answerer could consume, so planner evidence beyond the prompt limit cannot inflate recall.
  defp ranked_refs(answer, ref_map, granularity) do
    answer
    |> Map.get("candidates", [])
    |> Enum.map(fn candidate ->
      candidate
      |> candidate_source_message_ids()
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
    |> Enum.flat_map(&candidate_source_message_ids/1)
    |> Enum.uniq()
  end

  # Every evaluated knowledge or source-message candidate must trace only to sources ingested
  # for this case. The runner ingests messages, so an authorized document-version source is a
  # typed contamination signal rather than something that may be silently ignored.
  # Unexpected typed identities are counted but never copied into the report, because an id from
  # another scope or Account is itself data the evaluation harness is not authorized to disclose.
  defp isolation_counts(answer, ref_map) do
    allowed = ref_map.message_by_db_id |> Map.keys() |> MapSet.new(&{"message", &1})

    source_identities =
      answer
      |> Map.get("candidates", [])
      |> Enum.flat_map(&candidate_source_identities/1)
      |> Enum.uniq()

    %{
      candidates_checked: length(source_identities),
      leaks: Enum.count(source_identities, &(not MapSet.member?(allowed, &1)))
    }
  end

  defp candidate_source_message_ids(candidate) do
    candidate
    |> candidate_source_identities()
    |> Enum.flat_map(fn
      {"message", id} -> [id]
      {_other_type, _id} -> []
    end)
  end

  defp candidate_source_identities(candidate) do
    legacy =
      candidate
      |> Map.get("source_message_ids", [])
      |> Enum.flat_map(fn
        id when is_binary(id) -> [{"message", id}]
        _invalid -> []
      end)

    typed =
      candidate
      |> Map.get("source_references", [])
      |> Enum.flat_map(fn
        %{"type" => type, "id" => id}
        when type in ["message", "document_version"] and is_binary(id) ->
          [{type, id}]

        _hidden_or_invalid ->
          []
      end)

    Enum.uniq(legacy ++ typed)
  end

  # Evaluation runs use an internal Account adapter, so they have no calling
  # Peer unless the fixture names one. Keep that choice on the question: cases
  # may contain several participants, and guessing from message order would
  # change authorization and identity-profile behavior between datasets.
  defp put_question_peer(attrs, %{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "peer_key") || Map.get(metadata, :peer_key) do
      peer_key when is_binary(peer_key) and peer_key != "" ->
        Map.put(attrs, "peer_key", peer_key)

      _absent ->
        attrs
    end
  end

  defp put_question_peer(attrs, _question), do: attrs

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
      "refresh" => case[:refresh],
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
