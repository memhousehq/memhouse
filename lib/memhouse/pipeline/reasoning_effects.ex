# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.ReasoningEffects do
  @moduledoc """
  Applies one validated dream-time relation pass as durable governed effects.

  The model schema validates the response shape. This module re-reads both
  endpoints in the Account transaction before it writes, because a response may
  arrive after either statement changed. Contradictions retain both statements
  and create one curator review; they never change lifecycle state by themselves.
  """

  alias MemHouse.Clock
  alias MemHouse.Governance.{Audit, ValidationItem}
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation, Provenance}

  require Ash.Query

  @relation_kinds ~w(supports contradicts derived_from)

  @doc """
  Records every relation in one reasoning pass.

  `input_ids` is the snapshot allowlist. The caller keeps this call inside the
  watermark transaction, so an invalid or stale endpoint rolls back all effects.
  """
  def complete!(account_id, scope_id, input_ids, relations, actor) do
    Enum.count(relations, fn relation ->
      source = endpoint!(account_id, scope_id, input_ids, relation.source_id, actor)
      target = endpoint!(account_id, scope_id, input_ids, relation.target_id, actor)

      if source.id == target.id or relation.kind not in @relation_kinds do
        raise ArgumentError, "invalid reasoning relation"
      end

      case record_relation!(source, target, relation.kind, actor) do
        {:created, edge} ->
          if relation.kind == "contradicts", do: enqueue_conflict!(source, target, edge, actor)
          true

        :existing ->
          # The first pass may have committed the edge before a retry crashed. Re-enqueueing is
          # safe because conflict reviews use a canonical endpoint as their stable identity.
          if relation.kind == "contradicts", do: enqueue_conflict!(source, target, nil, actor)
          false
      end
    end)
  end

  defp endpoint!(account_id, scope_id, input_ids, id, actor) do
    unless id in input_ids,
      do: raise(ArgumentError, "reasoner referenced an input outside its pass")

    KnowledgeItem
    |> Ash.Query.filter(
      id == ^id and scope_id == ^scope_id and state == "active" and is_nil(deleted_at)
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: KnowledgeItem
      item -> item
    end
  end

  defp record_relation!(source, target, kind, actor) do
    existing =
      KnowledgeRelation
      |> Ash.Query.filter(
        source_knowledge_id == ^source.id and target_knowledge_id == ^target.id and kind == ^kind
      )
      |> Ash.Query.set_tenant(source.account_id)
      |> Ash.read_one!(actor: actor)

    if existing do
      :existing
    else
      edge =
        KnowledgeRelation
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(source.account_id)
        |> Ash.Changeset.for_create(:create_from_pipeline, %{
          scope_id: source.scope_id,
          source_knowledge_id: source.id,
          target_knowledge_id: target.id,
          kind: kind,
          confidence: 1.0
        })
        |> Ash.create!(actor: actor)

      Audit.append!(actor, source.account_id, %{
        scope_id: source.scope_id,
        category: "governance",
        action: "reasoning.relation_recorded",
        resource_type: "knowledge_relation",
        resource_id: edge.id,
        metadata: %{
          "source_knowledge_id" => source.id,
          "target_knowledge_id" => target.id,
          "kind" => kind
        }
      })

      {:created, edge}
    end
  end

  defp enqueue_conflict!(source, target, _edge, actor) do
    [anchor, other] = Enum.sort_by([source, target], & &1.id)

    ValidationItem
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(anchor.account_id)
    |> Ash.Changeset.for_create(:enqueue, %{
      knowledge_id: anchor.id,
      scope_id: anchor.scope_id,
      subject_peer_id: anchor.subject_peer_id,
      target_level: anchor.target_level,
      kind: "conflict",
      state: "pending",
      statement_hash: anchor.statement_hash,
      confidence: max(anchor.confidence, other.confidence),
      sensitivity: anchor.sensitivity,
      provenance_ids: provenance_ids([anchor, other], actor),
      conflict_knowledge_ids: [anchor.id, other.id],
      due_at: DateTime.add(Clock.utc_now(), 168, :hour)
    })
    |> Ash.create!(actor: actor)
  end

  defp provenance_ids(items, actor) do
    ids = Enum.map(items, & &1.id)

    Provenance
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(hd(items).account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end
end
