# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.ProviderCircuit do
  @moduledoc """
  Account-scoped admission circuit for extraction provider calls.

  The gateway is the only provider invocation seam, so applying the circuit to
  the `:ingest_extractor` role there covers both single-anchor and batched
  extraction without duplicating retry policy in either pipeline path.

  State is deliberately rebuildable and content-free. A key contains the
  Account id plus the resolved role/provider identity; it never contains
  a prompt, observation, completion, credential, or source id. A node restart
  closes every circuit. Durable messages and PipelineRuns remain the source of
  truth for replay and operator repair.

  Closed circuits count consecutive transient provider failures. Reaching the
  configured threshold opens the circuit for a bounded interval. After that
  interval exactly one caller receives a half-open probe permit; concurrent
  callers fail fast. Permits issued before the opening transition become
  cleanup-only and the probe waits for them to drain, so a late result cannot
  recover or extend the open generation. A successful probe closes the
  circuit, while a failed probe starts a new open interval. Configuration and
  structured-content failures keep their existing caller classification and
  do not describe provider availability, so they do not trip this circuit.
  """

  use GenServer

  alias MemHouse.Model.Config.Role
  alias MemHouse.Model.ProviderFailure

  defmodule OpenError do
    @moduledoc "A content-free signal that extraction provider admission is temporarily open."
    defexception message: "ingest provider circuit is open"

    @type t :: %__MODULE__{}
  end

  @type key :: {String.t(), atom(), String.t()}
  @type permit :: {:provider_circuit, reference(), key(), :closed | :half_open} | :bypass

  @doc "Starts the supervised, node-local circuit state owner."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a provider permit or a content-free open-circuit error."
  @spec checkout(Role.t(), map()) :: {:ok, permit()} | {:error, OpenError.t()}
  def checkout(%Role{} = config, context) when is_map(context) do
    checkout(config, context, now_ms())
  end

  @doc """
  Checks out a permit using an explicit monotonic timestamp.

  This deterministic-clock variant has the same inputs, return shape, bypass
  behavior, and open-circuit failure as `checkout/2`. It exists for isolated
  state-machine tests; production callers use `checkout/2`.
  """
  def checkout(%Role{role: role}, _context, _now_ms) when role != :ingest_extractor,
    do: {:ok, :bypass}

  def checkout(%Role{} = config, %{account_id: account_id} = context, now_ms)
      when is_binary(account_id) and is_integer(now_ms) do
    if enabled?() do
      GenServer.call(__MODULE__, {:checkout, key(config, context), now_ms})
    else
      {:ok, :bypass}
    end
  end

  # Offline callers without a verified Account must not share one global
  # failure bucket. They bypass this Account-scoped control; actual message
  # extraction always supplies the durable message's Account id.
  def checkout(%Role{}, _context, _now_ms), do: {:ok, :bypass}

  @doc "Records the provider result for one permit. Replaying a permit is a no-op."
  @spec complete(permit(), term()) :: :ok
  def complete(:bypass, _result), do: :ok

  def complete({:provider_circuit, _token, _key, _mode} = permit, result) do
    GenServer.call(__MODULE__, {:complete, permit, result, now_ms()})
  end

  @doc """
  Completes a permit using an explicit monotonic timestamp.

  Returns `:ok`. Unknown or already-completed permits are replay-safe no-ops.
  This deterministic-clock variant is for isolated state-machine tests.
  """
  def complete({:provider_circuit, _token, _key, _mode} = permit, result, now_ms)
      when is_integer(now_ms) do
    GenServer.call(__MODULE__, {:complete, permit, result, now_ms})
  end

  @doc "Returns this Account and resolved extractor identity's content-free circuit state."
  def status(%Role{} = config, context) when is_map(context) do
    status(config, context, now_ms())
  end

  @doc """
  Returns circuit status using an explicit monotonic timestamp.

  The return is the same content-free state map as `status/2`. An Account-less
  context returns the `:bypassed` state and cannot observe another Account.
  """
  def status(%Role{} = config, %{account_id: account_id} = context, now_ms)
      when is_binary(account_id) and is_integer(now_ms) do
    GenServer.call(__MODULE__, {:status, key(config, context), now_ms})
  end

  def status(%Role{}, _context, _now_ms) do
    %{
      state: :bypassed,
      consecutive_failures: 0,
      probe_in_flight?: false,
      retry_after_ms: 0,
      in_flight: 0
    }
  end

  @doc """
  Clears all rebuildable circuit state and releases caller monitors.

  Returns `:ok`. This is a test/startup-recovery seam, not a durable repair
  action; it never changes messages, PipelineRuns, or usage rows.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_opts), do: {:ok, %{circuits: %{}, permits: %{}, monitors: %{}}}

  @impl true
  def handle_call(:reset, _from, state) do
    Enum.each(state.monitors, fn {monitor, _token} -> Process.demonitor(monitor, [:flush]) end)
    {:reply, :ok, %{circuits: %{}, permits: %{}, monitors: %{}}}
  end

  def handle_call({:status, key, now_ms}, _from, state) do
    entry = Map.get(state.circuits, key, closed_entry())

    in_flight =
      Enum.count(state.permits, fn {_token, {permit_key, _mode, _monitor}} ->
        permit_key == key
      end)

    {:reply, Map.put(snapshot(entry, now_ms), :in_flight, in_flight), state}
  end

  def handle_call({:checkout, key, now_ms}, {caller, _tag}, state) do
    entry = Map.get(state.circuits, key, closed_entry())
    in_flight = in_flight_for_key(state, key)

    case admission(entry, now_ms, in_flight) do
      {:allow, mode, next_entry, transition} ->
        token = make_ref()
        permit = {:provider_circuit, token, key, mode}
        monitor = Process.monitor(caller)

        state =
          state
          |> put_in([:circuits, key], next_entry)
          |> put_in([:permits, token], {key, mode, monitor})
          |> put_in([:monitors, monitor], token)

        maybe_emit(key, transition, next_entry)
        {:reply, {:ok, permit}, state}

      :deny ->
        emit_decision(key, :blocked, entry)
        {:reply, {:error, %OpenError{}}, state}
    end
  end

  def handle_call(
        {:complete, {:provider_circuit, token, key, mode}, result, now_ms},
        _from,
        state
      ) do
    case Map.pop(state.permits, token) do
      {{^key, ^mode, monitor}, permits} ->
        Process.demonitor(monitor, [:flush])
        entry = Map.get(state.circuits, key, closed_entry())
        {next_entry, transition} = finish(entry, mode, result, now_ms)

        state = %{
          state
          | permits: permits,
            monitors: Map.delete(state.monitors, monitor),
            circuits: Map.put(state.circuits, key, next_entry)
        }

        maybe_emit(key, transition, next_entry)
        {:reply, :ok, state}

      {_missing_or_replayed, _unchanged_permits} ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {token, monitors} ->
        {{key, mode, ^monitor}, permits} = Map.pop(state.permits, token)
        entry = Map.get(state.circuits, key, closed_entry())

        {entry, transition} =
          case mode do
            :closed ->
              {entry, nil}

            :half_open ->
              {%{entry | state: :open, opened_at_ms: now_ms(), probe_in_flight?: false},
               :probe_abandoned}
          end

        state = %{
          state
          | permits: permits,
            monitors: monitors,
            circuits: Map.put(state.circuits, key, entry)
        }

        maybe_emit(key, transition, entry)
        {:noreply, state}
    end
  end

  defp admission(%{state: :closed} = entry, _now_ms, _in_flight),
    do: {:allow, :closed, entry, nil}

  defp admission(%{state: :open, opened_at_ms: opened_at_ms} = entry, now_ms, in_flight) do
    # A permit issued while closed may still be inside the provider when later
    # failures open the circuit. Do not begin the designated half-open probe
    # until those older calls drain; otherwise their late completion could
    # close the circuit while the probe is still running.
    if now_ms - opened_at_ms >= open_ms() and in_flight == 0 do
      next = %{entry | state: :half_open, probe_in_flight?: true}
      {:allow, :half_open, next, :half_opened}
    else
      :deny
    end
  end

  defp admission(%{state: :half_open}, _now_ms, _in_flight), do: :deny

  defp finish(%{state: :closed}, :closed, {:ok, _provider_result}, _now_ms),
    do: {closed_entry(), nil}

  defp finish(_entry, :half_open, {:ok, _provider_result}, _now_ms),
    do: {closed_entry(), :closed}

  defp finish(%{state: :closed} = entry, :closed, {:error, error}, now_ms) do
    if ProviderFailure.transient?(error) do
      record_failure(entry, :closed, now_ms)
    else
      {entry, nil}
    end
  end

  defp finish(entry, :half_open, {:error, error}, now_ms) do
    if ProviderFailure.transient?(error) do
      record_failure(entry, :half_open, now_ms)
    else
      # A half-open probe that reached the provider but received a permanent
      # configuration/content failure proves connectivity. Close the
      # availability circuit and leave the original error to its caller.
      {closed_entry(), :closed}
    end
  end

  defp finish(%{state: :closed} = entry, :closed, _malformed_provider_result, now_ms),
    do: record_failure(entry, :closed, now_ms)

  defp finish(entry, :half_open, _malformed_provider_result, now_ms),
    do: record_failure(entry, :half_open, now_ms)

  # Once another completion opens the circuit, every permit issued by the
  # prior closed generation becomes cleanup-only. Its late result cannot close
  # the circuit or move the original open interval. Half-open admission waits
  # for all such permits to drain, so only the designated probe can recover.
  defp finish(entry, :closed, _stale_result, _now_ms), do: {entry, nil}

  defp record_failure(entry, :half_open, now_ms) do
    {%{entry | state: :open, opened_at_ms: now_ms, probe_in_flight?: false}, :reopened}
  end

  defp record_failure(entry, :closed, now_ms) do
    failures = entry.consecutive_failures + 1

    if failures >= failure_threshold() do
      {%{
         entry
         | state: :open,
           consecutive_failures: failures,
           opened_at_ms: now_ms,
           probe_in_flight?: false
       }, :opened}
    else
      {%{entry | consecutive_failures: failures}, nil}
    end
  end

  defp snapshot(entry, now_ms) do
    retry_after_ms =
      case entry do
        %{state: :open, opened_at_ms: opened_at_ms} -> max(open_ms() - (now_ms - opened_at_ms), 0)
        _other -> 0
      end

    %{
      state: entry.state,
      consecutive_failures: entry.consecutive_failures,
      probe_in_flight?: entry.probe_in_flight?,
      retry_after_ms: retry_after_ms
    }
  end

  defp closed_entry do
    %{state: :closed, consecutive_failures: 0, opened_at_ms: nil, probe_in_flight?: false}
  end

  defp key(config, context) do
    {
      Map.fetch!(context, :account_id),
      config.role,
      config.provider
    }
  end

  defp in_flight_for_key(state, key) do
    Enum.count(state.permits, fn {_token, {permit_key, _mode, _monitor}} ->
      permit_key == key
    end)
  end

  defp enabled? do
    :memhouse
    |> Application.fetch_env!(:ingest_provider_circuit)
    |> Keyword.fetch!(:enabled)
  end

  defp failure_threshold do
    :memhouse
    |> Application.fetch_env!(:ingest_provider_circuit)
    |> Keyword.fetch!(:failure_threshold)
  end

  defp open_ms do
    :memhouse
    |> Application.fetch_env!(:ingest_provider_circuit)
    |> Keyword.fetch!(:open_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp maybe_emit(_key, nil, _entry), do: :ok
  defp maybe_emit(key, transition, entry), do: emit_decision(key, transition, entry)

  defp emit_decision({account_id, role, provider}, decision, entry) do
    :telemetry.execute(
      [:memhouse, :model, :provider_circuit],
      %{consecutive_failures: entry.consecutive_failures},
      %{
        account_id: account_id,
        role: role,
        provider: provider,
        state: entry.state,
        decision: decision
      }
    )
  end
end
