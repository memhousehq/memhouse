# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.Cache do
  @moduledoc """
  Node-local in-memory cache of clean context projections, with cluster-wide invalidation.

  Keys include Account, scope, and projection key to preserve tenancy. Values are one clean
  projection or the clean entity-card contents for a scope. Invalidation deletes locally and
  broadcasts to every node. The GenServer owns the public ETS table and receives broadcasts;
  losing the derived table is harmless.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Starts the cache process, which owns the ETS table and subscribes to invalidations.

  Options are ignored. The process is registered by module name.
  """
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Looks up one cached projection value at a captured decision time.

  Returns `{:ok, projection}` or `:error` for an Account/scope/projection key. An entry whose
  earliest source expiry is not later than `now` is deleted and treated as a miss.
  """
  def fetch(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, nil, value}] ->
        {:ok, value}

      [{^key, %DateTime{} = valid_until, value}] ->
        if DateTime.compare(valid_until, now) == :gt do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :error
        end

      # A hot upgrade can leave the former two-tuple shape in ETS. It carries no validity bound,
      # so discard it rather than serving content whose sources may already have expired.
      [{^key, _legacy_value}] ->
        :ets.delete(@table, key)
        :error

      [] ->
        :error
    end
  end

  @doc """
  Stores one clean projection value under the `{account id, scope id, projection cache key}`
  triple, together with the earliest expiry across its complete source set.

  Callers must reject dirty projections before calling. Returns `:ok`.
  """
  def put(key, value, valid_until) do
    true = :ets.insert(@table, {key, valid_until, value})
    :ok
  end

  @doc """
  Evicts every cached projection for one scope on every node.

  Deletes local entries, broadcasts to other nodes, and returns `:ok`.
  """
  def invalidate_scope(account_id, scope_id) do
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_, :_})
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_})

    Phoenix.PubSub.broadcast(
      MemHouse.PubSub,
      "context-invalidation",
      {:invalidate, account_id, scope_id}
    )

    :ok
  end

  @impl true
  def init(:ok) do
    # Public reads avoid a GenServer round trip; context assembly is read-heavy.
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok = Phoenix.PubSub.subscribe(MemHouse.PubSub, "context-invalidation")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:invalidate, account_id, scope_id}, state) do
    # The origin also receives this broadcast; repeated deletion is safe.
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_, :_})
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_})
    {:noreply, state}
  end
end
