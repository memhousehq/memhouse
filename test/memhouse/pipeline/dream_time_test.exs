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

          if Application.get_env(:memhouse, :dream_time_pause_reasoning?, false) do
            owner = Application.fetch_env!(:memhouse, :dream_time_test_pid)
            send(owner, {:dream_reasoning_paused, self()})

            receive do
              :release_dream_reasoning -> :ok
            after
              5_000 -> raise "timed out waiting to release the DreamTime reasoning fixture"
            end
          end

          {:ok, %Result{value: value, usage: %{input_tokens: 7, output_tokens: 3}}}
      end
    end

    @impl true
    def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

    @impl true
    def embed(config, texts, opts) do
      if Application.get_env(:memhouse, :dream_time_pause_retrieval?, false) do
        Application.put_env(:memhouse, :dream_time_pause_retrieval?, false)
        owner = Application.fetch_env!(:memhouse, :dream_time_test_pid)
        send(owner, {:dream_retrieval_paused, self()})

        receive do
          :release_dream_retrieval -> :ok
        after
          5_000 -> raise "timed out waiting to release the DreamTime retrieval fixture"
        end
      end

      Deterministic.embed(config, texts, opts)
    end

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

  alias MemHouse.Accounts.Peer
  alias MemHouse.DataLayer
  alias MemHouse.Governance.{AuditEvent, Engine, ValidationItem}
  alias MemHouse.Identity
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation, LifecycleEvent, Provenance}
  alias MemHouse.Memory
  alias MemHouse.Operations.{DreamTimeWatermark, PipelineRun}
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

  test "dream-time retries without advancing when an input expires before provider submission" do
    provider = Application.get_env(:memhouse, :model_provider)
    gates = Application.fetch_env!(:memhouse, :dream_time_gates)
    operations = Application.fetch_env!(:memhouse, :dream_reasoning_operations)

    Application.put_env(:memhouse, :model_provider, Provider)
    Application.put_env(:memhouse, :dream_time_test_pid, self())

    Application.put_env(
      :memhouse,
      :dream_reasoning_operations,
      Keyword.put(operations, :split_enabled, false)
    )

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
      Application.delete_env(:memhouse, :dream_time_pause_retrieval?)
      Application.put_env(:memhouse, :dream_time_gates, gates)
      Application.put_env(:memhouse, :dream_reasoning_operations, operations)
    end)

    seeded =
      seed_active_record!(
        "dream-time-in-flight-expiry",
        "expiring-input",
        "Avery keeps the deployment checklist."
      )

    future_item =
      DataLayer.with_account_key(
        "dream-time-in-flight-expiry",
        [role: :system, pipeline?: true],
        fn _account, actor ->
          Engine.transition!(
            seeded.knowledge,
            actor,
            %{state: "active", expires_at: DateTime.add(MemHouse.Clock.utc_now(), 1, :hour)},
            reason: "dream_time_test_future_expiry",
            channel: "pipeline"
          )
        end
      )

    Application.put_env(:memhouse, :dream_time_pause_retrieval?, true)

    dream =
      Task.async(fn ->
        receive do
          :start -> DreamTime.run_scope(seeded.account.id, seeded.scope.id)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(MemHouse.Repo, self(), dream.pid)
    send(dream.pid, :start)

    assert_receive {:dream_retrieval_paused, retrieval_pid}, 5_000

    DataLayer.with_account_key(
      "dream-time-in-flight-expiry",
      [role: :system, pipeline?: true],
      fn _account, actor ->
        Engine.transition!(
          future_item,
          actor,
          %{state: "active", expires_at: DateTime.add(MemHouse.Clock.utc_now(), -1, :second)},
          reason: "dream_time_test_expire_during_retrieval",
          channel: "pipeline"
        )
      end
    )

    send(retrieval_pid, :release_dream_retrieval)

    assert {:error, :stale_dream_time_input} = Task.await(dream, 10_000)
    refute_receive {:dream_reasoner_input, :reasoning, _}

    DataLayer.with_account_key(
      "dream-time-in-flight-expiry",
      [role: :system, pipeline?: true],
      fn account, actor ->
        watermark =
          DreamTimeWatermark
          |> Ash.Query.filter(scope_id == ^seeded.scope.id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: actor)

        assert is_nil(watermark)
      end
    )
  end

  test "a stale relation rolls back the complete dream-time effect bundle" do
    configure_legacy_reasoning!(notify?: true, pause?: true)

    first =
      seed_active_record!(
        "dream-time-atomic-bundle",
        "deduction-first",
        "Avery owns the weekly release checklist."
      )

    second =
      seed_active_record!(
        "dream-time-atomic-bundle",
        "deduction-second",
        "Avery reviews the weekly release checklist."
      )

    stale_endpoint =
      seed_active_record!(
        "dream-time-atomic-bundle",
        "stale-relation-endpoint",
        "Avery archives the weekly release checklist."
      )

    values =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{
               "items" => [deduction(first.knowledge.id, second.knowledge.id)],
               "relations" => [
                 %{
                   "source_id" => first.knowledge.id,
                   "target_id" => stale_endpoint.knowledge.id,
                   "kind" => "supports"
                 }
               ]
             }
           ]
         end},
        id: :dream_time_test_values
      )

    Application.put_env(:memhouse, :dream_time_test_values, values)

    {dream, reasoning_pid, messages} =
      start_paused_dream(first.account.id, first.scope.id)

    assert %{
             "peer_keys" => ["avery"],
             "scope_path" => "/dream"
           } = allowed_subject_refs(messages)

    stale_endpoint =
      DataLayer.with_account_key(
        "dream-time-atomic-bundle",
        [role: :system, pipeline?: true],
        fn _account, actor ->
          Engine.transition!(
            stale_endpoint.knowledge,
            actor,
            %{state: "needs_revalidation", verification: "test_stale_relation"},
            reason: "dream_time_test_stale_relation_endpoint",
            channel: "pipeline"
          )
        end
      )

    baseline = effect_snapshot(first.account.id, first.scope.id)
    send(reasoning_pid, :release_dream_reasoning)

    assert {:raised, %Ash.Error.Query.NotFound{}} = Task.await(dream, 10_000)
    assert stale_endpoint.state == "needs_revalidation"
    assert effect_snapshot(first.account.id, first.scope.id) == baseline
  end

  test "a peer becoming an agent during replayed reasoning fails closed" do
    configure_legacy_reasoning!(notify?: true)

    first =
      seed_active_record!(
        "dream-time-peer-kind-race",
        "deduction-first",
        "Avery owns the weekly release checklist."
      )

    second =
      seed_active_record!(
        "dream-time-peer-kind-race",
        "deduction-second",
        "Avery reviews the weekly release checklist."
      )

    response = %{
      "items" => [deduction(first.knowledge.id, second.knowledge.id)],
      "relations" => []
    }

    values =
      start_supervised!(
        {Agent,
         fn ->
           [response, response]
         end},
        id: :dream_time_test_values
      )

    Application.put_env(:memhouse, :dream_time_test_values, values)

    assert {:ok, %{status: :completed, items: 1}} =
             DreamTime.run_scope(first.account.id, first.scope.id)

    assert_receive {:dream_reasoner_input, :reasoning, first_messages}, 5_000

    assert %{
             "peer_keys" => ["avery"],
             "scope_path" => "/dream"
           } = allowed_subject_refs(first_messages)

    DataLayer.with_account_id(
      first.account.id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        first.knowledge
        |> Engine.transition!(
          actor,
          %{state: "needs_revalidation", verification: "test_replay"},
          reason: "dream_time_test_replay_input",
          channel: "pipeline"
        )
        |> Engine.transition!(
          actor,
          %{state: "active", verification: "test_replay"},
          reason: "dream_time_test_reactivate_replay_input",
          channel: "pipeline"
        )
      end
    )

    Application.put_env(:memhouse, :dream_time_pause_reasoning?, true)

    {dream, reasoning_pid, messages} =
      start_paused_dream(first.account.id, first.scope.id)

    assert %{
             "peer_keys" => ["avery"],
             "scope_path" => "/dream"
           } = allowed_subject_refs(messages)

    DataLayer.with_account_id(
      first.account.id,
      [role: :system, pipeline?: true],
      fn _account, actor -> create_peer!(first.account.id, actor, "avery", "agent") end
    )

    baseline = effect_snapshot(first.account.id, first.scope.id)
    send(reasoning_pid, :release_dream_reasoning)

    result = Task.await(dream, 10_000)
    assert effect_snapshot(first.account.id, first.scope.id) == baseline

    assert {:raised, %ArgumentError{message: "reasoner referenced an unknown peer"}} =
             result
  end

  test "scope deductions are reachable through trusted dream-time context" do
    configure_legacy_reasoning!(notify?: true)

    seeded = seed_active_scope_records!("dream-time-scope-deduction")

    values =
      start_supervised!(
        {Agent,
         fn ->
           [
             %{
               "items" => [
                 deduction(seeded.first.id, seeded.second.id, %{
                   "statement" => "The dream scope has a weekly release process.",
                   "kind" => "fact",
                   "subject_type" => "scope",
                   "subject_ref" => seeded.scope.path,
                   "target_level" => "scope"
                 })
               ],
               "relations" => []
             }
           ]
         end},
        id: :dream_time_test_values
      )

    Application.put_env(:memhouse, :dream_time_test_values, values)

    assert {:ok, %{status: :completed, items: 1}} =
             DreamTime.run_scope(seeded.account.id, seeded.scope.id)

    assert_receive {:dream_reasoner_input, :reasoning, messages}

    assert %{
             "peer_keys" => [],
             "scope_path" => "/dream"
           } = allowed_subject_refs(messages)

    DataLayer.with_account_id(
      seeded.account.id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        deduction =
          KnowledgeItem
          |> Ash.Query.filter(scope_id == ^seeded.scope.id and not is_nil(deduction_key))
          |> Ash.Query.set_tenant(seeded.account.id)
          |> Ash.read_one!(actor: actor)

        assert deduction.subject_scope_id == seeded.scope.id
        assert is_nil(deduction.subject_peer_id)
      end
    )
  end

  test "account agent names are rejected from dream-time deduction prose" do
    configure_legacy_reasoning!()

    seeded = seed_active_scope_records!("dream-time-agent-subject")

    create_peer!(seeded.account.id, seeded.actor, "relay-agent", "agent")

    invalid =
      deduction(seeded.first.id, seeded.second.id, %{
        "statement" => "relay-agent owns the weekly release process.",
        "kind" => "fact",
        "subject_type" => "scope",
        "subject_ref" => seeded.scope.path,
        "target_level" => "scope"
      })

    values =
      start_supervised!(
        {Agent,
         fn ->
           List.duplicate(%{"items" => [invalid], "relations" => []}, 3)
         end},
        id: :dream_time_test_values
      )

    Application.put_env(:memhouse, :dream_time_test_values, values)
    baseline = effect_snapshot(seeded.account.id, seeded.scope.id)

    assert {:error,
            {:structured_validation_failed,
             ["items[0].statement must be about a person, not about the relaying agent"]}} =
             DreamTime.run_scope(seeded.account.id, seeded.scope.id)

    assert effect_snapshot(seeded.account.id, seeded.scope.id) == baseline
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

  defp configure_legacy_reasoning!(opts \\ []) do
    provider = Application.get_env(:memhouse, :model_provider)
    operations = Application.fetch_env!(:memhouse, :dream_reasoning_operations)
    gates = Application.fetch_env!(:memhouse, :dream_time_gates)
    clock = start_supervised!({Agent, fn -> 100 end}, id: :dream_time_test_clock)

    Application.put_env(:memhouse, :model_provider, Provider)
    Application.put_env(:memhouse, :dream_time_test_clock, clock)

    if opts[:notify?], do: Application.put_env(:memhouse, :dream_time_test_pid, self())

    if opts[:pause?],
      do: Application.put_env(:memhouse, :dream_time_pause_reasoning?, true)

    Application.put_env(
      :memhouse,
      :dream_reasoning_operations,
      Keyword.put(operations, :split_enabled, false)
    )

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
      Application.delete_env(:memhouse, :dream_time_test_clock)
      Application.delete_env(:memhouse, :dream_time_test_pid)
      Application.delete_env(:memhouse, :dream_time_test_values)
      Application.delete_env(:memhouse, :dream_time_pause_reasoning?)
      Application.put_env(:memhouse, :dream_reasoning_operations, operations)
      Application.put_env(:memhouse, :dream_time_gates, gates)
    end)
  end

  defp start_paused_dream(account_id, scope_id) do
    dream =
      Task.async(fn ->
        receive do
          :start ->
            try do
              DreamTime.run_scope(account_id, scope_id)
            rescue
              error -> {:raised, error}
            end
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(MemHouse.Repo, self(), dream.pid)
    send(dream.pid, :start)

    assert_receive {:dream_reasoning_paused, reasoning_pid}, 5_000
    assert_receive {:dream_reasoner_input, :reasoning, messages}, 5_000

    {dream, reasoning_pid, messages}
  end

  defp allowed_subject_refs(messages) do
    messages
    |> Enum.find(&(&1.role == "user"))
    |> Map.fetch!(:content)
    |> Jason.decode!()
    |> Map.fetch!("allowed_subject_refs")
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

  defp seed_active_scope_records!(account_key) do
    %{actor: actor} =
      Identity.bootstrap_human(%{
        email: "#{account_key}@example.test",
        name: "Dream Scope",
        password: "correct horse battery staple"
      })

    DataLayer.with_actor(actor, fn account, current_actor ->
      pipeline = %{current_actor | role: :system, pipeline?: true, scope_ids: :all}

      scope =
        Scope
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:ensure, %{
          key: "dream",
          name: "Dream",
          path: "/dream",
          state: "active"
        })
        |> Ash.create!(actor: current_actor)

      first =
        scope_knowledge!(account.id, scope.id, "The scope owns a release checklist.", pipeline)

      second =
        scope_knowledge!(account.id, scope.id, "The scope reviews a release checklist.", pipeline)

      %{account: account, actor: pipeline, scope: scope, first: first, second: second}
    end)
  end

  defp create_peer!(account_id, actor, key, kind) do
    Peer
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{key: key, name: key, kind: kind})
    |> Ash.create!(actor: actor)
  end

  defp scope_knowledge!(account_id, scope_id, statement, actor) do
    KnowledgeItem
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create_from_pipeline, %{
      scope_id: scope_id,
      subject_scope_id: scope_id,
      statement: statement,
      kind: "fact",
      confidence: 1.0,
      evidence_level: "direct",
      sensitivity: "internal",
      state: "proposed",
      target_level: "scope",
      verification: "test",
      source_message_ids: [],
      extracting_model: "test",
      pipeline_version: "f5-1"
    })
    |> Ash.create!(actor: actor)
    |> Engine.transition!(
      actor,
      %{state: "active", verification: "test"},
      reason: "dream_time_test_activate_scope_input",
      channel: "pipeline"
    )
  end

  defp deduction(first_id, second_id, overrides \\ %{}) do
    Map.merge(
      %{
        "reasoning" => "Validation-only rationale.",
        "statement" => "Avery prefers weekly release summaries.",
        "kind" => "preference",
        "subject_type" => "peer",
        "subject_ref" => "avery",
        "confidence_level" => "stated_explicitly",
        "sensitivity" => "internal",
        "target_level" => "peer",
        "contributor_ids" => [first_id, second_id]
      },
      overrides
    )
  end

  defp effect_snapshot(account_id, scope_id) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      %{
        deductions: count(KnowledgeItem, account_id, actor, scope_id, [:deduction]),
        provenance: count(Provenance, account_id, actor, scope_id),
        lifecycle: count(LifecycleEvent, account_id, actor, scope_id),
        audit: count(AuditEvent, account_id, actor, scope_id),
        relations: count(KnowledgeRelation, account_id, actor, scope_id),
        reviews: count(ValidationItem, account_id, actor, scope_id),
        derived_jobs: count(PipelineRun, account_id, actor, scope_id, [:derived]),
        watermarks: watermark_cursors(account_id, actor, scope_id)
      }
    end)
  end

  defp watermark_cursors(account_id, actor, scope_id) do
    DreamTimeWatermark
    |> Ash.Query.filter(scope_id == ^scope_id)
    |> Ash.Query.select([:input_watermark, :input_watermark_id])
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(&{&1.input_watermark, &1.input_watermark_id})
  end

  defp count(resource, account_id, actor, scope_id, kind \\ nil) do
    query =
      resource
      |> Ash.Query.filter(scope_id == ^scope_id)
      |> Ash.Query.set_tenant(account_id)

    query =
      case kind do
        [:deduction] -> Ash.Query.filter(query, not is_nil(deduction_key))
        [:derived] -> Ash.Query.filter(query, kind in ["projection_refresh", "entity_resolution"])
        nil -> query
      end

    opts =
      if resource == PipelineRun,
        do: [actor: actor, page: [limit: 1_000]],
        else: [actor: actor]

    case Ash.read!(query, opts) do
      %{results: results} -> length(results)
      results -> length(results)
    end
  end
end
