# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.ConsolidatorTest do
  use MemHouseWeb.ConnCase, async: false

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Governance.GateRule
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Pipeline.Consolidator
  alias MemHouse.Topology.Scope

  require Ash.Query

  test "dream-time merges same-subject near duplicates and counts independent sources" do
    %{actor: actor} = bootstrap_human!("consolidation-merge")
    scope = bootstrap_scope!(actor)
    pipeline = pipeline_actor(actor)

    first = active_fact!(scope, actor, "Avery owns the release checklist.", Ecto.UUID.generate())

    second =
      active_fact!(scope, actor, "Avery keeps the release checklist.", Ecto.UUID.generate())

    for item <- [first, second] do
      item
      |> Ash.Changeset.for_update(:index_from_pipeline, %{
        embedding: [1.0, 0.0],
        embedding_provider: "test",
        embedding_model: "test",
        embedding_version: "1",
        embedding_dimensions: 2
      })
      |> Ash.Changeset.set_tenant(actor.account_id)
      |> Ash.update!(actor: pipeline)
    end

    assert %{merged: 1, aggregates: 0} = Consolidator.run(actor.account_id)

    active = active_knowledge!(actor, scope.id)
    assert [survivor] = active
    assert survivor.corroboration_count == 2

    assert Enum.sort(survivor.source_message_ids) ==
             Enum.sort([first.source_message_ids |> hd(), second.source_message_ids |> hd()])

    assert superseded?(actor, second.id) || superseded?(actor, first.id)
  end

  test "dream-time emits one active set aggregate with every source" do
    %{actor: actor} = bootstrap_human!("consolidation-aggregate")
    create_auto_rule!(actor)

    first = ingest!(actor, "aggregate-one", "Melanie has a pet named Bailey.")
    second = ingest!(actor, "aggregate-two", "Melanie has a pet named Luna.")

    assert %{merged: 0, aggregates: 1} = Consolidator.run(actor.account_id)

    aggregate =
      actor
      |> active_knowledge!()
      |> Enum.find(&(&1.extracting_model == "system:dream-time-consolidator"))

    assert aggregate.statement == "Melanie has pets: Bailey, Luna."
    assert aggregate.corroboration_count == 2

    assert Enum.sort(aggregate.source_message_ids) ==
             Enum.sort(first.source_message_ids ++ second.source_message_ids)

    # A replay sees the same derived statement and does not create another one.
    assert %{merged: 0, aggregates: 0} = Consolidator.run(actor.account_id)
  end

  defp bootstrap_human!(suffix) do
    MemHouse.Identity.bootstrap_human(%{
      email: "#{suffix}@example.test",
      name: "Consolidation #{suffix}",
      password: "correct horse battery staple"
    })
  end

  defp bootstrap_scope!(actor) do
    ingest!(actor, "consolidation-bootstrap", "Avery uses the release checklist.")

    DataLayer.with_actor(actor, fn account, _current_actor ->
      Scope
      |> Ash.Query.filter(path == "/poc")
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: %{pipeline_actor(actor) | scope_ids: :all})
    end)
  end

  defp active_fact!(scope, actor, statement, source_message_id) do
    pipeline = pipeline_actor(actor)

    knowledge =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(actor.account_id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        scope_id: scope.id,
        subject_peer_id: actor.peer_id,
        statement: statement,
        kind: "fact",
        confidence: 0.8,
        sensitivity: "internal",
        state: "proposed",
        target_level: "peer",
        source_message_ids: [source_message_id],
        extracting_model: "test:consolidator",
        pipeline_version: "f5-1"
      })
      |> Ash.create!(actor: pipeline)

    Engine.transition!(
      knowledge,
      pipeline,
      %{state: "active", verification: "test"},
      reason: "test_consolidator_active",
      channel: "test"
    )
  end

  defp create_auto_rule!(actor) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      GateRule
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.Changeset.for_create(:create, %{
        target_level: "peer",
        sensitivity: "internal",
        minimum_confidence: 0.5,
        gate_a_mode: "auto_keep",
        gate_b_mode: "auto_place",
        minimum_corroboration: 1,
        revalidate_after_days: 90,
        priority: 10
      })
      |> Ash.create!(actor: current_actor)
    end)
  end

  defp ingest!(actor, session_id, content) do
    {:ok, message} =
      Memory.ingest_message(
        %{
          "session_id" => session_id,
          "scope_path" => "/poc",
          "role" => "user",
          "content" => content
        },
        actor
      )

    {:ok, [knowledge]} = Memory.extract_message_for_account(message["id"], actor.account_id)
    knowledge_for!(actor, knowledge["id"])
  end

  defp active_knowledge!(actor, scope_id \\ nil) do
    DataLayer.with_actor(actor, fn account, _current_actor ->
      query =
        KnowledgeItem
        |> Ash.Query.filter(state == "active")
        |> Ash.Query.set_tenant(account.id)

      query = if scope_id, do: Ash.Query.filter(query, scope_id == ^scope_id), else: query
      Ash.read!(query, actor: pipeline_actor(actor))
    end)
  end

  defp knowledge_for!(actor, id) do
    DataLayer.with_actor(actor, fn account, _current_actor ->
      KnowledgeItem
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: pipeline_actor(actor))
    end)
  end

  defp superseded?(actor, id) do
    knowledge_for!(actor, id).state == "superseded"
  end

  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}
end
