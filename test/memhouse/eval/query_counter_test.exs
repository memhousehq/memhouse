# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.QueryCounterTest do
  @moduledoc "Covers bounded, content-free database query measurement."

  use MemHouse.DataCase, async: false

  alias MemHouse.Eval.QueryCounter

  test "counts only queries inside its bounded interval" do
    {result, measured} =
      QueryCounter.measure(fn ->
        Task.async(fn ->
          :telemetry.execute([:mem_house, :repo, :query], %{query_time: 1}, %{})
        end)
        |> Task.await()

        :telemetry.execute(
          [:mem_house, :repo, :query],
          %{query_time: 1, decode_time: 1, queue_time: 1, idle_time: 1},
          %{}
        )

        :measured
      end)

    assert result == :measured
    assert measured["queries"] == 1
    assert measured["query_time_ms"] >= 0.0
    assert measured["decode_time_ms"] >= 0.0
    assert measured["queue_time_ms"] >= 0.0
    assert measured["idle_time_ms"] >= 0.0
    refute inspect(measured) =~ "SELECT"
  end
end
