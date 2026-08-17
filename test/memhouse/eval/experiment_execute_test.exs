# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ExperimentExecuteTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.Eval.{Experiment, Report}

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
    assert current["safety"]["isolation_leaks"] == 0
    assert current["dream"]["replay_durable_effects"] == 0
    assert bundle["gates"]["status"] == "passed", inspect(bundle["gates"], pretty: true)
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
          "components" => %{"retrieval" => "current"}
        },
        %{
          "id" => "experimental",
          "kind" => "experimental",
          "benchmark" => "memhouse",
          "dataset" => dataset_path,
          "profile" => "balanced",
          "strategies" => ["lexical"],
          "components" => %{"retrieval" => "minimal-hybrid"}
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
end
