# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Embedding.QueryCache do
  @moduledoc """
  Bounded node-local cache of query vectors.

  Keys contain an Account id, the four-part embedder identity, and a SHA-256
  text digest. The raw query never enters ETS, telemetry, or an exported value.
  The cache is a rebuildable latency optimization; a restart only causes a new
  provider call.
  """

  use GenServer

  @table __MODULE__
  @limit 1_000

  @doc "Starts the cache process that owns the private ETS table."
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns a cached query vector or `:error` when the key is absent."
  def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})

  @doc "Stores one query vector and evicts the least recently used value when full."
  def put(key, vector), do: GenServer.call(__MODULE__, {:put, key, vector})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{clock: 0}}
  end

  @impl true
  def handle_call({:fetch, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, vector, _used_at}] ->
        {used_at, state} = tick(state)
        true = :ets.insert(@table, {key, vector, used_at})
        {:reply, {:ok, vector}, state}

      [] ->
        {:reply, :error, state}
    end
  end

  def handle_call({:put, key, vector}, _from, state) do
    {used_at, state} = tick(state)
    true = :ets.insert(@table, {key, vector, used_at})
    evict_oldest_if_needed()
    {:reply, :ok, state}
  end

  defp tick(%{clock: clock} = state), do: {clock + 1, %{state | clock: clock + 1}}

  defp evict_oldest_if_needed do
    if :ets.info(@table, :size) > @limit do
      {key, _vector, _used_at} = oldest_entry()
      true = :ets.delete(@table, key)
    end
  end

  defp oldest_entry, do: @table |> :ets.tab2list() |> Enum.min_by(&elem(&1, 2))
end
