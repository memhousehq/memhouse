# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.Cache do
  @moduledoc """
  Node-local in-memory cache of clean context projections, with cluster-wide invalidation.

  Keys include Account, scope, and projection key to preserve tenancy. Values are one clean
  projection or the clean entity-card contents for a scope, together with the scope input
  generation that produced it. Invalidation deletes locally and broadcasts to every node. The
  GenServer owns the public ETS table and receives broadcasts; losing the derived table is
  harmless.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Starts the cache process, which owns the ETS table and subscribes to invalidations.

  Options are ignored. The process is registered by module name.
  """
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Looks up one cached projection value at a captured decision time and scope generation.

  Returns `{:ok, projection}` or `:error` for an Account/scope/projection key. An entry whose
  generation differs from `input_generation`, or whose earliest source expiry is not later than
  `now`, is deleted and treated as a miss.
  """
  def fetch(key, now, input_generation) do
    case :ets.lookup(@table, key) do
      [{^key, ^input_generation, nil, value}] ->
        {:ok, value}

      [{^key, ^input_generation, %DateTime{} = valid_until, value}] ->
        if MemHouse.Memory.Visibility.boundary_visible?(valid_until, now) do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :error
        end

      # A mutation may have advanced the generation, and a hot upgrade can leave either former
      # tuple shape in ETS. Discard all of them rather than serving content whose inputs may have
      # changed or expired.
      [{^key, _generation, _valid_until, _value}] ->
        :ets.delete(@table, key)
        :error

      [{^key, _legacy_valid_until, _legacy_value}] ->
        :ets.delete(@table, key)
        :error

      [{^key, _legacy_value}] ->
        :ets.delete(@table, key)
        :error

      [] ->
        :error
    end
  end

  @doc """
  Stores one clean projection value under the `{account id, scope id, projection cache key}`
  triple, together with the scope input generation and earliest expiry across its complete source
  set.

  Callers must reject dirty projections before calling. Returns `:ok`.
  """
  def put(key, value, valid_until, input_generation) do
    true = :ets.insert(@table, {key, input_generation, valid_until, value})
    :ok
  end

  @doc """
  Evicts every cached projection for one scope on every node.

  Deletes local entries, broadcasts to other nodes, and returns `:ok`.
  """
  def invalidate_scope(account_id, scope_id) do
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_, :_, :_})
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
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_, :_, :_})
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_, :_})
    :ets.match_delete(@table, {{account_id, scope_id, :_}, :_})
    {:noreply, state}
  end
end
