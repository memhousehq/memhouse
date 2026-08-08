# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Embedding.QueryCacheTest do
  use ExUnit.Case, async: false

  alias MemHouse.Model.Embedding.QueryCache

  test "keys are Account-scoped digests and values are reused" do
    query = "where is the runbook?"
    digest = :crypto.hash(:sha256, query)

    first_key =
      {"account-one", %{provider: "ortex", model: "bge", version: "1", dimensions: 384}, digest}

    second_key =
      {"account-two", %{provider: "ortex", model: "bge", version: "1", dimensions: 384}, digest}

    assert :error = QueryCache.fetch(first_key)
    assert :ok = QueryCache.put(first_key, [0.1, 0.2])
    assert {:ok, [0.1, 0.2]} = QueryCache.fetch(first_key)
    assert :error = QueryCache.fetch(second_key)

    refute Enum.any?(:ets.tab2list(QueryCache), &(inspect(&1) =~ query))
  end
end
