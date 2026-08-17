# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ExperimentExecuteTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Eval.{Experiment, Report}
  alias MemHouse.Governance.Engine
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory

  require Ash.Query

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "memhouse-experiment-execute-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "execute mode reuses the runner and records Postgres stage measurements", %{
    tmp_dir: tmp_dir
  } do
    dataset_path = Path.expand("test/fixtures/eval/memhouse-smoke.json")
    definition_path = Path.join(tmp_dir, "execute-experiment.json")

    File.write!(definition_path, Jason.encode!(definition(dataset_path)))

    {manifest, bundle} =
      Experiment.run(definition_path,
        account_key: "eval-experiment-test",
        run_id: "execute-fixture",
        source_revision: "test-source-revision"
      )

    assert manifest["mode"] == "execute"

    assert manifest["backend"] == %{
             "engine" => "postgres",
             "mode" => MemHouse.RuntimeConfig.database_mode(),
             "sqlite" => "unsupported"
           }

    assert manifest["source"]["revision"] == "test-source-revision"
    assert get_in(manifest, ["variants", "current", "profile", "version"]) == "f7-1"
    assert get_in(manifest, ["variants", "current", "profile", "rrf_k"]) == 15

    refute Map.has_key?(
             get_in(manifest, ["models", "dialectic_agent", "parameters"]),
             "api_key_ref"
           )

    Enum.each(bundle["reports"], fn {_kind, report} -> assert Report.validate(report) == :ok end)

    current = get_in(bundle, ["evidence", "measured", "current"])

    assert current["ingest"]["messages_attempted"] == 2
    assert current["ingest"]["messages_ingested"] == 2
    assert current["ingest"]["stored_facts"] >= 1
    assert current["cost"]["model_calls"] >= 1
    assert current["cost"]["total_tokens"] >= 0
    assert is_number(current["latency"]["wall_time_ms"])
    assert current["database"]["queries"] > 0
    assert is_number(current["database"]["query_time_ms"])
    assert current["maintenance"]["pipeline_runs_created"] >= 3
    assert current["maintenance"]["extraction_runs"] == 2
    assert current["safety"]["isolation_leaks"] == 0
    assert current["dream"]["replay_durable_effects"] == 0
    assert bundle["gates"]["status"] == "passed", inspect(bundle["gates"], pretty: true)
  end

  test "execute mode drives batching and adaptive recall through their real runtime seams", %{
    tmp_dir: tmp_dir
  } do
    dataset_path = Path.expand("test/fixtures/eval/memhouse-smoke.json")
    definition_path = Path.join(tmp_dir, "execute-ablation.json")
    original_batching = Application.fetch_env!(:memhouse, :extraction_batching)
    original_dream_gates = Application.fetch_env!(:memhouse, :dream_time_gates)
    original_dream_operations = Application.fetch_env!(:memhouse, :dream_reasoning_operations)

    experimental_components =
      executable_components("balanced", ["lexical"])
      |> Map.merge(%{
        "adaptive_recall_effort" => "high",
        "dream_time" => true,
        "dream_reasoning_operations" => dream_operations_component(true),
        "extraction_batching" => batching_component(true),
        "idle_dream_scheduling" => idle_component(true),
        "lineage_recall" => true,
        "source_recall" => true
      })

    execute_definition =
      definition(dataset_path)
      |> put_in(["variants", Access.at(1), "extraction_batching"], true)
      |> put_in(["variants", Access.at(1), "recall_effort"], "high")
      |> put_in(["variants", Access.at(1), "source_recall"], true)
      |> put_in(["variants", Access.at(1), "lineage_recall"], true)
      |> put_in(["variants", Access.at(1), "idle_dream_scheduling"], true)
      |> put_in(["variants", Access.at(1), "dream_time"], true)
      |> put_in(["variants", Access.at(1), "dream_reasoning_split"], true)
      |> put_in(["variants", Access.at(1), "components"], experimental_components)

    File.write!(definition_path, Jason.encode!(execute_definition))

    seed_active_dream_inputs!(
      "eval-ablation-test-execute-ablation-experimental",
      "/bench/memhouse/execute-ablation-experimental/smoke"
    )

    {_manifest, bundle} =
      Experiment.run(definition_path,
        account_key: "eval-ablation-test",
        run_id: "execute-ablation",
        source_revision: "test-source-revision",
        # Test roles are deterministic. This bypasses the operator-only offline
        # Ortex preflight without authorizing or making a hosted provider call.
        allow_provider_calls: true
      )

    experimental_report = bundle["reports"]["experimental"]

    assert experimental_report["components"] == experimental_components

    assert Enum.all?(hd(experimental_report["cases"])["questions"], fn question ->
             question["recall"]["used"] == true and
               question["recall"]["effort"] == "high" and
               question["recall"]["source_recall_permitted"] == true and
               question["recall"]["lineage_recall_permitted"] == true
           end)

    assert Enum.any?(hd(experimental_report["cases"])["questions"], fn question ->
             Enum.any?(question["recall"]["outcomes"], fn outcome ->
               outcome["tool"] == "lineage" and outcome["status"] == "completed"
             end)
           end)

    current = get_in(bundle, ["evidence", "measured", "current"])
    experimental = get_in(bundle, ["evidence", "measured", "experimental"])

    assert experimental["ingest"]["model_calls"] <= current["ingest"]["model_calls"]
    assert experimental["maintenance"]["extraction_runs"] == 2

    # The deterministic fixture produces governed provisional items, so the active-direct-only
    # idle scheduler correctly creates no wakeup. The binding is nevertheless the exact runtime
    # switch used during ingest and is restored below.
    assert experimental_report["components"]["idle_dream_scheduling"]["enabled"] == true
    assert experimental["maintenance"]["dream_time_runs"] == 0
    assert experimental_report["reasoning"]["enabled"] == true

    assert get_in(experimental_report, [
             "reasoning",
             "operations",
             "reasoning_update",
             "completed"
           ]) >
             0

    assert Application.fetch_env!(:memhouse, :extraction_batching) == original_batching
    assert Application.fetch_env!(:memhouse, :dream_time_gates) == original_dream_gates

    assert Application.fetch_env!(:memhouse, :dream_reasoning_operations) ==
             original_dream_operations
  end

  defp definition(dataset_path) do
    %{
      "schema" => "memhouse-experiment-definition-1",
      "id" => "execute-profile-comparison",
      "mode" => "execute",
      "dataset" => %{
        "id" => Path.basename(dataset_path),
        "sha256" => sha256(dataset_path),
        "split" => "fixture"
      },
      "seeds" => %{
        "case_sampling" => "all",
        "durability" => "execute-test-v1"
      },
      "variants" => [
        %{
          "id" => "current",
          "kind" => "current",
          "benchmark" => "memhouse",
          "dataset" => dataset_path,
          "profile" => "balanced",
          "strategies" => ["lexical"],
          "components" => executable_components("balanced", ["lexical"])
        },
        %{
          "id" => "experimental",
          "kind" => "experimental",
          "benchmark" => "memhouse",
          "dataset" => dataset_path,
          "profile" => "balanced",
          "strategies" => ["lexical"],
          "components" => executable_components("balanced", ["lexical"])
        }
      ],
      "gates" => %{
        "quality" => %{"max_accuracy_regression" => 1.0, "min_recall_at_10" => 0.0},
        "safety" => %{
          "min_citation_hit_rate" => 0.0,
          "max_unsupported_claims" => 0,
          "max_isolation_leaks" => 0,
          "max_dropped_strategy_runs" => 0
        },
        "cost" => %{"max_total_tokens_ratio" => 10.0},
        "latency" => %{"max_recall_p95_ratio" => 100.0},
        "dream" => %{"max_replay_durable_effects" => 0}
      },
      "inferences" => [],
      "first_party_claims" => []
    }
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp executable_components(profile, strategies) do
    %{
      "adaptive_recall_effort" => "fixed",
      "dream_time" => false,
      "dream_reasoning_operations" => dream_operations_component(false),
      "durability_audit" => false,
      "extraction_batching" => batching_component(false),
      "idle_dream_scheduling" => idle_component(false),
      "lineage_recall" => false,
      "recall_projection_refresh" => false,
      "retrieval_profile" => profile,
      "retrieval_seeds" => strategies,
      "retrieval_strategies" => strategies,
      "retrieval_rerank" => false,
      "retrieval_deadline" => "disabled",
      "semantic_index_refresh" =>
        Enum.any?(strategies, &(&1 in ["semantic", "semantic_dual_lane"])),
      "source_recall" => false
    }
  end

  defp batching_component(enabled) do
    %{
      "claim_timeout_seconds" => 1200,
      "context_limit_tokens" => 131_072,
      "enabled" => enabled,
      "identity" => "utf8-bytes-v1:target=4096:context=131072:output=8192:margin=2048",
      "max_anchors" => 32,
      "reserved_output_tokens" => 8192,
      "safety_margin_tokens" => 2048,
      "target_tokens" => 4096,
      "tokenizer" => "utf8-bytes-v1"
    }
  end

  defp idle_component(enabled) do
    %{
      "enabled" => enabled,
      "idle_seconds" => 0,
      "max_delta_items" => 20,
      "max_elapsed_ms" => 120_000,
      "max_working_set_items" => 50,
      "min_changes" => 1,
      "min_interval_seconds" => 0
    }
  end

  defp dream_operations_component(split_enabled) do
    %{
      "split_enabled" => split_enabled,
      "synthesis" => false,
      "update" => true
    }
  end

  defp seed_active_dream_inputs!(account_key, scope_path) do
    Enum.each(
      ["Alice prefers concise updates.", "Alice moved the review to Friday."],
      fn content ->
        assert {:ok, message} =
                 Memory.ingest_message(%{
                   "account_key" => account_key,
                   "session_id" => "seed-#{System.unique_integer([:positive])}",
                   "scope_path" => scope_path,
                   "peer_key" => "alice",
                   "content" => content
                 })

        assert {:ok, knowledge} = Memory.extract_message(message["id"], account_key)

        DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                     actor ->
          Enum.each(knowledge, fn item ->
            KnowledgeItem
            |> Ash.Query.filter(id == ^item["id"])
            |> Ash.Query.set_tenant(account.id)
            |> Ash.read_one!(actor: actor)
            |> Engine.transition!(
              actor,
              %{state: "active", verification: "eval_test_seed"},
              reason: "eval_test_seed",
              channel: "pipeline"
            )
          end)
        end)
      end
    )
  end
end
