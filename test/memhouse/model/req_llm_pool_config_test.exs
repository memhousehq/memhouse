# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.ReqLLMPoolConfigTest do
  @moduledoc """
  Pins the shared hosted-model connection-pool layout.

  ReqLLM uses one Finch pool for every provider and generation role. Capacity
  belongs in one HTTP/1 shard because multiple Finch shards are selected at
  random and can queue despite unused capacity elsewhere.
  """

  use ExUnit.Case, async: true

  test "ReqLLM has one explicit shard that covers the configurable ingest queue" do
    assert Application.fetch_env!(:req_llm, :stream_pool_size) == 16
    assert Application.fetch_env!(:req_llm, :stream_pool_count) == 1
    assert Application.fetch_env!(:req_llm, :stream_pool_timeout) == 120_000

    assert Application.fetch_env!(:memhouse, Oban)
           |> Keyword.fetch!(:queues)
           |> Keyword.fetch!(:ingest) ==
             10
  end
end
