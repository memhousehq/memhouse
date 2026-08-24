# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.DreamTimeTest do
  use MemHouse.DataCase, async: false

  defmodule Provider do
    @moduledoc "Reports dream operation selection before delegating to the deterministic provider."
    @behaviour MemHouse.Model.Provider

    alias MemHouse.Model.Provider.Result
    alias MemHouse.Model.Providers.Deterministic

    @impl true
    def structured(config, messages, schema, opts) do
      if pid = Application.get_env(:memhouse, :dream_time_test_pid) do
        task = Keyword.get(opts, :task)
        send(pid, {:dream_reasoner_call, task, opts})
        send(pid, {:dream_reasoner_task, task})
        send(pid, {:dream_reasoner_input, task, messages})
      end

      case Application.get_env(:memhouse, :dream_time_test_values) do
        nil ->
          Deterministic.structured(config, messages, schema, opts)

        values ->
          value = Agent.get_and_update(values, fn [value | rest] -> {value, rest} end)

          if Keyword.get(opts, :repair_attempt) == 0 do
            Agent.update(Application.fetch_env!(:memhouse, :dream_time_test_clock), &(&1 + 7))
          end

          {:ok, %Result{value: value, usage: %{input_tokens: 7, output_tokens: 3}}}
      end
    end

    @impl true
    def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

    @impl true
    def embed(config, texts, opts), do: Deterministic.embed(config, texts, opts)

    @impl true
    def rerank(config, query, documents, opts),
      do: Deterministic.rerank(config, query, documents, opts)
  end

  defmodule DeadlineClock do
    @moduledoc "Provides a deterministic monotonic clock for dream deadline tests."
    @behaviour MemHouse.Clock

    @impl true
    def utc_now, do: MemHouse.Clock.System.utc_now()

    @impl true
    def monotonic_ms do
      Agent.get(Application.fetch_env!(:memhouse, :dream_time_test_clock), & &1)
    end
  end

  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Identity
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Pipeline.DreamTime
  alias MemHouse.Pipeline.DreamTime.Gate
  alias MemHouse.Topology.Scope

  require Ash.Query

  test "hourly and manual dream-time retain one legacy reasoner call by default" do
    provider = Application.get_env(:memhouse, :model_provider)
    operations = Application.fetch_env!(:memhouse, :dream_reasoning_operations)

    Application.put_env(:memhouse, :model_provider, Provider)
    Application.put_env(:memhouse, :dream_time_test_pid, self())

    Application.put_env(
      :memhouse,
      :dream_reasoning_operations,
      Keyword.put(operations, :split_enabled, false)
    )

    on_exit(fn ->
      Application.put_env(:memhouse, :model_provider, provider)
      Application.delete_env(:memhouse, :dream_time_test_pid)
      Application.put_env(:memhouse, :dream_reasoning_operations, operations)
    end)

    account_id = seed_active!("dream-time-legacy-default")

    assert {:ok, %{scopes: 1}} = DreamTime.run(account_id)
    assert_receive {:dream_reasoner_call, :reasoning, _opts}
    refute_receive {:dream_reasoner_call, :reasoning, _opts}
    refute_receive {:dream_reasoner_call, :reasoning_update, _opts}
    refute_receive {:dream_reasoner_call, :reasoning_synthesis, _opts}
  end

  test "legacy dream-time repairs receive only the pass time that remains" do
    provider = Application.get_env(:memhouse, :model_provider)
    clock_module = Application.get_env(:memhouse, :clock)
    operations = Application.fetch_env!(:memhouse, :dream_reasoning_operations)
    gates = Application.fetch_env!(:memhouse, :dream_time_gates)
    clock = start_supervised!({Agent, fn -> 100 end}, id: :dream_time_test_clock)

    values =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{"items" => [%{}], "relations" => []},
             %{"items" => [], "relations" => []}
           ]
         end},
        id: :dream_time_test_values
      )

    Application.put_env(:memhouse, :model_provider, Provider)
    Application.put_env(:memhouse, :clock, DeadlineClock)
    Application.put_env(:memhouse, :dream_time_test_clock, clock)
    Application.put_env(:memhouse, :dream_time_test_pid, self())

    Application.put_env(
      :memhouse,
      :dream_reasoning_operations,
      Keyword.put(operations, :split_enabled, false)
    )

    Application.put_env(:memhouse, :dream_time_gates, Keyword.put(gates, :max_elapsed_ms, 20))

    on_exit(fn ->
      Application.put_env(:memhouse, :model_provider, provider)

      if clock_module,
        do: Application.put_env(:memhouse, :clock, clock_module),
        else: Application.delete_env(:memhouse, :clock)

      Application.delete_env(:memhouse, :dream_time_test_clock)
      Application.delete_env(:memhouse, :dream_time_test_values)
      Application.delete_env(:memhouse, :dream_time_test_pid)
      Application.put_env(:memhouse, :dream_reasoning_operations, operations)
      Application.put_env(:memhouse, :dream_time_gates, gates)
    end)

    account_id = seed_active!("dream-time-legacy-deadline")
    Application.put_env(:memhouse, :dream_time_test_values, values)

    assert {:ok, %{scopes: 1}} = DreamTime.run(account_id)

    assert_receive {:dream_reasoner_call, :reasoning, first_opts}
    assert Keyword.fetch!(first_opts, :request_timeout) == 20
    assert Keyword.fetch!(first_opts, :repair_attempt) == 0

    assert_receive {:dream_reasoner_call, :reasoning, repair_opts}
    assert Keyword.fetch!(repair_opts, :request_timeout) == 13
    assert Keyword.fetch!(repair_opts, :repair_attempt) == 1
  end

  test "a scope without an active-knowledge delta does not call the reasoner" do
    %{actor: actor} =
      Identity.bootstrap_human(%{
        email: "dream-time-empty@example.test",
        name: "Dream Time Empty",
        password: "correct horse battery staple"
      })

    scope =
      DataLayer.with_actor(actor, fn account, current_actor ->
        Scope
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:ensure, %{
          key: "empty",
          name: "Empty",
          path: "/empty",
          state: "active"
        })
        |> Ash.create!(actor: current_actor)
      end)

    handler = {__MODULE__, self(), :gate}
    test_process = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :pipeline, :dream_gate],
        fn _event, measurements, metadata, _config ->
          send(test_process, {:dream_gate, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    operation_handler = {__MODULE__, self(), :operation}

    :ok =
      :telemetry.attach(
        operation_handler,
        [:memhouse, :operation, :completed],
        fn _event, measurements, metadata, _config ->
          send(test_process, {:operation, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(operation_handler) end)

    assert {:ok, %{scopes: 0, throttled: 0, items: 0, relations: 0}} =
             DreamTime.run(actor.account_id)

    assert {:ok, %{status: :no_delta}} = DreamTime.run_scope(actor.account_id, scope.id)

    assert_receive {:dream_gate, %{eligible_changes: 0}, metadata}
    assert metadata.decision == :skip
    assert metadata.reason == :no_delta
    assert metadata.account_id == actor.account_id
    refute inspect(metadata) =~ "Dream Time Empty"

    assert_receive {:operation, operation_measurements, operation_metadata}
    assert operation_metadata.operation == "dream"
    assert operation_metadata.account_id == actor.account_id
    assert operation_measurements.calls == 0
    assert operation_measurements.items == 0
    refute inspect({operation_measurements, operation_metadata}) =~ "Dream Time Empty"
  end

  test "dream-time excludes active inputs whose expiry passed before the lifecycle sweep" do
    provider = Application.get_env(:memhouse, :model_provider)
    gates = Application.fetch_env!(:memhouse, :dream_time_gates)

    Application.put_env(:memhouse, :model_provider, Provider)
    Application.put_env(:memhouse, :dream_time_test_pid, self())

    Application.put_env(
      :memhouse,
      :dream_time_gates,
      Keyword.merge(gates,
        min_changes: 1,
        idle_seconds: 0,
        min_interval_seconds: 0,
        max_delta_items: 10,
        max_working_set_items: 10
      )
    )

    on_exit(fn ->
      Application.put_env(:memhouse, :model_provider, provider)
      Application.delete_env(:memhouse, :dream_time_test_pid)
      Application.put_env(:memhouse, :dream_time_gates, gates)
    end)

    visible =
      seed_active_record!(
        "dream-time-expiry",
        "visible-input",
        "Avery prefers concise weekly updates."
      )

    expired =
      seed_active_record!(
        "dream-time-expiry",
        "expired-input",
        "Avery keeps the obsolete deployment checklist."
      )

    DataLayer.with_account_key("dream-time-expiry", [role: :system, pipeline?: true], fn
      _account, actor ->
        Engine.transition!(
          expired.knowledge,
          actor,
          %{state: "active", expires_at: DateTime.add(MemHouse.Clock.utc_now(), -1, :hour)},
          reason: "dream_time_test_expire_before_sweep",
          channel: "pipeline"
        )
    end)

    assert {:ok, %{status: :completed}} =
             DreamTime.run_scope(visible.account.id, visible.scope.id)

    assert_receive {:dream_reasoner_input, :reasoning, messages}
    input = messages |> List.last() |> Map.fetch!(:content) |> Jason.decode!()

    for field <- ["delta", "working_set"] do
      ids = Map.fetch!(input, field) |> Enum.map(& &1["id"])
      assert visible.knowledge.id in ids
      refute expired.knowledge.id in ids
    end
  end

  test "change, idle, interval, and work gates are deterministic and independent" do
    now = ~U[2026-08-17 12:00:00.000000Z]

    config =
      [
        min_changes: 3,
        idle_seconds: 60,
        min_interval_seconds: 300,
        max_delta_items: 7,
        max_working_set_items: 11,
        max_elapsed_ms: 9_000
      ]

    assert Gate.decide(0, nil, nil, now, config) == {:skip, :no_delta}

    assert Gate.decide(2, DateTime.add(now, -600), nil, now, config) ==
             {:skip, :change_threshold}

    assert Gate.decide(3, DateTime.add(now, -59), nil, now, config) ==
             {:skip, :idle_time}

    assert Gate.decide(
             3,
             DateTime.add(now, -60),
             DateTime.add(now, -299),
             now,
             config
           ) == {:skip, :minimum_interval}

    assert {:run, limits} =
             Gate.decide(
               3,
               DateTime.add(now, -60),
               DateTime.add(now, -300),
               now,
               config
             )

    assert limits.max_delta_items == 7
    assert limits.max_working_set_items == 11
    assert limits.max_elapsed_ms == 9_000
  end

  test "invalid dream-time work limits fail closed" do
    assert_raise ArgumentError, ~r/max_delta_items must be positive/, fn ->
      Gate.decide(1, ~U[2026-08-17 11:00:00Z], nil, ~U[2026-08-17 12:00:00Z],
        min_changes: 1,
        idle_seconds: 0,
        min_interval_seconds: 0,
        max_delta_items: 0,
        max_working_set_items: 50,
        max_elapsed_ms: 1_000
      )
    end
  end

  test "current knowledge candidate maps do not require a private record field" do
    first_id = Ash.UUID.generate()
    second_id = Ash.UUID.generate()

    candidates = [
      %{
        "candidate_type" => "knowledge",
        "id" => first_id,
        "statement" => "The candidate has the public retrieval shape.",
        "fusion_score" => 0.8,
        "strategies" => ["semantic", "lexical"]
      },
      %{"candidate_type" => "knowledge", "id" => second_id, "fusion_score" => 0.4}
    ]

    assert {:ok, [^first_id, ^second_id]} = DreamTime.candidate_ids(candidates)
  end

  test "a malformed candidate returns one content-safe diagnostic error" do
    assert {:error,
            %DreamTime.InvalidCandidate{position: 0, reason: "missing knowledge id"} = error} =
             DreamTime.candidate_ids([
               %{"candidate_type" => "knowledge", "statement" => "secret"}
             ])

    refute Exception.message(error) =~ "secret"
  end

  defp seed_active!(account_key) do
    account_key
    |> seed_active_record!("legacy-default", "Avery prefers concise weekly updates.")
    |> then(& &1.account.id)
  end

  defp seed_active_record!(account_key, session_id, statement) do
    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => session_id,
               "scope_path" => "/dream",
               "peer_key" => "avery",
               "content" => statement
             })

    assert {:ok, [knowledge]} = Memory.extract_message(message["id"], account_key)

    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account, actor ->
      item =
        KnowledgeItem
        |> Ash.Query.filter(id == ^knowledge["id"])
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)
        |> Engine.transition!(
          actor,
          %{state: "active", verification: "test"},
          reason: "dream_time_test_activate",
          channel: "pipeline"
        )

      scope =
        Scope
        |> Ash.Query.filter(id == ^item.scope_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)

      %{account: account, scope: scope, knowledge: item}
    end)
  end
end
