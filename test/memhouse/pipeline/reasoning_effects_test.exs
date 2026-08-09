# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.ReasoningEffectsTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Governance.ValidationItem
  alias MemHouse.Identity
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation}
  alias MemHouse.Pipeline.ReasoningEffects
  alias MemHouse.Topology.Scope

  require Ash.Query

  test "a contradiction creates one edge and one replay-safe bundled review" do
    %{actor: actor} =
      Identity.bootstrap_human(%{
        email: "reasoning-effects@example.test",
        name: "Reasoning Effects",
        password: "correct horse battery staple"
      })

    DataLayer.with_actor(actor, fn account, current_actor ->
      pipeline = %{current_actor | role: :system, pipeline?: true, scope_ids: :all}
      scope = scope!(account.id, current_actor)
      first = knowledge!(account.id, scope.id, "Avery works from Helsinki.", pipeline)
      second = knowledge!(account.id, scope.id, "Avery works from Tampere.", pipeline)
      relation = %{source_id: first.id, target_id: second.id, kind: "contradicts"}

      assert 1 ==
               ReasoningEffects.complete!(
                 account.id,
                 scope.id,
                 [first.id, second.id],
                 [relation],
                 pipeline
               )

      assert 0 ==
               ReasoningEffects.complete!(
                 account.id,
                 scope.id,
                 [first.id, second.id],
                 [relation],
                 pipeline
               )

      relations =
        KnowledgeRelation
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: pipeline)

      reviews =
        ValidationItem
        |> Ash.Query.filter(kind == "conflict")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: pipeline)

      assert [%{kind: "contradicts"}] = relations
      assert [%{conflict_knowledge_ids: ids, provenance_ids: []}] = reviews
      assert MapSet.new(ids) == MapSet.new([first.id, second.id])
    end)
  end

  test "a relation endpoint outside the reasoning pass has no durable effect" do
    %{actor: actor} =
      Identity.bootstrap_human(%{
        email: "reasoning-effects-invalid@example.test",
        name: "Reasoning Effects Invalid",
        password: "correct horse battery staple"
      })

    DataLayer.with_actor(actor, fn account, current_actor ->
      pipeline = %{current_actor | role: :system, pipeline?: true, scope_ids: :all}
      scope = scope!(account.id, current_actor)
      first = knowledge!(account.id, scope.id, "Avery owns the deployment checklist.", pipeline)
      second = knowledge!(account.id, scope.id, "Avery owns the incident checklist.", pipeline)

      assert_raise ArgumentError, fn ->
        ReasoningEffects.complete!(
          account.id,
          scope.id,
          [first.id],
          [%{source_id: first.id, target_id: second.id, kind: "supports"}],
          pipeline
        )
      end

      assert [] =
               KnowledgeRelation
               |> Ash.Query.set_tenant(account.id)
               |> Ash.read!(actor: pipeline)
    end)
  end

  defp scope!(account_id, actor) do
    Scope
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{
      key: "reasoning-effects",
      name: "Reasoning effects",
      path: "/reasoning-effects",
      state: "active"
    })
    |> Ash.create!(actor: actor)
  end

  defp knowledge!(account_id, scope_id, statement, actor) do
    knowledge =
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

    knowledge
    |> Ash.Changeset.for_update(:transition, %{
      state: "active",
      verification: "test",
      reason: "test",
      channel: "test"
    })
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.update!(actor: actor)
  end
end
