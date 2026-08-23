# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.DreamTimeIdleSchedulerTest do
  @moduledoc """
  Verifies idle wakeups, content-free job payloads, and stale-run supersession.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Identity
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.DreamTime
  alias MemHouse.Pipeline.Reconciler
  alias MemHouse.Repo
  alias MemHouse.Topology.Scope

  require Ash.Query

  setup do
    gates = Application.fetch_env!(:memhouse, :dream_time_gates)

    enabled_gates =
      gates
      |> Keyword.put(:idle_scheduler_enabled, true)
      |> Keyword.put(:idle_seconds, 60)

    Application.put_env(:memhouse, :dream_time_gates, enabled_gates)
    on_exit(fn -> Application.put_env(:memhouse, :dream_time_gates, gates) end)
    {:ok, default_gates: gates}
  end

  test "default-off scheduler creates no scoped run, job, or reasoner call", %{
    default_gates: default_gates
  } do
    refute Keyword.fetch!(default_gates, :idle_scheduler_enabled)
    Application.put_env(:memhouse, :dream_time_gates, default_gates)
    {actor, scope} = bootstrap!("disabled")
    _item = activate_direct!(actor, scope, "Avery keeps the established dream schedule.")

    assert idle_runs(actor, scope.id) == []

    assert %{rows: [[0, 0]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT
                 (SELECT count(*)
                  FROM oban_jobs
                  WHERE args->>'pipeline_kind' = 'dream_time'
                    AND args->>'tenant' = $1),
                 (SELECT count(*)
                  FROM usage_events
                  WHERE account_id = $2 AND model_role = 'dream_reasoner')
               """,
               [actor.account_id, Ecto.UUID.dump!(actor.account_id)]
             )
  end

  test "an active direct change atomically creates a delayed content-free scoped wakeup" do
    {actor, scope} = bootstrap!("durable")
    item = activate_direct!(actor, scope, "Avery prefers release notes with links.")
    [run] = idle_runs(actor, scope.id)

    assert run.target_type == "scope"
    assert run.target_id == scope.id

    assert run.payload == %{
             "mode" => "idle_scope",
             "activity_at" => DateTime.to_iso8601(item.updated_at),
             "activity_id" => item.id
           }

    refute inspect(run.payload) =~ item.statement

    %{rows: [[scheduled_at, args]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT scheduled_at, args FROM oban_jobs WHERE args->>'idempotency_key' = $1",
        [run.idempotency_key]
      )

    expected_at = item.updated_at |> DateTime.add(60, :second) |> DateTime.to_naive()
    assert NaiveDateTime.compare(scheduled_at, expected_at) == :eq

    assert Map.keys(args) |> Enum.sort() == [
             "action_arguments",
             "idempotency_key",
             "metadata",
             "pipeline_kind",
             "primary_key",
             "tenant"
           ]

    assert args["pipeline_kind"] == "dream_time"
    refute inspect(args) =~ item.statement
  end

  test "rolling back governance also rolls back its idle run and job" do
    {actor, scope} = bootstrap!("rollback")
    proposed = proposed_direct!(actor, scope, "This transition must roll back.")

    assert_raise RuntimeError, "force idle rollback", fn ->
      DataLayer.with_actor(actor, fn _account, _current_actor ->
        Engine.transition!(
          proposed,
          pipeline_actor(actor),
          %{state: "active", verification: "test"},
          reason: "test_idle_rollback",
          channel: "test"
        )

        raise "force idle rollback"
      end)
    end

    assert idle_runs(actor, scope.id) == []
    assert reload_knowledge!(actor, proposed.id).state == "proposed"
  end

  test "duplicates converge and newer activity supersedes an older wakeup before model work" do
    {actor, scope} = bootstrap!("supersede")
    first_item = activate_direct!(actor, scope, "Avery prefers concise release notes.")
    [first_run] = idle_runs(actor, scope.id)

    duplicate =
      DataLayer.with_actor(actor, fn account, current_actor ->
        Pipeline.enqueue_idle_dream_time(
          account.id,
          scope.id,
          first_item.updated_at,
          first_item.id,
          current_actor
        )
      end)

    assert {:ok, %{id: duplicate_id}} = duplicate
    assert duplicate_id == first_run.id
    assert job_count(first_run.idempotency_key) == 1

    Process.sleep(2)
    _second_item = activate_direct!(actor, scope, "Avery prefers release notes with owners.")
    [first, second] = idle_runs(actor, scope.id)
    older_run = Enum.find([first, second], &(&1.id == first_run.id))
    newer_run = Enum.find([first, second], &(&1.id != first_run.id))

    assert older_run.id == first_run.id
    assert newer_run.id != older_run.id

    assert {:ok, %{status: :skipped, reason: :superseded_activity}} =
             Pipeline.execute(older_run)
  end

  test "a burst leaves only its latest generation effective" do
    {actor, scope} = bootstrap!("burst")

    for index <- 1..5 do
      Process.sleep(2)
      activate_direct!(actor, scope, "Avery records burst fact #{index}.")
    end

    runs = idle_runs(actor, scope.id)
    assert length(runs) == 5
    {older_runs, [latest_run]} = Enum.split(runs, -1)

    for run <- older_runs do
      assert {:ok, %{status: :skipped, reason: :superseded_activity}} = Pipeline.execute(run)
    end

    assert {:ok, %{status: :skipped, reason: :idle_time}} = Pipeline.execute(latest_run)
  end

  test "a scheduled run executes only its scope and malformed generations fail closed" do
    {actor, first_scope} = bootstrap!("scoped")
    second_scope = create_scope!(actor, "other")
    _first = activate_direct!(actor, first_scope, "Avery uses the first checklist.")
    _second = activate_direct!(actor, second_scope, "Avery uses the second checklist.")
    [first_run] = idle_runs(actor, first_scope.id)

    handler = {__MODULE__, self()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :pipeline, :dream_gate],
        fn _event, _measurements, metadata, _config -> send(parent, {:gate, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %{status: :skipped, reason: :idle_time}} = Pipeline.execute(first_run)
    assert_receive {:gate, %{scope_id: scope_id}}
    assert scope_id == first_scope.id
    second_scope_id = second_scope.id
    refute_receive {:gate, %{scope_id: ^second_scope_id}}

    assert {:ok, %{status: :skipped, reason: :invalid_schedule}} =
             DreamTime.run_scheduled_scope(actor.account_id, first_scope.id, "hostile", "payload")

    malformed = %{first_run | target_id: second_scope.id}

    assert {:ok, %{status: "rejected", reason_class: "invalid_dream_target"}} =
             Pipeline.execute(malformed)
  end

  test "reconciliation recreates a missing idle job with the original replay identity" do
    {actor, scope} = bootstrap!("restart")
    _item = activate_direct!(actor, scope, "Avery restarts the durable scheduler.")
    [run] = idle_runs(actor, scope.id)

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM oban_jobs WHERE args->>'idempotency_key' = $1",
      [run.idempotency_key]
    )

    backdate_run!(run.id)
    assert {:ok, %{terminated: 1}} = Reconciler.run(actor.account_id)
    backdate_run!(run.id)
    assert {:ok, %{replayed: 1}} = Reconciler.run(actor.account_id)

    assert [replayed] = idle_runs(actor, scope.id)
    assert replayed.id == run.id
    assert job_count(run.idempotency_key) == 1
  end

  defp bootstrap!(suffix) do
    %{actor: actor} =
      Identity.bootstrap_human(%{
        email: "dream-idle-#{suffix}@example.test",
        name: "Dream Idle #{suffix}",
        password: "correct horse battery staple"
      })

    {actor, create_scope!(actor, "main")}
  end

  defp create_scope!(actor, key) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      Scope
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.Changeset.for_create(:ensure, %{
        key: "dream-idle-#{key}",
        name: "Dream idle #{key}",
        path: "/dream-idle/#{key}",
        state: "active"
      })
      |> Ash.create!(actor: current_actor)
    end)
  end

  defp activate_direct!(actor, scope, statement) do
    proposed = proposed_direct!(actor, scope, statement)

    DataLayer.with_actor(actor, fn _account, _current_actor ->
      Engine.transition!(
        proposed,
        pipeline_actor(actor),
        %{state: "active", verification: "test"},
        reason: "test_idle_schedule",
        channel: "test"
      )
    end)
  end

  defp proposed_direct!(actor, scope, statement) do
    DataLayer.with_actor(actor, fn account, _current_actor ->
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        scope_id: scope.id,
        subject_peer_id: actor.peer_id,
        statement: statement,
        kind: "fact",
        confidence: 0.9,
        sensitivity: "internal",
        state: "proposed",
        target_level: "peer",
        source_message_ids: [Ash.UUID.generate()],
        extracting_model: "test:idle-scheduler",
        pipeline_version: "test-1"
      })
      |> Ash.create!(actor: pipeline_actor(actor))
    end)
  end

  defp reload_knowledge!(actor, id) do
    DataLayer.with_actor(actor, fn account, _current_actor ->
      KnowledgeItem
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: pipeline_actor(actor))
    end)
  end

  defp idle_runs(actor, scope_id) do
    DataLayer.with_actor(actor, fn account, _current_actor ->
      PipelineRun
      |> Ash.Query.filter(
        kind == "dream_time" and scope_id == ^scope_id and target_type == "scope"
      )
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: pipeline_actor(actor), page: [limit: 100])
      |> Map.fetch!(:results)
    end)
  end

  defp job_count(key) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM oban_jobs WHERE args->>'idempotency_key' = $1",
        [key]
      )

    count
  end

  defp backdate_run!(run_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE pipeline_runs SET updated_at = now() - interval '6 minutes' WHERE id = $1",
      [Ecto.UUID.dump!(run_id)]
    )
  end

  defp pipeline_actor(actor), do: %{actor | role: :system, pipeline?: true, scope_ids: :all}
end
