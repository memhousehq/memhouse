# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.QueryCounterTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.Eval.QueryCounter

  test "counts only queries inside its bounded interval" do
    MemHouse.Repo.query!("SELECT 1")

    {result, measured} =
      QueryCounter.measure(fn ->
        MemHouse.Repo.query!("SELECT 1")
        :measured
      end)

    MemHouse.Repo.query!("SELECT 1")

    assert result == :measured
    assert measured["queries"] == 1
    assert measured["query_time_ms"] >= 0.0
    assert measured["decode_time_ms"] >= 0.0
    assert measured["queue_time_ms"] >= 0.0
    assert measured["idle_time_ms"] >= 0.0
    refute inspect(measured) =~ "SELECT"
  end
end
