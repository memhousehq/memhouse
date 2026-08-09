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
end
