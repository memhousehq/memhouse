# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.MeasurementTest do
  use ExUnit.Case, async: true

  alias MemHouse.Eval.{Maintenance, Measurement}
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Retrieval.MaintenancePlan

  test "maintenance accounting reports scheduled and profile-skipped stages explicitly" do
    current = pipeline_run(MaintenancePlan.for_profile(:current))
    minimal = pipeline_run(MaintenancePlan.for_profile(:minimal))

    measurement =
      Measurement.delta(
        snapshot([]),
        snapshot([current, minimal]),
        1
      )

    stages = measurement["maintenance"]["projection_refresh_stages"]

    assert stages["sources"] == %{"scheduled" => 2, "skipped" => 0}
    assert stages["index"] == %{"scheduled" => 2, "skipped" => 0}
    assert stages["recall_documents"] == %{"scheduled" => 2, "skipped" => 0}
    assert stages["entities"] == %{"scheduled" => 1, "skipped" => 1}
    assert stages["context_projections"] == %{"scheduled" => 1, "skipped" => 1}
    assert measurement["maintenance"]["projection_refresh_stage_runs_completed"] == 2
  end

  test "pending refresh plans do not count as completed maintenance savings" do
    pending =
      :minimal
      |> MaintenancePlan.for_profile()
      |> pipeline_run("pending")

    measurement = Measurement.delta(snapshot([]), snapshot([pending]), 1)

    assert measurement["maintenance"]["projection_refresh_runs"] == 1
    assert measurement["maintenance"]["projection_refresh_stage_runs_completed"] == 0

    assert measurement["maintenance"]["projection_refresh_stages"]["entities"] ==
             %{"scheduled" => 0, "skipped" => 0}
  end

  test "legacy payloads keep full maintenance and unknown plan identities fail closed" do
    assert MaintenancePlan.from_payload(%{"mode" => "coalesced"}) ==
             MaintenancePlan.for_profile(:current)

    assert_raise ArgumentError, ~r/unknown durable retrieval maintenance plan/, fn ->
      MaintenancePlan.from_payload(%{"maintenance_profile" => "future-v9"})
    end
  end

  test "evaluation maintenance ignores baseline runs and rejects terminal non-completion" do
    baseline = %{id: "old", status: "pending"}
    completed = %{id: "completed", status: "completed"}

    assert Maintenance.new_runs([baseline, completed], MapSet.new(["old"])) == [completed]
    assert Maintenance.ensure_completed!([completed]) == :ok

    for status <- ["cancelled", "discarded"] do
      assert_raise ArgumentError, ~r/#{status}/, fn ->
        Maintenance.ensure_completed!([%{id: status, status: status}])
      end
    end
  end

  test "separate entity cache runs are reported only after completion" do
    completed = %PipelineRun{
      id: Ash.UUID.generate(),
      kind: "entity_resolution",
      status: "completed"
    }

    pending = %PipelineRun{id: Ash.UUID.generate(), kind: "entity_resolution", status: "pending"}

    measurement = Measurement.delta(snapshot([]), snapshot([completed, pending]), 1)

    assert measurement["maintenance"]["entity_resolution_runs"] == 2
    assert measurement["maintenance"]["entity_resolution_runs_completed"] == 1
    assert measurement["maintenance"]["cache_maintenance_runs_completed"] == 1
  end

  defp pipeline_run(plan, status \\ "completed") do
    %PipelineRun{
      id: Ash.UUID.generate(),
      kind: "projection_refresh",
      status: status,
      payload: MaintenancePlan.payload(plan)
    }
  end

  defp snapshot(runs) do
    %{knowledge_ids: MapSet.new(), pipeline_runs: runs, usages: []}
  end
end
