# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.ProviderCircuitTest.Provider do
  @moduledoc "Records provider calls for circuit-breaker integration tests."

  @behaviour MemHouse.Model.Provider

  @doc "Starts or resets the call counter."
  def start! do
    case Agent.start(fn -> 0 end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> Agent.update(__MODULE__, fn _ -> 0 end)
    end
  end

  @doc "Stops the call counter when it is running."
  def stop do
    if pid = Process.whereis(__MODULE__) do
      try do
        Agent.stop(pid)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  @doc "Returns the number of provider callbacks observed by this test provider."
  def calls, do: Agent.get(__MODULE__, & &1)

  @impl true
  def structured(_config, _messages, _schema, _opts) do
    Agent.update(__MODULE__, &(&1 + 1))
    {:error, :provider_upstream_error}
  end

  @impl true
  def chat(_config, _messages, _opts), do: {:error, :unsupported}

  @impl true
  def embed(_config, _texts, _opts), do: {:error, :unsupported}

  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :unsupported}
end

defmodule MemHouse.Model.ProviderCircuitTest.ExitingProvider do
  @moduledoc "Simulates a provider exit without terminating the test process."

  @behaviour MemHouse.Model.Provider

  @impl true
  @doc "Exits to exercise gateway permit cleanup."
  def structured(_config, _messages, _schema, _opts), do: exit(:provider_timeout)

  @impl true
  @doc "Returns unsupported for unused chat calls."
  def chat(_config, _messages, _opts), do: {:error, :unsupported}

  @impl true
  @doc "Returns unsupported for unused embedding calls."
  def embed(_config, _texts, _opts), do: {:error, :unsupported}

  @impl true
  @doc "Returns unsupported for unused reranking calls."
  def rerank(_config, _query, _documents, _opts), do: {:error, :unsupported}
end

defmodule MemHouse.Model.ProviderCircuitTest do
  @moduledoc """
  Verifies provider-circuit admission, recovery, cleanup, and Account isolation.
  """

  use ExUnit.Case, async: false

  alias MemHouse.Model.Config.Role
  alias MemHouse.Model.Gateway
  alias MemHouse.Model.ProviderCircuit
  alias MemHouse.Model.ProviderCircuitTest.ExitingProvider
  alias MemHouse.Model.ProviderCircuitTest.Provider
  alias MemHouse.Pipeline.Extractor

  @config %Role{
    role: :ingest_extractor,
    provider: "test-provider",
    model: "test-model",
    model_version: "v1",
    prompt_version: "extract-13",
    pipeline_version: "f5-1",
    config_version: 1,
    options: %{}
  }

  setup do
    previous_circuit = Application.fetch_env!(:memhouse, :ingest_provider_circuit)
    previous_provider = Application.get_env(:memhouse, :model_provider)

    Application.put_env(:memhouse, :ingest_provider_circuit,
      enabled: true,
      failure_threshold: 2,
      open_ms: 100
    )

    ProviderCircuit.reset()
    Provider.start!()

    on_exit(fn ->
      Provider.stop()
      ProviderCircuit.reset()
      Application.put_env(:memhouse, :ingest_provider_circuit, previous_circuit)

      if previous_provider do
        Application.put_env(:memhouse, :model_provider, previous_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    :ok
  end

  test "opens after bounded consecutive failures and reports content-free state" do
    events = attach_events()
    context = %{account_id: Ecto.UUID.generate()}

    assert {:ok, first} = ProviderCircuit.checkout(@config, context, 0)
    assert :ok = ProviderCircuit.complete(first, {:error, :provider_upstream_error}, 0)
    assert ProviderCircuit.status(@config, context, 0).state == :closed

    assert {:ok, second} = ProviderCircuit.checkout(@config, context, 1)
    assert :ok = ProviderCircuit.complete(second, {:error, :provider_upstream_error}, 1)

    assert %{
             state: :open,
             consecutive_failures: 2,
             probe_in_flight?: false,
             retry_after_ms: 100
           } = ProviderCircuit.status(@config, context, 1)

    assert {:error, %ProviderCircuit.OpenError{}} =
             ProviderCircuit.checkout(@config, context, 2)

    assert_receive {:circuit, %{consecutive_failures: 2}, %{decision: :opened, state: :open}}
    assert_receive {:circuit, %{consecutive_failures: 2}, %{decision: :blocked, state: :open}}

    :telemetry.detach(events)
  end

  test "admits one half-open probe, recovers on success, and replays completion once" do
    context = %{account_id: Ecto.UUID.generate()}
    open!(context, 0)

    parent = self()

    callers =
      Enum.map(1..24, fn _ ->
        spawn(fn ->
          result = ProviderCircuit.checkout(@config, context, 100)
          send(parent, {:checkout_result, self(), result})

          if match?({:ok, _permit}, result) do
            receive do
              :release -> :ok
            end
          end
        end)
      end)

    results =
      Enum.map(1..24, fn _ ->
        assert_receive {:checkout_result, owner, result}
        {owner, result}
      end)

    assert [{probe_owner, {:ok, probe}}] =
             Enum.filter(results, fn {_owner, result} -> match?({:ok, _permit}, result) end)

    assert Enum.count(results, fn {_owner, result} ->
             match?({:error, %ProviderCircuit.OpenError{}}, result)
           end) == 23

    assert ProviderCircuit.status(@config, context, 100).state == :half_open

    assert :ok = ProviderCircuit.complete(probe, {:ok, %{}}, 100)
    send(probe_owner, :release)
    assert length(callers) == 24
    assert ProviderCircuit.status(@config, context, 100).state == :closed

    # Duplicate job/result delivery cannot update counters a second time.
    assert :ok = ProviderCircuit.complete(probe, {:error, :provider_upstream_error}, 101)
    assert ProviderCircuit.status(@config, context, 101).consecutive_failures == 0
  end

  test "failed half-open probe reopens from its completion time" do
    context = %{account_id: Ecto.UUID.generate()}
    open!(context, 0)

    assert {:ok, probe} = ProviderCircuit.checkout(@config, context, 100)
    assert :ok = ProviderCircuit.complete(probe, {:error, :provider_upstream_error}, 140)

    assert %{state: :open, retry_after_ms: 100} =
             ProviderCircuit.status(@config, context, 140)

    assert {:error, %ProviderCircuit.OpenError{}} =
             ProviderCircuit.checkout(@config, context, 239)

    assert {:ok, _next_probe} = ProviderCircuit.checkout(@config, context, 240)
  end

  test "a stale success only drains and preserves the original open interval" do
    Application.put_env(:memhouse, :ingest_provider_circuit,
      enabled: true,
      failure_threshold: 1,
      open_ms: 100
    )

    context = %{account_id: Ecto.UUID.generate()}
    assert {:ok, older} = ProviderCircuit.checkout(@config, context, 0)
    assert {:ok, failing} = ProviderCircuit.checkout(@config, context, 0)
    assert :ok = ProviderCircuit.complete(failing, {:error, :provider_upstream_error}, 0)
    assert ProviderCircuit.status(@config, context, 50).state == :open

    assert {:error, %ProviderCircuit.OpenError{}} =
             ProviderCircuit.checkout(@config, context, 50)

    assert :ok = ProviderCircuit.complete(older, {:ok, %{}}, 50)

    assert %{state: :open, retry_after_ms: 50, in_flight: 0} =
             ProviderCircuit.status(@config, context, 50)

    assert {:error, %ProviderCircuit.OpenError{}} =
             ProviderCircuit.checkout(@config, context, 99)

    assert {:ok, _designated_probe} = ProviderCircuit.checkout(@config, context, 100)
  end

  test "a stale failure only drains and preserves the original open interval" do
    Application.put_env(:memhouse, :ingest_provider_circuit,
      enabled: true,
      failure_threshold: 1,
      open_ms: 100
    )

    context = %{account_id: Ecto.UUID.generate()}
    assert {:ok, older} = ProviderCircuit.checkout(@config, context, 0)
    assert {:ok, failing} = ProviderCircuit.checkout(@config, context, 0)
    assert :ok = ProviderCircuit.complete(failing, {:error, :provider_upstream_error}, 0)

    assert {:error, %ProviderCircuit.OpenError{}} =
             ProviderCircuit.checkout(@config, context, 50)

    assert :ok = ProviderCircuit.complete(older, {:error, :provider_upstream_error}, 50)

    assert %{state: :open, retry_after_ms: 50, in_flight: 0} =
             ProviderCircuit.status(@config, context, 50)

    assert {:error, %ProviderCircuit.OpenError{}} =
             ProviderCircuit.checkout(@config, context, 99)

    assert {:ok, _probe} = ProviderCircuit.checkout(@config, context, 100)
  end

  test "caller death releases closed permits and reopens an abandoned half-open probe" do
    context = %{account_id: Ecto.UUID.generate()}
    parent = self()

    closed_owner =
      spawn(fn ->
        send(parent, {:closed_checkout, ProviderCircuit.checkout(@config, context, 0)})
      end)

    closed_ref = Process.monitor(closed_owner)
    assert_receive {:closed_checkout, {:ok, _permit}}
    assert_receive {:DOWN, ^closed_ref, :process, ^closed_owner, _reason}
    assert_eventually(fn -> ProviderCircuit.status(@config, context, 0).in_flight == 0 end)

    open!(context, 0)

    probe_owner =
      spawn(fn ->
        result = ProviderCircuit.checkout(@config, context, 100)
        send(parent, {:probe_checkout, result})
      end)

    assert_receive {:probe_checkout, {:ok, _permit}}
    probe_ref = Process.monitor(probe_owner)
    assert_receive {:DOWN, ^probe_ref, :process, ^probe_owner, _reason}

    assert_eventually(fn ->
      status = ProviderCircuit.status(@config, context)
      status.state == :open and status.in_flight == 0 and not status.probe_in_flight?
    end)
  end

  test "gateway converts provider exits and completes the circuit permit" do
    context = %{account_id: Ecto.UUID.generate()}
    Application.put_env(:memhouse, :model_provider, ExitingProvider)
    config = MemHouse.Model.role_config(:ingest_extractor, context)

    assert {:error, {:provider_exit, :provider_timeout}} =
             Gateway.structured_once(:ingest_extractor, [], %{}, context)

    assert ProviderCircuit.status(config, context, 0).in_flight == 0
  end

  test "state is isolated by Account and permanent provider errors do not trip availability" do
    account_a = %{account_id: Ecto.UUID.generate()}
    account_b = %{account_id: Ecto.UUID.generate()}
    open!(account_a, 0)

    assert ProviderCircuit.status(@config, account_a, 1).state == :open
    assert ProviderCircuit.status(@config, account_b, 1).state == :closed
    assert {:ok, permit} = ProviderCircuit.checkout(@config, account_b, 1)

    assert :ok =
             ProviderCircuit.complete(
               permit,
               {:error, %{class: :invalid}},
               1
             )

    assert ProviderCircuit.status(@config, account_b, 1).consecutive_failures == 0
  end

  test "one Account/provider/role circuit spans model identities but not providers" do
    context = %{account_id: Ecto.UUID.generate()}
    open!(context, 0)

    same_provider_new_model = %{
      @config
      | model: "replacement-model",
        model_version: "v2"
    }

    other_provider = %{@config | provider: "other-provider"}

    assert ProviderCircuit.status(same_provider_new_model, context, 1).state == :open
    assert ProviderCircuit.status(other_provider, context, 1).state == :closed
  end

  test "gateway blocks extraction without recording another provider attempt" do
    Application.put_env(:memhouse, :model_provider, Provider)

    Application.put_env(:memhouse, :ingest_provider_circuit,
      enabled: true,
      failure_threshold: 1,
      open_ms: 30_000
    )

    context = %{account_id: Ecto.UUID.generate()}

    assert {:error, :provider_upstream_error} =
             Gateway.structured_once(:ingest_extractor, [], %{}, context)

    assert {:error, %ProviderCircuit.OpenError{}} =
             Gateway.structured_once(:ingest_extractor, [], %{}, context)

    assert Provider.calls() == 1
    assert Gateway.error_class(%ProviderCircuit.OpenError{}) == "provider_circuit_open"
  end

  test "single and batched extractor paths share gateway circuit admission" do
    Application.put_env(:memhouse, :model_provider, Provider)

    Application.put_env(:memhouse, :ingest_provider_circuit,
      enabled: true,
      failure_threshold: 1,
      open_ms: 30_000
    )

    account_id = Ecto.UUID.generate()
    message = message(account_id)
    context = %{account_id: account_id}

    # Structured generation would ordinarily retry provider_upstream_error.
    # The first failure opens admission, so its repair and the replayed single
    # extraction fail fast without more billed calls.
    assert {:error, %ProviderCircuit.OpenError{}} = Extractor.extract(message, context)
    assert {:error, %ProviderCircuit.OpenError{}} = Extractor.extract(message, context)
    assert Provider.calls() == 1

    ProviderCircuit.reset()
    Provider.start!()

    assert {:error, %ProviderCircuit.OpenError{}} =
             Extractor.extract_batch([%{message: message, context: context}])

    assert Provider.calls() == 1
  end

  test "missing Account context bypasses rather than coupling unrelated callers" do
    assert {:ok, :bypass} = ProviderCircuit.checkout(@config, %{}, 0)
    assert ProviderCircuit.status(@config, %{}, 0).state == :bypassed
  end

  defp open!(context, now_ms) do
    assert {:ok, first} = ProviderCircuit.checkout(@config, context, now_ms)
    assert :ok = ProviderCircuit.complete(first, {:error, :provider_upstream_error}, now_ms)
    assert {:ok, second} = ProviderCircuit.checkout(@config, context, now_ms)
    assert :ok = ProviderCircuit.complete(second, {:error, :provider_upstream_error}, now_ms)
    assert ProviderCircuit.status(@config, context, now_ms).state == :open
  end

  defp message(account_id) do
    %{
      "id" => Ecto.UUID.generate(),
      "account_id" => account_id,
      "peer_id" => Ecto.UUID.generate(),
      "scope_id" => Ecto.UUID.generate(),
      "session_id" => Ecto.UUID.generate(),
      "peer_key" => "avery",
      "scope_path" => "/provider-circuit",
      "known_peer_keys" => ["avery"],
      "occurred_at" => ~U[2026-08-17 12:00:00Z],
      "content" => "Avery owns the release checklist."
    }
  end

  defp attach_events do
    id = "provider-circuit-#{System.unique_integer([:positive])}"
    owner = self()

    :ok =
      :telemetry.attach(
        id,
        [:memhouse, :model, :provider_circuit],
        fn _event, measurements, metadata, _config ->
          send(owner, {:circuit, measurements, metadata})
        end,
        nil
      )

    id
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
