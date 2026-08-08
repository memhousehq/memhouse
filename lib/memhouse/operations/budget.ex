# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.BudgetCounter do
  @moduledoc """
  Rebuildable in-memory daily counters for admission checks.

  Counters trade exactness for cheap reads and can be reconstructed from UsageEvent. They never
  replace the durable ledger or carry content.
  """

  use GenServer

  @table __MODULE__

  @doc """
  Starts the process that owns the counter table, registered under the module
  name.

  Started as part of the application's supervision tree; nothing else should
  start it. Options are accepted and ignored.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds `amount` to the Account/scope/metric tally for today, creating it at zero
  first if it does not exist.

  `scope_id` may be nil for Account-wide metrics; nil is part of the key, so
  scoped and unscoped tallies of the same metric are separate buckets and never
  merge. `metric` is an atom such as `:api_requests`, `:ingest`, or a token
  kind. `amount` must be a non-negative integer — counters only ever move
  forward, and the guard rejects a decrement rather than letting one corrupt
  the day's total.

  Always returns `:ok`, including when the table is missing.
  """
  def increment(account_id, scope_id, metric, amount)
      when is_binary(account_id) and is_atom(metric) and is_integer(amount) and amount >= 0 do
    period = Date.utc_today() |> Date.to_iso8601()
    key = {account_id, scope_id, metric, period}
    # Atomic read-modify-write inside the table, so concurrent requests for the
    # same Account cannot lose an increment to a read/write race. The trailing
    # tuple is the default row inserted when the key is absent.
    :ets.update_counter(@table, key, {2, amount}, {key, 0})
    :ok
  rescue
    # Raised when the table does not exist. Dropping a cache increment is
    # correct here; the durable ledger row was already written by the caller.
    ArgumentError -> :ok
  end

  @doc """
  Reads today's tally for one Account, scope, and metric.

  Returns the integer total, or `0` when nothing has been counted today. Zero is
  also what a caller gets after a restart, which deliberately re-opens the day's
  allowance rather than blocking traffic on an unknown total.

  Raises `ArgumentError` if the owning process has never started, so a missing
  cache surfaces instead of silently reading as "nothing consumed".
  """
  def value(account_id, scope_id, metric) do
    period = Date.utc_today() |> Date.to_iso8601()

    case :ets.lookup(@table, {account_id, scope_id, metric, period}) do
      [{_key, value}] -> value
      [] -> 0
    end
  end

  # Named and public so request and job processes can hit the table directly
  # instead of sending this process a message per increment.
  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end

defmodule MemHouse.Operations.Budget do
  @moduledoc """
  Applies daily usage limits to work lanes.

  Exact durable usage remains in UsageEvent; this module reads rebuildable counters for admission.
  Dream-time work is throttled before request-serving paths, and unknown lanes fail closed.
  """

  alias MemHouse.Operations.BudgetCounter

  # Token metrics the background reasoning lane is judged against. Request and
  # ingest counts are excluded on purpose: those lanes are never throttled here.
  @dream_metrics [:input_tokens, :output_tokens, :embedding_tokens]

  @doc """
  Whether the given lane may run now for this Account and scope.

  `lane` is the kind of work being admitted. The background reasoning lane is
  the only one with a ceiling: it is admitted only while today's tally for
  every configured token metric is still strictly below its limit. Any other
  lane is always admitted.

  Returns a boolean. A metric whose configured limit is missing, or is anything
  other than a non-negative integer, is treated as unbounded.

  A denial is a throttle, not an error. The background lane treats it as a
  successful no-op: the run finishes having done nothing, no durable state
  changes, and the work comes back the next time it is enqueued. Do not turn a
  denial into a failure — that would burn retry attempts on a decision that was
  intentional.
  """
  def admit?(account_id, scope_id, :dream_time) do
    limits = Application.get_env(:memhouse, :budget_limits, %{})

    Enum.all?(@dream_metrics, fn metric ->
      case Map.get(limits, metric) do
        limit when is_integer(limit) and limit >= 0 ->
          BudgetCounter.value(account_id, scope_id, metric) < limit

        _unset ->
          true
      end
    end)
  end

  # Every other lane is user-facing or governance work. Adding a lane to the
  # throttled set is a product decision about degrading behaviour under load,
  # not a tuning change.
  def admit?(_account_id, _scope_id, _lane), do: true
end
