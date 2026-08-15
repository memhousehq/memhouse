# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Diagnostics do
  @moduledoc """
  Keeps the latest content-free retrieval outcome for each Account.

  This is an ephemeral operator diagnostic. It stores component names, timings,
  reason classes, and profile settings only; queries and candidates never enter
  the table.
  """

  use GenServer

  @table __MODULE__

  @doc "Starts the node-local diagnostic table."
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Records a summary for callers that do not have a request limit."
  def record(account_id, result, deadline_ms), do: record(account_id, result, deadline_ms, 12)

  @doc "Records one content-free retrieval summary for an Account."
  def record(account_id, result, deadline_ms, max_candidates) do
    diskann = MemHouse.Retrieval.Store.diskann_query_settings(max_candidates)

    summary = %{
      profile: result.profile,
      profile_version: result.profile_version,
      query_search_list_size: diskann[:query_search_list_size],
      query_rescore: diskann[:query_rescore],
      lexical_analyzer: MemHouse.Retrieval.LexicalQueryAnalyzer.version(),
      deadline_ms: deadline_ms,
      latency_ms: result.latency_ms,
      pre_rerank_remaining_ms: result.pre_rerank_remaining_ms,
      outcomes: result.retrieval_outcomes,
      recorded_at: DateTime.utc_now()
    }

    GenServer.call(__MODULE__, {:record, account_id, summary})
  end

  @impl true
  def handle_call({:record, account_id, summary}, _from, state) do
    :ets.insert(@table, {account_id, summary})
    {:reply, :ok, state}
  end

  @doc "Returns the latest content-free summary for an Account, if this node observed one."
  def latest(account_id) do
    case :ets.lookup(@table, account_id) do
      [{^account_id, summary}] -> summary
      [] -> nil
    end
  end
end
