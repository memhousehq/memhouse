# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Experiment do
  @moduledoc """
  Runs matched current-versus-experimental memory evaluations.

  An experiment definition names exactly one current and one experimental variant over the
  same input. The result is two artifacts: an environment-resolved run manifest and a comparison
  bundle whose measured evidence, inferences, and external first-party claims remain separate.

  Fixture mode replays content-free stage metrics and never starts the application, database, or
  a model provider. Execute mode delegates product behavior to `MemHouse.Eval.Runner` and only
  adds experiment provenance, stage accounting, and gates around its validated reports.
  """

  alias MemHouse.Clock
  alias MemHouse.Retrieval.Profile

  alias MemHouse.Eval.{
    Adapter,
    ComponentBindings,
    Maintenance,
    ExecutionEvidence,
    Measurement,
    QueryCounter,
    Report,
    Runner,
    VariantRuntime
  }

  @definition_schema "memhouse-experiment-definition-1"
  @manifest_schema "memhouse-experiment-manifest-1"
  @bundle_schema "memhouse-comparison-1"
  @variant_kinds ~w(current experimental)
  @stages ~w(ingest quality safety cost latency dream database maintenance)

  @doc """
  Runs the definition at `path` and returns `{run_manifest, comparison_bundle}`.

  Fixture definitions carry their deterministic environment and content-free stage metrics.
  Execute definitions use the existing evaluation runner and require the application to have
  been started by the calling Mix task. Invalid definitions, metrics, or backend claims raise.
  """
  def run(path, opts \\ []) when is_binary(path) do
    {definition, bytes} = load_definition!(path)
    definition = validate_definition!(definition)

    if definition["mode"] == "execute" and
         not Keyword.get(opts, :allow_provider_calls, false) do
      assert_offline_definition!(definition)
    end

    {environment, measured, reports} =
      case definition["mode"] do
        "fixture" -> fixture_run(definition)
        "execute" -> execute_run(definition, path, opts)
      end

    run_manifest = build_run_manifest(definition, bytes, environment)
    comparison = compare(measured)
    gates = evaluate_gates(definition["gates"], measured)

    bundle = %{
      "schema" => @bundle_schema,
      "generated_at" => run_manifest["generated_at"],
      "run_manifest" => run_manifest,
      "evidence" => %{
        "measured" => measured,
        "inferences" => Map.get(definition, "inferences", []),
        "first_party_claims" => Map.get(definition, "first_party_claims", [])
      },
      "comparison" => comparison,
      "gates" => gates,
      "reports" => reports
    }

    {run_manifest, bundle}
  end

  @doc "Returns the validated definition mode without starting MemHouse."
  def mode!(path) when is_binary(path) do
    {definition, _bytes} = load_definition!(path)
    validate_definition!(definition)["mode"]
  end

  @doc """
  Refuses an execute definition that would make a provider call in offline mode.

  Generation and reranking roles are replaced by deterministic local roles by the Mix task.
  Semantic retrieval is different: vector identity must remain attached to the real embedder,
  so an offline run requires an Ortex embedder with both operator-supplied artifacts already
  present. Hosted and deterministic stand-in embedders are rejected rather than called or used
  to manufacture semantic evidence.
  """
  def assert_offline_capabilities!(path) when is_binary(path) do
    {definition, _bytes} = load_definition!(path)
    definition = validate_definition!(definition)
    assert_offline_definition!(definition)
  end

  @doc "Raises when any comparison gate failed; otherwise returns the bundle unchanged."
  def assert_gates!(%{"gates" => %{"status" => "passed"}} = bundle), do: bundle

  def assert_gates!(%{"gates" => %{"failures" => failures}}) when is_list(failures) do
    names = Enum.map_join(failures, ", ", & &1["gate"])
    raise ArgumentError, "experiment gates failed: #{names}"
  end

  def assert_gates!(_bundle), do: raise(ArgumentError, "experiment bundle has no gate result")

  defp load_definition!(path) do
    bytes = read_local!(path)
    {Jason.decode!(bytes), bytes}
  end

  defp validate_definition!(
         %{
           "schema" => @definition_schema,
           "id" => id,
           "mode" => mode,
           "dataset" => dataset,
           "seeds" => seeds,
           "variants" => variants,
           "gates" => gates
         } = definition
       )
       when is_binary(id) and id != "" and mode in ["fixture", "execute"] and
              is_map(dataset) and is_list(variants) and is_map(gates) do
    validate_dataset!(dataset)
    validate_seeds!(seeds)
    validate_variants!(variants, mode)
    validate_inferences!(Map.get(definition, "inferences", []))
    validate_first_party_claims!(Map.get(definition, "first_party_claims", []))

    if mode == "fixture" do
      definition |> Map.fetch!("fixture_environment") |> validate_environment!()
      validate_fixture_metrics!(variants)
    end

    definition
  end

  defp validate_definition!(_definition) do
    raise ArgumentError,
          "experiment definition must be #{@definition_schema} with id, mode, dataset, seeds, two variants, and gates"
  end

  defp validate_dataset!(%{"id" => id, "sha256" => sha, "split" => split})
       when is_binary(id) and id != "" and is_binary(sha) and is_binary(split) and split != "" do
    if Regex.match?(~r/^[0-9a-f]{64}$/, sha),
      do: :ok,
      else: raise(ArgumentError, "dataset.sha256 must be a lowercase SHA-256")
  end

  defp validate_dataset!(_dataset) do
    raise ArgumentError, "dataset must identify id, lowercase SHA-256, and split"
  end

  defp validate_seeds!(seeds) when is_map(seeds) and map_size(seeds) > 0 do
    unless Enum.all?(seeds, fn {key, value} ->
             is_binary(key) and key != "" and (is_binary(value) or is_integer(value))
           end) do
      raise ArgumentError, "seeds must map non-empty names to exact string or integer values"
    end
  end

  defp validate_seeds!(_seeds), do: raise(ArgumentError, "seeds must be a non-empty object")

  defp validate_variants!(variants, mode) do
    kinds = Enum.map(variants, &Map.get(&1, "kind"))
    ids = Enum.map(variants, &Map.get(&1, "id"))

    unless Enum.sort(kinds) == Enum.sort(@variant_kinds) and length(Enum.uniq(ids)) == 2 do
      raise ArgumentError, "experiment requires one current and one experimental variant"
    end

    Enum.each(variants, fn variant ->
      unless is_binary(variant["id"]) and variant["id"] != "" and
               is_binary(variant["profile"]) and variant["profile"] != "" and
               valid_strategies?(Map.get(variant, "strategies")) and
               is_map(Map.get(variant, "components")) do
        raise ArgumentError,
              "each variant requires id, kind, profile, null or non-empty strategies, and components"
      end

      if mode == "execute" and
           (not is_binary(Map.get(variant, "dataset")) or
              not is_binary(Map.get(variant, "benchmark"))) do
        raise ArgumentError, "execute variants require dataset and benchmark"
      end

      validate_component_bindings!(variant, mode)
    end)
  end

  defp valid_strategies?(nil), do: true

  defp valid_strategies?(strategies) when is_list(strategies) and strategies != [],
    do: Enum.all?(strategies, &(is_binary(&1) and &1 != ""))

  defp valid_strategies?(_strategies), do: false

  defp validate_component_bindings!(variant, "fixture") do
    if variant["components"] != %{} do
      raise ArgumentError,
            "fixture variant #{inspect(variant["id"])} cannot declare executable components"
    end
  end

  defp validate_component_bindings!(variant, "execute") do
    ComponentBindings.validate!(variant)
  end

  defp executable_components(variant), do: ComponentBindings.resolve!(variant)

  defp validate_inferences!(claims) when is_list(claims) do
    unless Enum.all?(claims, &(is_map(&1) and non_empty_string?(Map.get(&1, "claim")))) do
      raise ArgumentError, "inferences must contain claim objects"
    end
  end

  defp validate_inferences!(_claims), do: raise(ArgumentError, "inferences must be a list")

  defp validate_first_party_claims!(claims) when is_list(claims) do
    unless Enum.all?(claims, fn claim ->
             is_map(claim) and non_empty_string?(Map.get(claim, "claim")) and
               non_empty_string?(Map.get(claim, "source")) and
               is_boolean(Map.get(claim, "reproduced"))
           end) do
      raise ArgumentError,
            "first_party_claims must identify claim, source, and reproduction status"
    end
  end

  defp validate_first_party_claims!(_claims) do
    raise ArgumentError, "first_party_claims must be a list"
  end

  defp validate_environment!(%{
         "source" => %{"repository" => repository, "revision" => revision},
         "backend" => backend,
         "models" => models
       })
       when is_binary(repository) and repository != "" and is_binary(revision) and
              revision != "" and is_map(models) do
    validate_backend!(backend)
    validate_models!(models)
  end

  defp validate_environment!(_environment) do
    raise ArgumentError, "fixture_environment must identify source, backend, and models"
  end

  defp validate_backend!(%{
         "engine" => "postgres",
         "mode" => mode,
         "sqlite" => "unsupported"
       })
       when mode in ["external", "pg0"],
       do: :ok

  defp validate_backend!(%{"engine" => engine}) when engine != "postgres" do
    raise ArgumentError,
          "backend engine must be postgres; SQLite is not a supported MemHouse path"
  end

  defp validate_backend!(_backend) do
    raise ArgumentError,
          "backend must record postgres external or pg0 mode and SQLite as unsupported"
  end

  defp validate_models!(models) do
    required = ~w(embedder reranker ingest_extractor dream_reasoner dialectic_agent)

    unless Enum.all?(required, fn role -> valid_model?(Map.get(models, role)) end) do
      raise ArgumentError,
            "models must identify provider, model, version, prompt, pipeline, and parameters for every role"
    end
  end

  defp valid_model?(%{
         "provider" => provider,
         "model" => model,
         "version" => version,
         "prompt_version" => prompt,
         "pipeline_version" => pipeline,
         "parameters" => parameters
       }) do
    Enum.all?([provider, model, version, prompt, pipeline], &(is_binary(&1) and &1 != "")) and
      is_map(parameters)
  end

  defp valid_model?(_model), do: false

  defp validate_fixture_metrics!(variants) do
    Enum.each(variants, fn variant ->
      metrics = Map.get(variant, "fixture_metrics")

      unless is_map(metrics) and Enum.all?(@stages, &is_map(Map.get(metrics, &1))) do
        raise ArgumentError, "fixture variants require all content-free metric stages"
      end

      numeric_paths = [
        ["ingest", "messages_attempted"],
        ["ingest", "messages_ingested"],
        ["ingest", "stored_facts"],
        ["ingest", "model_calls"],
        ["ingest", "input_tokens"],
        ["ingest", "output_tokens"],
        ["quality", "accuracy"],
        ["quality", "recall_at_10"],
        ["safety", "citation_hit_rate"],
        ["safety", "unsupported_claims"],
        ["safety", "isolation_candidates_checked"],
        ["safety", "isolation_leaks"],
        ["safety", "dropped_strategy_runs"],
        ["cost", "model_calls"],
        ["cost", "input_tokens"],
        ["cost", "output_tokens"],
        ["cost", "embedding_tokens"],
        ["cost", "total_tokens"],
        ["cost", "estimated_usd"],
        ["latency", "wall_time_ms"],
        ["latency", "recall_p95_ms"],
        ["dream", "attempted"],
        ["dream", "completed"],
        ["dream", "failed"],
        ["dream", "replay_durable_effects"],
        ["dream", "model_calls"],
        ["dream", "input_tokens"],
        ["dream", "output_tokens"],
        ["database", "queries"],
        ["database", "query_time_ms"],
        ["database", "decode_time_ms"],
        ["database", "queue_time_ms"],
        ["database", "idle_time_ms"],
        ["maintenance", "pipeline_runs_created"],
        ["maintenance", "extraction_runs"],
        ["maintenance", "dream_time_runs"],
        ["maintenance", "projection_refresh_runs"]
      ]

      unless Enum.all?(numeric_paths, &is_number(get_in(metrics, &1))) and
               (is_nil(get_in(metrics, ["safety", "abstention_accuracy"])) or
                  is_number(get_in(metrics, ["safety", "abstention_accuracy"]))) do
        raise ArgumentError, "fixture variants require complete numeric stage metrics"
      end

      isolation_count_paths = [
        ["safety", "isolation_candidates_checked"],
        ["safety", "isolation_leaks"]
      ]

      isolation_counts = Enum.map(isolation_count_paths, &get_in(metrics, &1))

      unless Enum.all?(isolation_counts, &(is_integer(&1) and &1 >= 0)) do
        raise ArgumentError, "fixture isolation counts must be non-negative integers"
      end
    end)
  end

  defp fixture_run(definition) do
    measured =
      definition["variants"]
      |> Map.new(fn variant -> {variant["kind"], variant["fixture_metrics"]} end)

    {definition["fixture_environment"], measured, nil}
  end

  defp execute_run(definition, definition_path, opts) do
    root = Path.dirname(definition_path)
    run_id = Keyword.get(opts, :run_id) || default_run_id()
    account_root = Keyword.get(opts, :account_key, "eval-experiment")

    results =
      Enum.map(definition["variants"], fn variant ->
        dataset_path = resolve(root, variant["dataset"])
        dataset = Adapter.load!(dataset_path, benchmark: variant["benchmark"])
        assert_dataset_identity!(definition["dataset"], dataset)

        account_key = "#{account_root}-#{run_id}-#{variant["kind"]}"
        before = Measurement.snapshot(account_key)
        started_at = System.monotonic_time(:millisecond)

        {report, database} =
          QueryCounter.measure(fn ->
            run_variant(dataset, definition, variant, account_key, run_id, before)
          end)

        wall_time_ms = System.monotonic_time(:millisecond) - started_at

        measured =
          Measurement.delta(before, Measurement.snapshot(account_key), wall_time_ms, database)

        {variant["kind"], report, stage_metrics(report, measured)}
      end)

    reports = Map.new(results, fn {kind, report, _metrics} -> {kind, report} end)
    measured = Map.new(results, fn {kind, _report, metrics} -> {kind, metrics} end)

    environment = %{
      "source" => source_identity(opts),
      "backend" => backend_identity(),
      "models" => model_identities(),
      "profiles" =>
        Map.new(definition["variants"], fn variant ->
          report = Map.fetch!(reports, variant["kind"])
          {variant["kind"], profile_identity(variant, report)}
        end)
    }

    validate_environment!(environment)
    {environment, measured, reports}
  end

  defp run_variant(dataset, definition, variant, account_key, run_id, before) do
    components = executable_components(variant)
    prior_run_ids = MapSet.new(before.pipeline_runs, & &1.id)

    VariantRuntime.with_components(components, fn ->
      report =
        Runner.run(dataset,
          profile: variant["profile"],
          strategies: variant["strategies"],
          deadline: components["retrieval_deadline"],
          components: components,
          judge: "deterministic",
          split: definition["dataset"]["split"],
          account_key: account_key,
          run_id: "#{run_id}-#{variant["id"]}",
          limit_cases: Map.get(variant, "limit_cases"),
          limit_messages: Map.get(variant, "limit_messages"),
          limit_questions: Map.get(variant, "limit_questions"),
          extraction_batching: components["extraction_batching"]["enabled"],
          recall_effort: components["adaptive_recall_effort"],
          source_recall: components["source_recall"],
          source_exact_recall: components["source_exact_recall"],
          source_semantic_recall: components["source_semantic_recall"],
          stable_profile_recall: components["stable_profile_recall"],
          lineage_recall: components["lineage_recall"],
          dream_time: components["dream_time"],
          idle_dream_scheduling: components["idle_dream_scheduling"]["enabled"],
          durability_audit: components["durability_audit"],
          durability_seed: Map.get(variant, "durability_seed", definition["seeds"]["durability"]),
          refresh_semantic_index: components["semantic_index_refresh"],
          refresh_source_semantic_index: components["source_semantic_index_refresh"],
          refresh_recall_projection: components["recall_projection_refresh"],
          after_ingest: fn _scope_path ->
            Maintenance.settle!(account_key, prior_run_ids)
          end,
          before_questions: fn _scope_path ->
            Maintenance.settle!(account_key, prior_run_ids)
          end
        )

      validated =
        report
        |> assert_executed_components!(variant, components)
        |> Report.validate!()

      Maintenance.settle!(account_key, prior_run_ids)
      validated
    end)
  end

  defp assert_executed_components!(report, variant, components) do
    if report["components"] != components do
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} runner component report did not match its binding"
    end

    failed_cases = Enum.filter(report["cases"], &(&1["status"] == "failed"))

    if failed_cases != [] do
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} could not execute its declared components: #{length(failed_cases)} runtime-failed case(s)"
    end

    declared = components["retrieval_strategies"]

    dropped =
      report["cases"]
      |> Enum.flat_map(& &1["questions"])
      |> Enum.flat_map(& &1["dropped_strategies"])
      |> Enum.filter(&(&1 in declared))
      |> Enum.uniq()

    if dropped != [] do
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} could not execute declared retrieval strategies #{inspect(dropped)}"
    end

    assert_recall_components!(report, variant, components)
    assert_refresh_components!(report, variant, components)
    assert_idle_scheduling!(report, variant, components)
    assert_reasoning_operations!(report, variant, components)

    report
  end

  defp assert_recall_components!(report, variant, components) do
    recalls =
      report["cases"]
      |> Enum.flat_map(& &1["questions"])
      |> Enum.map(& &1["recall"])

    valid? = Enum.all?(recalls, &recall_matches_components?(&1, variant, components))

    unless valid? do
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} recall behavior did not match its component binding"
    end

    if components["adaptive_recall_effort"] != "fixed" and
         not Enum.any?(recalls, &(Map.get(&1, "answer_context_adaptive_items", 0) > 0)) do
      raise ArgumentError,
            "execute variant #{inspect(variant["id"])} declared adaptive recall but admitted no new tool evidence to an answer context"
    end

    assert_completed_recall_tool!(recalls, variant, components, "lineage_recall", "lineage")

    assert_completed_recall_tool!(
      recalls,
      variant,
      components,
      "source_exact_recall",
      "source_exact"
    )

    assert_completed_recall_tool!(
      recalls,
      variant,
      components,
      "source_semantic_recall",
      "source_semantic"
    )

    assert_completed_recall_tool!(
      recalls,
      variant,
      components,
      "stable_profile_recall",
      "profile"
    )
  end

  defp assert_completed_recall_tool!(recalls, variant, components, component, tool) do
    ExecutionEvidence.assert_recall_tool!(
      recalls,
      variant,
      components,
      component,
      tool
    )
  end

  defp assert_refresh_components!(report, variant, components) do
    if components["source_semantic_index_refresh"] do
      refresh = get_in(report, ["refresh", "source_semantic_index"]) || %{}

      unless refresh["status"] == "completed" and refresh["scopes"] > 0 and
               is_map(refresh["embedding_identity"]) do
        raise ArgumentError,
              "execute variant #{inspect(variant["id"])} did not complete its source semantic index refresh"
      end
    end
  end

  defp assert_idle_scheduling!(report, variant, components) do
    if components["idle_dream_scheduling"]["enabled"] do
      scheduling = get_in(report, ["reasoning", "scheduling"]) || %{}

      valid? =
        scheduling["enabled"] == true and scheduling["generations"] >= 2 and
          scheduling["scheduled_at_ordered"] == true and scheduling["stale_model_calls"] == 0 and
          scheduling["stale_status"] == "superseded_activity" and
          scheduling["latest_status"] == "completed" and
          scheduling["replay_durable_effects"] == 0

      unless valid? do
        raise ArgumentError,
              "execute variant #{inspect(variant["id"])} did not complete durable stale/latest/replay idle scheduling"
      end
    end
  end

  defp recall_matches_components?(recall, _variant, %{"adaptive_recall_effort" => "fixed"}) do
    recall["used"] == false and recall["effort"] == "fixed"
  end

  defp recall_matches_components?(recall, variant, components) do
    recall["used"] == true and
      recall["effort"] == components["adaptive_recall_effort"] and
      recall["retrieval_profile"] == variant["profile"] and
      is_binary(recall["retrieval_profile_version"]) and
      recall["source_recall_permitted"] == components["source_recall"] and
      recall["source_exact_recall_permitted"] == components["source_exact_recall"] and
      recall["source_semantic_recall_permitted"] == components["source_semantic_recall"] and
      recall["stable_profile_recall_permitted"] == components["stable_profile_recall"] and
      recall["lineage_recall_permitted"] == components["lineage_recall"]
  end

  defp assert_reasoning_operations!(report, variant, components) do
    operations = components["dream_reasoning_operations"]

    if operations["split_enabled"] do
      actual = get_in(report, ["reasoning", "operations"]) || %{}

      missing =
        ["update", "synthesis"]
        |> Enum.filter(&operations[&1])
        |> Enum.map(&"reasoning_#{&1}")
        |> Enum.reject(fn operation ->
          get_in(actual, [operation, "completed"]) |> Kernel.||(0) > 0
        end)

      if missing != [] do
        raise ArgumentError,
              "execute variant #{inspect(variant["id"])} declared split dream operations but completed none for #{inspect(missing)}"
      end

      mismatched_versions =
        ["update", "synthesis"]
        |> Enum.filter(&operations[&1])
        |> Enum.reject(fn operation ->
          get_in(actual, ["reasoning_#{operation}", "prompt_version"]) ==
            operations["#{operation}_prompt_version"]
        end)

      if mismatched_versions != [] do
        raise ArgumentError,
              "execute variant #{inspect(variant["id"])} observed unexpected split reasoning prompt versions for #{inspect(mismatched_versions)}"
      end
    end
  end

  defp assert_offline_definition!(%{"mode" => "fixture"}), do: :ok

  defp assert_offline_definition!(%{"mode" => "execute", "variants" => variants}) do
    assert_offline_variants!(variants)
  end

  defp assert_offline_variants!([%{"components" => components} | rest]) do
    semantic_retrieval? =
      Enum.any?(components["retrieval_strategies"], &(&1 in ["semantic", "semantic_dual_lane"]))

    if semantic_retrieval? or components["source_semantic_recall"] == true or
         components["source_semantic_index_refresh"] == true,
       do: assert_local_embedder!()

    assert_offline_variants!(rest)
  end

  defp assert_offline_variants!([]), do: :ok

  defp assert_local_embedder! do
    embedder =
      :memhouse
      |> Application.fetch_env!(:model_roles)
      |> Keyword.fetch!(:embedder)
      |> Map.new()

    options = embedder |> Map.get(:options, %{}) |> Map.new()

    case Map.get(embedder, :provider) do
      "ortex" ->
        missing =
          for key <- ["model_path", "tokenizer_path"],
              not local_artifact?(Map.get(options, key)),
              do: key

        if missing == [] do
          :ok
        else
          raise ArgumentError,
                "offline semantic experiment requires existing local Ortex artifacts: missing #{Enum.join(missing, ", ")}"
        end

      provider ->
        raise ArgumentError,
              "offline semantic experiment requires the local Ortex embedder, got #{inspect(provider)}; use --live-model only with explicit provider authorization"
    end
  end

  defp local_artifact?(path),
    do: is_binary(path) and path != "" and File.regular?(path)

  defp build_run_manifest(definition, bytes, environment) do
    generated_at =
      Map.get(definition, "generated_at") ||
        Clock.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      "schema" => @manifest_schema,
      "id" => definition["id"],
      "mode" => definition["mode"],
      "generated_at" => generated_at,
      "definition" => %{
        "schema" => definition["schema"],
        "sha256" => sha256(bytes)
      },
      "dataset" => definition["dataset"],
      "seeds" => definition["seeds"],
      "source" => environment["source"],
      "backend" => environment["backend"],
      "models" => environment["models"],
      "variants" =>
        Map.new(definition["variants"], fn variant ->
          {variant["kind"],
           %{
             "id" => variant["id"],
             "components" => Map.get(variant, "components", %{}),
             "profile" =>
               get_in(environment, ["profiles", variant["kind"]]) ||
                 %{
                   "name" => variant["profile"],
                   "version" => Map.get(variant, "profile_version", "fixture"),
                   "strategies" => variant["strategies"]
                 }
           }}
        end)
    }
  end

  defp compare(%{"current" => current, "experimental" => experimental}) do
    %{
      "quality" => %{
        "accuracy_delta" => delta(experimental, current, ["quality", "accuracy"]),
        "recall_at_10_delta" => delta(experimental, current, ["quality", "recall_at_10"])
      },
      "safety" => %{
        "citation_hit_rate_delta" =>
          delta(experimental, current, ["safety", "citation_hit_rate"]),
        "abstention_accuracy_delta" =>
          delta(experimental, current, ["safety", "abstention_accuracy"]),
        "unsupported_claims_delta" =>
          delta(experimental, current, ["safety", "unsupported_claims"]),
        "isolation_leaks_delta" => delta(experimental, current, ["safety", "isolation_leaks"]),
        "dropped_strategy_runs_delta" =>
          delta(experimental, current, ["safety", "dropped_strategy_runs"])
      },
      "cost" => %{
        "total_tokens_delta" => delta(experimental, current, ["cost", "total_tokens"]),
        "total_tokens_ratio" => ratio(experimental, current, ["cost", "total_tokens"]),
        "estimated_usd_delta" => delta(experimental, current, ["cost", "estimated_usd"])
      },
      "latency" => %{
        "wall_time_ratio" => ratio(experimental, current, ["latency", "wall_time_ms"]),
        "recall_p95_ratio" => ratio(experimental, current, ["latency", "recall_p95_ms"])
      },
      "dream" => %{
        "replay_durable_effects_delta" =>
          delta(experimental, current, ["dream", "replay_durable_effects"])
      },
      "database" => %{
        "queries_delta" => delta(experimental, current, ["database", "queries"]),
        "queries_ratio" => ratio(experimental, current, ["database", "queries"]),
        "query_time_ms_delta" => delta(experimental, current, ["database", "query_time_ms"])
      },
      "maintenance" => %{
        "pipeline_runs_created_delta" =>
          delta(experimental, current, ["maintenance", "pipeline_runs_created"]),
        "extraction_runs_delta" =>
          delta(experimental, current, ["maintenance", "extraction_runs"]),
        "dream_time_runs_delta" =>
          delta(experimental, current, ["maintenance", "dream_time_runs"]),
        "projection_refresh_runs_delta" =>
          delta(experimental, current, ["maintenance", "projection_refresh_runs"])
      }
    }
  end

  defp evaluate_gates(gates, %{"current" => current, "experimental" => experimental}) do
    checks =
      []
      |> optional_min_delta(
        "quality.accuracy_regression",
        gates,
        ["quality", "max_accuracy_regression"],
        delta(experimental, current, ["quality", "accuracy"])
      )
      |> optional_min(
        "quality.recall_at_10",
        gates,
        ["quality", "min_recall_at_10"],
        get_in(experimental, ["quality", "recall_at_10"])
      )
      |> category_quality_checks(gates, current, experimental)
      |> optional_min(
        "safety.citation_hit_rate",
        gates,
        ["safety", "min_citation_hit_rate"],
        get_in(experimental, ["safety", "citation_hit_rate"])
      )
      |> optional_min(
        "safety.abstention_accuracy",
        gates,
        ["safety", "min_abstention_accuracy"],
        get_in(experimental, ["safety", "abstention_accuracy"])
      )
      |> optional_max(
        "safety.unsupported_claims",
        gates,
        ["safety", "max_unsupported_claims"],
        get_in(experimental, ["safety", "unsupported_claims"])
      )
      |> optional_max(
        "safety.isolation_leaks",
        gates,
        ["safety", "max_isolation_leaks"],
        get_in(experimental, ["safety", "isolation_leaks"])
      )
      |> require_isolation_coverage(
        gates,
        get_in(experimental, ["safety", "isolation_candidates_checked"])
      )
      |> optional_max(
        "safety.dropped_strategy_runs",
        gates,
        ["safety", "max_dropped_strategy_runs"],
        get_in(experimental, ["safety", "dropped_strategy_runs"])
      )
      |> optional_max(
        "cost.total_tokens_ratio",
        gates,
        ["cost", "max_total_tokens_ratio"],
        ratio(experimental, current, ["cost", "total_tokens"])
      )
      |> optional_max(
        "cost.estimated_usd",
        gates,
        ["cost", "max_estimated_usd"],
        get_in(experimental, ["cost", "estimated_usd"])
      )
      |> optional_max(
        "latency.recall_p95_ratio",
        gates,
        ["latency", "max_recall_p95_ratio"],
        ratio(experimental, current, ["latency", "recall_p95_ms"])
      )
      |> optional_max(
        "latency.wall_time_ratio",
        gates,
        ["latency", "max_wall_time_ratio"],
        ratio(experimental, current, ["latency", "wall_time_ms"])
      )
      |> optional_max(
        "dream.replay_durable_effects",
        gates,
        ["dream", "max_replay_durable_effects"],
        get_in(experimental, ["dream", "replay_durable_effects"])
      )
      |> Enum.reverse()

    failures = Enum.filter(checks, &(&1["status"] == "failed"))

    %{
      "status" => if(failures == [], do: "passed", else: "failed"),
      "checks" => checks,
      "failures" => failures
    }
  end

  defp optional_min_delta(checks, name, gates, path, actual) do
    case get_in(gates, path) do
      nil ->
        checks

      allowed when is_number(allowed) ->
        [check(name, actual, -allowed, :min) | checks]

      value ->
        raise ArgumentError, "gate #{Enum.join(path, ".")} must be numeric, got #{inspect(value)}"
    end
  end

  defp category_quality_checks(checks, gates, current, experimental) do
    checks
    |> category_floor_checks(gates, experimental)
    |> category_regression_checks(gates, current, experimental)
  end

  defp category_floor_checks(checks, gates, experimental) do
    case get_in(gates, ["quality", "min_category_accuracy"]) do
      nil ->
        checks

      configured when is_map(configured) ->
        assert_category_gate_map!("min_category_accuracy", configured)

        Enum.reduce(configured, checks, fn {category, expected}, acc ->
          assert_category_gate!("min_category_accuracy", category, expected)
          metrics = category_metrics!(experimental, category)
          coverage = category_coverage!(metrics, category)
          actual = if coverage > 0, do: Map.get(metrics, "accuracy"), else: nil

          [
            category_check(
              "quality.category.#{category}.accuracy",
              actual,
              expected,
              :min,
              coverage
            )
            | acc
          ]
        end)

      value ->
        raise ArgumentError,
              "gate quality.min_category_accuracy must be an object, got #{inspect(value)}"
    end
  end

  defp category_regression_checks(checks, gates, current, experimental) do
    case get_in(gates, ["quality", "max_category_accuracy_regression"]) do
      nil ->
        checks

      configured when is_map(configured) ->
        assert_category_gate_map!("max_category_accuracy_regression", configured)

        Enum.reduce(configured, checks, fn {category, allowed}, acc ->
          assert_category_gate!("max_category_accuracy_regression", category, allowed)
          current_metrics = category_metrics!(current, category)
          experimental_metrics = category_metrics!(experimental, category)

          coverage =
            min(
              category_coverage!(current_metrics, category),
              category_coverage!(experimental_metrics, category)
            )

          current_accuracy = Map.get(current_metrics, "accuracy")
          experimental_accuracy = Map.get(experimental_metrics, "accuracy")

          actual =
            if coverage > 0 and is_number(current_accuracy) and
                 is_number(experimental_accuracy),
               do: experimental_accuracy - current_accuracy,
               else: nil

          [
            category_check(
              "quality.category.#{category}.accuracy_regression",
              actual,
              -allowed,
              :min,
              coverage
            )
            | acc
          ]
        end)

      value ->
        raise ArgumentError,
              "gate quality.max_category_accuracy_regression must be an object, got #{inspect(value)}"
    end
  end

  defp assert_category_gate_map!(name, configured) when map_size(configured) == 0 do
    raise ArgumentError, "gate quality.#{name} must contain at least one category"
  end

  defp assert_category_gate_map!(_name, _configured), do: :ok

  defp category_metrics!(metrics, category) do
    case get_in(metrics, ["quality", "by_category"]) do
      nil ->
        %{}

      by_category when is_map(by_category) ->
        case Map.get(by_category, category) do
          nil -> %{}
          value -> value
        end

      value ->
        raise ArgumentError,
              "quality.by_category must be an object, got #{inspect(value)}"
    end
  end

  defp category_coverage!(metrics, category) when is_map(metrics) do
    case Map.get(metrics, "questions", 0) do
      coverage when is_integer(coverage) and coverage >= 0 ->
        coverage

      value ->
        raise ArgumentError,
              "quality.by_category #{inspect(category)} questions must be a non-negative integer, got #{inspect(value)}"
    end
  end

  defp category_coverage!(metrics, category) do
    raise ArgumentError,
          "quality.by_category #{inspect(category)} must be an object, got #{inspect(metrics)}"
  end

  defp assert_category_gate!(name, category, expected) do
    unless is_binary(category) and category != "" and is_number(expected) and expected >= 0 and
             expected <= 1 do
      raise ArgumentError,
            "gate quality.#{name} must map non-empty category names to fractions from 0 to 1"
    end
  end

  defp category_check(name, actual, expected, direction, coverage) do
    check(name, actual, expected, direction)
    |> Map.put("coverage", coverage)
  end

  defp optional_min(checks, name, gates, path, actual),
    do: optional_check(checks, name, gates, path, actual, :min)

  # A leak ceiling is promotion evidence only when retrieval exercised the source-membership
  # check. Keep this coupled to max_isolation_leaks so definitions cannot opt out of coverage
  # while still presenting a passing isolation gate.
  defp require_isolation_coverage(checks, gates, actual) do
    if is_nil(get_in(gates, ["safety", "max_isolation_leaks"])) do
      checks
    else
      [check("safety.isolation_candidates_checked", actual, 1, :min) | checks]
    end
  end

  defp optional_max(checks, name, gates, path, actual),
    do: optional_check(checks, name, gates, path, actual, :max)

  defp optional_check(checks, name, gates, path, actual, direction) do
    case get_in(gates, path) do
      nil ->
        checks

      expected when is_number(expected) ->
        [check(name, actual, expected, direction) | checks]

      value ->
        raise ArgumentError, "gate #{Enum.join(path, ".")} must be numeric, got #{inspect(value)}"
    end
  end

  defp check(name, actual, expected, direction) do
    passed =
      is_number(actual) and
        case direction do
          :min -> actual >= expected
          :max -> actual <= expected
        end

    %{
      "gate" => name,
      "status" => if(passed, do: "passed", else: "failed"),
      "actual" => actual,
      "operator" => if(direction == :min, do: ">=", else: "<="),
      "expected" => expected
    }
  end

  defp delta(experimental, current, path) do
    with experimental when is_number(experimental) <- get_in(experimental, path),
         current when is_number(current) <- get_in(current, path) do
      experimental - current
    else
      _value -> nil
    end
  end

  defp ratio(experimental, current, path) do
    case {get_in(experimental, path), get_in(current, path)} do
      {experimental, current}
      when is_number(experimental) and is_number(current) and experimental == 0 and current == 0 ->
        1.0

      {experimental, current}
      when is_number(experimental) and is_number(current) and current > 0 ->
        experimental / current

      _values ->
        nil
    end
  end

  defp stage_metrics(report, measurement) do
    overall = get_in(report, ["metrics", "overall"]) || %{}
    retrieval = get_in(report, ["metrics", "retrieval"]) || %{}
    isolation = get_in(report, ["metrics", "isolation"]) || %{}
    usage = measurement["usage"]
    ingest_usage = get_in(usage, ["by_role", "ingest_extractor"]) || empty_usage()
    reasoning = report["reasoning"] || empty_reasoning()
    by_category = get_in(report, ["metrics", "by_category"])
    by_category = if is_nil(by_category), do: %{}, else: by_category

    %{
      "ingest" => %{
        "messages_attempted" => report["messages_attempted"],
        "messages_ingested" => report["messages_ingested"],
        "stored_facts" => measurement["stored_facts"],
        "model_calls" => ingest_usage["calls"],
        "input_tokens" => ingest_usage["input_tokens"],
        "output_tokens" => ingest_usage["output_tokens"]
      },
      "quality" => %{
        "accuracy" => overall["accuracy"],
        "by_category" => by_category,
        "recall_at_10" => get_in(retrieval, ["recall_at_k", "10"]),
        "groundedness" => overall["mean_groundedness"],
        "context_relevance" => overall["mean_context_relevance"],
        "answer_relevance" => overall["mean_answer_relevance"]
      },
      "safety" => %{
        "citation_hit_rate" => overall["citation_hit_rate"],
        "abstention_accuracy" => overall["abstention_accuracy"],
        "unsupported_claims" => unsupported_claims(report),
        "isolation_candidates_checked" => Map.get(isolation, "candidates_checked", 0),
        "isolation_leaks" => Map.get(isolation, "leaks", 0),
        "dropped_strategy_runs" => dropped_strategy_runs(report)
      },
      "cost" => %{
        "model_calls" => usage["model_calls"],
        "input_tokens" => usage["input_tokens"],
        "output_tokens" => usage["output_tokens"],
        "embedding_tokens" => usage["embedding_tokens"],
        "total_tokens" => usage["total_tokens"],
        "estimated_usd" => usage["estimated_usd"],
        "cost_profile" => usage["cost_profile"]
      },
      "latency" => %{
        "wall_time_ms" => measurement["wall_time_ms"],
        "recall_p95_ms" => get_in(overall, ["latency_ms", "p95"])
      },
      "dream" => %{
        "attempted" => reasoning["attempted"],
        "completed" => reasoning["completed"],
        "failed" => reasoning["failed"],
        "replay_durable_effects" => reasoning["replay_durable_effects"],
        "model_calls" => get_in(reasoning, ["reasoner", "calls"]) || 0,
        "input_tokens" => get_in(reasoning, ["reasoner", "input_tokens"]) || 0,
        "output_tokens" => get_in(reasoning, ["reasoner", "output_tokens"]) || 0
      },
      "database" => measurement["database"],
      "maintenance" => measurement["maintenance"]
    }
  end

  defp unsupported_claims(report) do
    report
    |> Map.get("cases", [])
    |> Enum.flat_map(&Map.get(&1, "questions", []))
    |> Enum.count(fn question ->
      Map.get(question, "abstained") != true and Map.get(question, "citations", []) == []
    end)
  end

  defp dropped_strategy_runs(report) do
    report
    |> Map.get("cases", [])
    |> Enum.flat_map(&Map.get(&1, "questions", []))
    |> Enum.count(&(Map.get(&1, "dropped_strategies", []) != []))
  end

  defp empty_usage do
    %{
      "calls" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "embedding_tokens" => 0,
      "duration_ms" => 0,
      "errors" => 0
    }
  end

  defp empty_reasoning do
    %{
      "attempted" => 0,
      "completed" => 0,
      "failed" => 0,
      "replay_durable_effects" => 0,
      "reasoner" => empty_usage()
    }
  end

  defp assert_dataset_identity!(expected, dataset) do
    actual = %{
      "id" => dataset.dataset_id,
      "sha256" => dataset.dataset_sha256
    }

    unless actual["id"] == expected["id"] and actual["sha256"] == expected["sha256"] do
      raise ArgumentError, "execute dataset identity does not match the experiment definition"
    end
  end

  defp source_identity(opts) do
    revision =
      Keyword.get(opts, :source_revision) || System.get_env("MEMHOUSE_SOURCE_REVISION") ||
        git_revision()

    %{
      "repository" => "memhousehq/memhouse",
      "revision" => revision,
      "working_tree" => git_working_tree()
    }
  end

  defp git_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      _error -> "unavailable"
    end
  end

  defp git_working_tree do
    case System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> "clean"
      {_changes, 0} -> "dirty"
      _error -> "unavailable"
    end
  end

  defp backend_identity do
    %{
      "engine" => "postgres",
      "mode" => MemHouse.RuntimeConfig.database_mode(),
      "sqlite" => "unsupported"
    }
  end

  defp model_identities do
    :memhouse
    |> Application.fetch_env!(:model_roles)
    |> Map.new(fn {role, config} ->
      {Atom.to_string(role),
       %{
         "provider" => to_string(config.provider),
         "model" => to_string(config.model),
         "version" => to_string(config.model_version),
         "prompt_version" => to_string(config.prompt_version),
         "pipeline_version" => to_string(config.pipeline_version),
         "config_version" => Map.get(config, :config_version, 1),
         "embedding_dimensions" => Map.get(config, :embedding_dimensions),
         "parameters" => safe_model_parameters(Map.get(config, :options, %{}))
       }}
    end)
  end

  defp safe_model_parameters(options) do
    allowed =
      ~w(max_tokens max_retries receive_timeout total_timeout temperature top_p reasoning_effort max_length input_order pooling output_index positive_class_index batch_size)

    options
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(allowed)
  end

  defp profile_identity(variant, report) do
    config = Profile.configuration!(variant["profile"])
    strategies = variant["strategies"] || Enum.map(config.strategies, &Atom.to_string/1)

    enabled =
      :memhouse
      |> Application.fetch_env!(:retrieval_profiles)
      |> Keyword.fetch!(:enabled_strategies)
      |> Enum.map(&Atom.to_string/1)

    %{
      "name" => variant["profile"],
      "version" => report["profile_version"],
      "strategies" => strategies,
      "enabled_strategies" => enabled,
      "disabled_strategies" => strategies -- enabled,
      "weights" =>
        config.weights
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.take(strategies),
      "rrf_k" => config.rrf_k,
      "rerank" => config.rerank,
      "deadline_ms" => config.deadline_ms,
      "deadline" => Map.get(variant, "deadline", "disabled")
    }
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp default_run_id do
    Clock.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace(~r/[^0-9TZ]+/, "")
  end

  defp resolve(root, path) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Paths are operator-owned Mix task inputs, never HTTP request values.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_local!(path), do: File.read!(path)
end
