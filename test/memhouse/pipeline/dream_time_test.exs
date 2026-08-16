# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.DreamTimeTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Identity
  alias MemHouse.Pipeline.DreamTime
  alias MemHouse.Topology.Scope

  test "a scope without an active-knowledge delta does not call the reasoner" do
    %{actor: actor} =
      Identity.bootstrap_human(%{
        email: "dream-time-empty@example.test",
        name: "Dream Time Empty",
        password: "correct horse battery staple"
      })

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

    assert {:ok, %{scopes: 0, throttled: 0, items: 0, relations: 0}} =
             DreamTime.run(actor.account_id)
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
