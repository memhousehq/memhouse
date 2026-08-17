# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.RecallDocumentTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Retrieval.{DiskannLabels, Query, RecallDocument, RecallProjector, Store}
  alias MemHouse.Topology.Scope

  require Ash.Query

  @identity %{provider: "fixture", model: "recall", version: "1", dimensions: 3}

  test "projection replay classifies lanes and canonical lifecycle invalidates before refresh" do
    %{account: account, actor: actor} = bootstrap!("projection")
    scope = root_scope!(account.id, actor)
    pipeline = pipeline_actor(actor)

    direct = active_item!(scope, actor, "direct release note", [1.0, 0.0, 0.0])

    derived =
      active_item!(scope, actor, "derived release inference", [0.8, 0.2, 0.0],
        extracting_model: "system:dream-time-consolidator"
      )

    assert {:ok, %{projected: 2, removed: 0}} =
             RecallProjector.rebuild_scope(account.id, scope.id)

    assert {:ok, %{projected: 2, removed: 0}} =
             RecallProjector.rebuild_scope(account.id, scope.id)

    documents = projected!(account.id, pipeline)

    assert MapSet.new(
             Enum.map(documents, &{&1.knowledge_item_id, &1.derivation_lane, &1.operation})
           ) ==
             MapSet.new([
               {derived.id, "derived", "consolidation"},
               {direct.id, "direct", "extraction"}
             ])

    before = search(account.id, actor, [scope.id], 5, 5, 10)
    assert MapSet.new(Enum.map(before, & &1["id"])) == MapSet.new([direct.id, derived.id])

    # Lifecycle is canonical. The stale projection cannot keep the retracted
    # row readable during the delay before the refresh job runs.
    Engine.transition!(direct, pipeline, %{state: "retracted"},
      reason: "recall_projection_test",
      channel: "test"
    )

    assert Enum.map(search(account.id, actor, [scope.id], 5, 5, 10), & &1["id"]) == [
             derived.id
           ]

    assert {:ok, %{projected: 1, removed: 1}} =
             RecallProjector.refresh_scope(account.id, scope.id)

    assert Enum.map(projected!(account.id, pipeline), & &1.knowledge_item_id) == [derived.id]

    derived
    |> Ash.Changeset.for_destroy(:erase)
    |> Ash.Changeset.set_tenant(account.id)
    |> Ash.destroy!(actor: pipeline)

    # The FK is an immediate erasure fence; replay remains a no-op cleanup.
    assert projected!(account.id, pipeline) == []

    assert {:ok, %{projected: 0, removed: 0}} =
             RecallProjector.rebuild_scope(account.id, scope.id)
  end

  test "authorized set matches canonical semantic and lane caps interleave deterministically" do
    %{account: account, actor: actor} = bootstrap!("differential")
    root = root_scope!(account.id, actor)
    hidden = child_scope!(account.id, root, actor)

    direct_one = active_item!(root, actor, "direct one", [1.0, 0.0, 0.0])
    direct_two = active_item!(root, actor, "direct two", [0.99, 0.01, 0.0])
    _direct_three = active_item!(root, actor, "direct three", [0.98, 0.02, 0.0])

    derived =
      active_item!(root, actor, "derived lane", [0.7, 0.3, 0.0],
        extracting_model: "system:dream-time-consolidator"
      )

    hidden_item = active_item!(hidden, actor, "hidden scope", [1.0, 0.0, 0.0])

    assert {:ok, _} = RecallProjector.rebuild_scope(account.id, root.id)
    assert {:ok, _} = RecallProjector.rebuild_scope(account.id, hidden.id)

    canonical = canonical_search(account.id, actor, [root.id], 20)
    projected = search(account.id, actor, [root.id], 20, 20, 20)

    assert MapSet.new(Enum.map(projected, & &1["id"])) ==
             MapSet.new(Enum.map(canonical, & &1["id"]))

    refute hidden_item.id in Enum.map(projected, & &1["id"])

    # Derived lane rank 1 survives even though three direct vectors are closer.
    bounded = search(account.id, actor, [root.id], 2, 1, 3)

    assert Enum.map(bounded, &{&1["recall_lane"], &1["lane_rank"]}) == [
             {"direct", 1},
             {"derived", 1},
             {"direct", 2}
           ]

    assert Enum.map(bounded, & &1["id"]) == [direct_one.id, derived.id, direct_two.id]
    assert Enum.all?(bounded, &is_float(&1["semantic_distance"]))

    # A different Account cannot use its tenant setting to read these rows.
    unique = System.unique_integer([:positive])

    assert DataLayer.with_account_key(
             "recall-other-#{unique}",
             [role: :system, pipeline?: true],
             fn other, other_actor ->
               RecallDocument
               |> Ash.Query.set_tenant(other.id)
               |> Ash.read!(actor: other_actor)
             end
           ) == []
  end

  defp search(account_id, actor, scope_ids, direct_limit, derived_limit, limit) do
    query = %Query{
      account_id: account_id,
      actor: actor,
      scope_ids: scope_ids,
      text: "release",
      target: :knowledge,
      source_filters: %{}
    }

    DataLayer.with_actor(actor, fn _account, _actor ->
      Store.semantic_dual_lane(
        query,
        [1.0, 0.0, 0.0],
        @identity,
        direct_limit,
        derived_limit,
        limit
      )
    end)
  end

  defp canonical_search(account_id, actor, scope_ids, limit) do
    query = %Query{
      account_id: account_id,
      actor: actor,
      scope_ids: scope_ids,
      text: "release",
      target: :knowledge,
      source_filters: %{}
    }

    DataLayer.with_actor(actor, fn _account, _actor ->
      Store.semantic(query, [1.0, 0.0, 0.0], @identity, limit)
    end)
  end

  defp projected!(account_id, actor) do
    RecallDocument
    |> Ash.Query.sort(knowledge_item_id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp active_item!(scope, actor, statement, embedding, opts \\ []) do
    pipeline = pipeline_actor(actor)
    label = DiskannLabels.ensure_scope!(actor.account_id, scope.id)

    item =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(actor.account_id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        scope_id: scope.id,
        subject_peer_id: actor.peer_id,
        statement: statement,
        kind: "fact",
        confidence: 0.9,
        evidence_level: "direct",
        sensitivity: "internal",
        state: "proposed",
        target_level: "peer",
        extracting_model: Keyword.get(opts, :extracting_model, "fixture:extractor"),
        pipeline_version: "f7-1"
      })
      |> Ash.create!(actor: pipeline)
      |> then(
        &Engine.transition!(&1, pipeline, %{state: "active", verification: "test"},
          reason: "recall_projection_test",
          channel: "test"
        )
      )

    item
    |> Ash.Changeset.for_update(:index_from_pipeline, %{
      embedding: embedding,
      embedding_provider: @identity.provider,
      embedding_model: @identity.model,
      embedding_version: @identity.version,
      embedding_dimensions: @identity.dimensions,
      diskann_labels: [label]
    })
    |> Ash.Changeset.set_tenant(actor.account_id)
    |> Ash.update!(actor: pipeline)
  end

  defp child_scope!(account_id, parent, actor) do
    Scope
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{
      parent_id: parent.id,
      key: "hidden",
      name: "Hidden",
      path: "/hidden",
      state: "active"
    })
    |> Ash.create!(actor: actor)
  end

  defp root_scope!(account_id, actor) do
    Scope
    |> Ash.Query.filter(path == "/")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp bootstrap!(suffix) do
    MemHouse.Identity.bootstrap_human(%{
      email: "recall-#{suffix}@example.test",
      name: "Recall #{suffix}",
      password: "correct horse battery staple"
    })
  end

  defp pipeline_actor(actor), do: %{actor | role: :system, scope_ids: :all, pipeline?: true}
end
