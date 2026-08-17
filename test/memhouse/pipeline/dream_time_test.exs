# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.DreamTimeTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Identity
  alias MemHouse.Pipeline.DreamTime
  alias MemHouse.Pipeline.DreamTime.Gate
  alias MemHouse.Topology.Scope

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

    assert {:ok, %{scopes: 0, throttled: 0, items: 0, relations: 0}} =
             DreamTime.run(actor.account_id)

    assert {:ok, %{status: :no_delta}} = DreamTime.run_scope(actor.account_id, scope.id)

    assert_receive {:dream_gate, %{eligible_changes: 0}, metadata}
    assert metadata.decision == :skip
    assert metadata.reason == :no_delta
    assert metadata.account_id == actor.account_id
    refute inspect(metadata) =~ "Dream Time Empty"
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
end
