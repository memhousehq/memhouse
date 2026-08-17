# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ExperimentTest do
  use ExUnit.Case, async: false

  alias MemHouse.Eval.Experiment

  @generated_at "2026-08-17T12:00:00Z"

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "memhouse-experiment-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "fixture mode produces a versioned manifest and a passing comparison bundle", %{
    tmp_dir: tmp_dir
  } do
    definition_path = write_definition!(tmp_dir, definition())

    {run_manifest, bundle} = Experiment.run(definition_path)

    assert run_manifest["schema"] == "memhouse-experiment-manifest-1"
    assert run_manifest["definition"]["sha256"] == sha256(definition_path)

    assert run_manifest["seeds"] == %{
             "case_sampling" => "all",
             "durability" => "fixture-durability-v1"
           }

    assert run_manifest["source"] == %{
             "repository" => "memhousehq/memhouse",
             "revision" => "fixture-revision"
           }

    assert run_manifest["backend"] == %{
             "engine" => "postgres",
             "mode" => "external",
             "sqlite" => "unsupported"
           }

    assert get_in(run_manifest, ["variants", "experimental", "profile", "strategies"]) == [
             "semantic",
             "lexical"
           ]

    assert get_in(run_manifest, ["models", "ingest_extractor", "prompt_version"]) ==
             "extract-fixture-1"

    assert get_in(run_manifest, ["models", "ingest_extractor", "parameters"]) == %{
             "max_tokens" => 512,
             "temperature" => 0.0
           }

    assert bundle["schema"] == "memhouse-comparison-1"
    assert bundle["run_manifest"] == run_manifest
    assert bundle["gates"]["status"] == "passed"
    assert bundle["gates"]["failures"] == []

    assert get_in(bundle, ["evidence", "measured", "experimental", "ingest", "stored_facts"]) ==
             2

    assert get_in(bundle, ["comparison", "quality", "accuracy_delta"]) == 0.0

    assert bundle["evidence"]["inferences"] == [
             %{"claim" => "A smaller retrieval set may reduce operating complexity."}
           ]

    assert bundle["evidence"]["first_party_claims"] == [
             %{
               "claim" => "Honcho reports 90.4 percent on LongMemEval S.",
               "source" => "plastic-labs/honcho-benchmarks@fixture",
               "reproduced" => false
             }
           ]
  end

  test "quality, citation, unsupported-claim, isolation, cost, latency, and dream failures gate",
       %{
         tmp_dir: tmp_dir
       } do
    definition =
      definition()
      |> put_in(["variants", Access.at(1), "fixture_metrics", "quality", "accuracy"], 0.5)
      |> put_in(
        ["variants", Access.at(1), "fixture_metrics", "safety", "citation_hit_rate"],
        0.5
      )
      |> put_in(
        ["variants", Access.at(1), "fixture_metrics", "safety", "unsupported_claims"],
        1
      )
      |> put_in(
        ["variants", Access.at(1), "fixture_metrics", "safety", "isolation_leaks"],
        1
      )
      |> put_in(["variants", Access.at(1), "fixture_metrics", "cost", "total_tokens"], 241)
      |> put_in(["variants", Access.at(1), "fixture_metrics", "latency", "recall_p95_ms"], 21)
      |> put_in(
        ["variants", Access.at(1), "fixture_metrics", "dream", "replay_durable_effects"],
        1
      )

    {_run_manifest, bundle} =
      tmp_dir
      |> write_definition!(definition)
      |> Experiment.run()

    assert bundle["gates"]["status"] == "failed"

    assert Enum.sort(Enum.map(bundle["gates"]["failures"], & &1["gate"])) ==
             Enum.sort([
               "quality.accuracy_regression",
               "safety.citation_hit_rate",
               "safety.unsupported_claims",
               "safety.isolation_leaks",
               "cost.total_tokens_ratio",
               "latency.recall_p95_ratio",
               "dream.replay_durable_effects"
             ])

    assert_raise ArgumentError, ~r/experiment gates failed/, fn ->
      Experiment.assert_gates!(bundle)
    end
  end

  test "retired SQLite definitions are rejected instead of being reported as parity", %{
    tmp_dir: tmp_dir
  } do
    definition = put_in(definition(), ["fixture_environment", "backend", "engine"], "sqlite")
    definition_path = write_definition!(tmp_dir, definition)

    assert_raise ArgumentError, ~r/backend engine must be postgres/, fn ->
      Experiment.run(definition_path)
    end
  end

  test "packaged pg0 is accepted as the second Postgres deployment mode", %{tmp_dir: tmp_dir} do
    definition = put_in(definition(), ["fixture_environment", "backend", "mode"], "pg0")
    definition_path = write_definition!(tmp_dir, definition)

    {manifest, _bundle} = Experiment.run(definition_path)

    assert manifest["backend"] == %{
             "engine" => "postgres",
             "mode" => "pg0",
             "sqlite" => "unsupported"
           }
  end

  test "fixture metrics cannot claim executable component ablations", %{tmp_dir: tmp_dir} do
    definition =
      put_in(definition(), ["variants", Access.at(0), "components"], %{
        "retrieval_profile" => "balanced"
      })

    definition_path = write_definition!(tmp_dir, definition)

    assert_raise ArgumentError, ~r/cannot declare executable components/, fn ->
      Experiment.run(definition_path)
    end
  end

  test "execute component labels must exactly match the runner behavior", %{tmp_dir: tmp_dir} do
    definition = Jason.decode!(File.read!("specs/eval/experiments/memory-profile-ablation.json"))

    lying_definition =
      put_in(
        definition,
        ["variants", Access.at(1), "components", "semantic_index_refresh"],
        false
      )

    lying_path = write_definition!(tmp_dir, lying_definition)

    assert_raise ArgumentError, ~r/component bindings must equal/, fn ->
      Experiment.mode!(lying_path)
    end

    unsupported_definition =
      put_in(
        definition,
        ["variants", Access.at(1), "components", "source_search"],
        "governed-hybrid"
      )

    unsupported_path = write_definition!(tmp_dir, unsupported_definition)

    assert_raise ArgumentError, ~r/unsupported component keys \["source_search"\]/, fn ->
      Experiment.mode!(unsupported_path)
    end
  end

  test "committed execute definition binds the real minimal dual-lane and lexical profile" do
    definition = Jason.decode!(File.read!("specs/eval/experiments/memory-profile-ablation.json"))
    experimental = Enum.find(definition["variants"], &(&1["kind"] == "experimental"))

    assert Experiment.mode!("specs/eval/experiments/memory-profile-ablation.json") == "execute"
    assert experimental["profile"] == "minimal"
    assert experimental["strategies"] == nil
    assert experimental["recall_effort"] == "high"

    assert experimental["components"] == %{
             "adaptive_recall_effort" => "high",
             "dream_time" => true,
             "dream_reasoning_operations" => %{
               "split_enabled" => true,
               "synthesis" => false,
               "update" => true
             },
             "durability_audit" => false,
             "extraction_batching" => %{
               "claim_timeout_seconds" => 1200,
               "context_limit_tokens" => 131_072,
               "enabled" => true,
               "identity" => "utf8-bytes-v1:target=4096:context=131072:output=8192:margin=2048",
               "max_anchors" => 32,
               "reserved_output_tokens" => 8192,
               "safety_margin_tokens" => 2048,
               "target_tokens" => 4096,
               "tokenizer" => "utf8-bytes-v1"
             },
             "idle_dream_scheduling" => %{
               "enabled" => true,
               "idle_seconds" => 0,
               "max_delta_items" => 20,
               "max_elapsed_ms" => 120_000,
               "max_working_set_items" => 50,
               "min_changes" => 1,
               "min_interval_seconds" => 0
             },
             "lineage_recall" => true,
             "recall_projection_refresh" => true,
             "retrieval_profile" => "minimal",
             "retrieval_seeds" => ["semantic_dual_lane", "lexical"],
             "retrieval_strategies" => ["semantic_dual_lane", "lexical"],
             "retrieval_rerank" => false,
             "retrieval_deadline" => "disabled",
             "semantic_index_refresh" => true,
             "source_recall" => true
           }
  end

  test "offline semantic execution refuses missing local artifacts without a stand-in" do
    roles = Application.fetch_env!(:memhouse, :model_roles)
    embedder = roles |> Keyword.fetch!(:embedder) |> Map.put(:provider, "ortex")
    embedder = Map.put(embedder, :options, %{"model_path" => nil, "tokenizer_path" => nil})
    Application.put_env(:memhouse, :model_roles, Keyword.put(roles, :embedder, embedder))
    on_exit(fn -> Application.put_env(:memhouse, :model_roles, roles) end)

    assert_raise ArgumentError,
                 ~r/offline semantic experiment requires existing local Ortex artifacts/,
                 fn ->
                   Experiment.assert_offline_capabilities!(
                     "specs/eval/experiments/memory-profile-ablation.json"
                   )
                 end

    deterministic_embedder = Map.put(embedder, :provider, "deterministic")

    Application.put_env(
      :memhouse,
      :model_roles,
      Keyword.put(roles, :embedder, deterministic_embedder)
    )

    assert_raise ArgumentError, ~r/requires the local Ortex embedder, got "deterministic"/, fn ->
      Experiment.assert_offline_capabilities!(
        "specs/eval/experiments/memory-profile-ablation.json"
      )
    end
  end

  test "the Mix command writes both artifacts and asserts gates by default", %{tmp_dir: tmp_dir} do
    definition_path = write_definition!(tmp_dir, definition())
    manifest_path = Path.join(tmp_dir, "run-manifest.json")
    bundle_path = Path.join(tmp_dir, "comparison.json")

    Mix.Task.reenable("memhouse.eval.experiment")

    Mix.Tasks.Memhouse.Eval.Experiment.run([
      "--definition",
      definition_path,
      "--manifest-output",
      manifest_path,
      "--output",
      bundle_path
    ])

    assert Jason.decode!(File.read!(manifest_path))["schema"] ==
             "memhouse-experiment-manifest-1"

    assert Jason.decode!(File.read!(bundle_path))["gates"]["status"] == "passed"
  end

  test "committed fixture evidence is exactly reproducible without providers" do
    {manifest, bundle} =
      Experiment.run("test/fixtures/eval/profile-experiment-fixture.json")

    assert manifest ==
             Jason.decode!(
               File.read!("specs/eval/results/profile-experiment-fixture-manifest.json")
             )

    assert bundle ==
             Jason.decode!(
               File.read!("specs/eval/results/profile-experiment-fixture-bundle.json")
             )
  end

  defp write_definition!(tmp_dir, definition) do
    path = Path.join(tmp_dir, "experiment.json")
    File.write!(path, Jason.encode!(definition))
    path
  end

  defp definition do
    %{
      "schema" => "memhouse-experiment-definition-1",
      "id" => "fixture-profile-comparison",
      "mode" => "fixture",
      "generated_at" => @generated_at,
      "dataset" => %{
        "id" => "memhouse-smoke.json",
        "sha256" => String.duplicate("a", 64),
        "split" => "fixture"
      },
      "seeds" => %{
        "case_sampling" => "all",
        "durability" => "fixture-durability-v1"
      },
      "fixture_environment" => %{
        "source" => %{
          "repository" => "memhousehq/memhouse",
          "revision" => "fixture-revision"
        },
        "backend" => %{
          "engine" => "postgres",
          "mode" => "external",
          "sqlite" => "unsupported"
        },
        "models" => fixture_models()
      },
      "variants" => [
        %{
          "id" => "current",
          "kind" => "current",
          "profile" => "balanced",
          "strategies" => nil,
          "components" => %{},
          "fixture_metrics" => metrics()
        },
        %{
          "id" => "experimental",
          "kind" => "experimental",
          "profile" => "balanced",
          "strategies" => ["semantic", "lexical"],
          "components" => %{},
          "fixture_metrics" => metrics()
        }
      ],
      "gates" => %{
        "quality" => %{
          "max_accuracy_regression" => 0.05,
          "min_recall_at_10" => 1.0
        },
        "safety" => %{
          "min_citation_hit_rate" => 1.0,
          "min_abstention_accuracy" => 1.0,
          "max_unsupported_claims" => 0,
          "max_isolation_leaks" => 0
        },
        "cost" => %{"max_total_tokens_ratio" => 1.2},
        "latency" => %{"max_recall_p95_ratio" => 2.0},
        "dream" => %{"max_replay_durable_effects" => 0}
      },
      "inferences" => [
        %{"claim" => "A smaller retrieval set may reduce operating complexity."}
      ],
      "first_party_claims" => [
        %{
          "claim" => "Honcho reports 90.4 percent on LongMemEval S.",
          "source" => "plastic-labs/honcho-benchmarks@fixture",
          "reproduced" => false
        }
      ]
    }
  end

  defp fixture_models do
    ~w(embedder reranker ingest_extractor dream_reasoner dialectic_agent)
    |> Map.new(fn role ->
      {role,
       %{
         "provider" => "deterministic",
         "model" => "fixture-#{role}",
         "version" => "1",
         "prompt_version" =>
           if(role == "ingest_extractor", do: "extract-fixture-1", else: "none"),
         "pipeline_version" => "fixture-1",
         "parameters" =>
           if(role == "ingest_extractor",
             do: %{"max_tokens" => 512, "temperature" => 0.0},
             else: %{}
           )
       }}
    end)
  end

  defp metrics do
    %{
      "ingest" => %{
        "messages_attempted" => 2,
        "messages_ingested" => 2,
        "stored_facts" => 2,
        "model_calls" => 2,
        "input_tokens" => 100,
        "output_tokens" => 20
      },
      "quality" => %{"accuracy" => 1.0, "recall_at_10" => 1.0},
      "safety" => %{
        "citation_hit_rate" => 1.0,
        "abstention_accuracy" => 1.0,
        "unsupported_claims" => 0,
        "isolation_leaks" => 0,
        "dropped_strategy_runs" => 0
      },
      "cost" => %{
        "model_calls" => 2,
        "input_tokens" => 100,
        "output_tokens" => 20,
        "embedding_tokens" => 0,
        "total_tokens" => 120,
        "estimated_usd" => 0.0
      },
      "latency" => %{"wall_time_ms" => 10, "recall_p95_ms" => 10},
      "dream" => %{
        "attempted" => 0,
        "completed" => 0,
        "failed" => 0,
        "replay_durable_effects" => 0,
        "model_calls" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0
      },
      "database" => %{
        "queries" => 12,
        "query_time_ms" => 4.0,
        "decode_time_ms" => 0.5,
        "queue_time_ms" => 0.25,
        "idle_time_ms" => 0.0
      },
      "maintenance" => %{
        "pipeline_runs_created" => 4,
        "extraction_runs" => 2,
        "dream_time_runs" => 0,
        "projection_refresh_runs" => 2,
        "pipeline_runs_by_kind" => %{"extraction" => 2, "projection_refresh" => 2},
        "pipeline_runs_by_status" => %{"completed" => 2, "pending" => 2}
      }
    }
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
