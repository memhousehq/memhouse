# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.DeductionEffects do
  @moduledoc """
  Creates governed dream-time deductions and maintains their contributor lineage.

  A reasoner response is only a proposal. This module re-reads every contributor
  before it writes, copies its durable source provenance, and lets governance
  decide whether the deduction can become active.
  """

  alias MemHouse.Governance.{Audit, Engine}
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation, Provenance}

  require Ash.Query

  @doc """
  Creates or returns one replay-safe deduction from validated contributor ids.
  """
  def apply!(item, account_id, scope_id, actor) do
    contributors =
      contributors!(
        account_id,
        scope_id,
        item.contributor_ids,
        actor,
        synthesis_item?(item)
      )

    key = key(account_id, scope_id, item, contributors)

    existing =
      KnowledgeItem
      |> Ash.Query.filter(deduction_key == ^key)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    if existing do
      existing
    else
      subject = subject!(item, account_id, scope_id, actor)
      family_key = family_key(account_id, scope_id, item, subject)
      predecessor = active_family_member(account_id, family_key, actor)

      knowledge =
        KnowledgeItem
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.Changeset.for_create(:create_from_pipeline, %{
          scope_id: scope_id,
          subject_peer_id: subject.peer_id,
          subject_scope_id: subject.scope_id,
          statement: item.statement,
          kind: item.kind,
          confidence: item.confidence,
          evidence_level: "indirect",
          sensitivity: item.sensitivity,
          state: "proposed",
          target_level: item.target_level,
          verification: "pending",
          supersedes_id: predecessor && predecessor.id,
          deduction_key: key,
          deduction_family_key: family_key,
          contributor_ids: Enum.map(contributors, & &1.id),
          source_message_ids:
            contributors |> Enum.flat_map(& &1.source_message_ids) |> Enum.uniq(),
          expires_at: item.expires_at,
          revalidate_after: item.revalidate_after,
          relevant_from: item.relevant_from,
          relevant_until: item.relevant_until,
          extracting_provider: item.provider,
          extracting_model: item.model,
          extracting_model_version: item.model_version,
          # Split synthesis has an operation-specific prompt identity. Reuse
          # the existing durable prompt_version field rather than introducing
          # a second provenance column whose values could diverge.
          prompt_version: operation_prompt_version(item),
          pipeline_version: item.pipeline_version
        })
        |> Ash.create!(actor: actor)

      copy_provenance!(knowledge, contributors, actor)
      Engine.evaluate_proposal(knowledge, actor)
    end
  end

  @doc """
  Completes the structural effects when governance activates a deduction.
  """
  def accept!(%{deduction_key: nil}, _actor), do: :ok

  def accept!(knowledge, actor) do
    contributors =
      contributors!(
        knowledge.account_id,
        knowledge.scope_id,
        knowledge.contributor_ids,
        actor,
        synthesis_item?(knowledge)
      )

    Enum.each(contributors, &relation!(knowledge, &1, "derived_from", actor))

    if is_binary(knowledge.supersedes_id) do
      predecessor = knowledge!(knowledge.account_id, knowledge.supersedes_id, actor)

      if predecessor.state == "active" do
        Engine.transition!(
          predecessor,
          actor,
          %{state: "superseded", verification: "reasoning_replaced"},
          reason: "f5_deduction_contributors_changed",
          channel: "pipeline"
        )

        relation!(knowledge, predecessor, "supersedes", actor)
      end
    end

    :ok
  end

  @doc """
  Marks active deductions stale when an accepted contributor no longer remains active.
  """
  def invalidate_contributors!(account_id, contributor_ids, actor) do
    KnowledgeRelation
    |> Ash.Query.filter(target_knowledge_id in ^contributor_ids and kind == "derived_from")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.source_knowledge_id)
    |> Enum.uniq()
    |> Enum.each(fn id ->
      deduction = knowledge!(account_id, id, actor)

      if deduction.state == "active" do
        Engine.transition!(
          deduction,
          actor,
          %{state: "needs_revalidation", verification: "contributor_changed"},
          reason: "f5_deduction_contributor_changed",
          channel: "pipeline"
        )
      end
    end)
  end

  defp contributors!(account_id, scope_id, ids, actor, require_independent_sources?)
       when is_list(ids) and length(ids) >= 2 do
    rows =
      KnowledgeItem
      |> Ash.Query.filter(
        id in ^ids and scope_id == ^scope_id and state == "active" and is_nil(deleted_at)
      )
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    cond do
      length(rows) != length(ids) or length(ids) != length(Enum.uniq(ids)) ->
        raise ArgumentError, "invalid deduction contributors"

      require_independent_sources? and
          independent_source_count(account_id, ids, actor) < 2 ->
        raise ArgumentError, "invalid synthesis contributor sources"

      true ->
        rows
    end
  end

  defp contributors!(_account_id, _scope_id, _ids, _actor, _require_independent_sources?),
    do: raise(ArgumentError, "invalid deduction contributors")

  defp independent_source_count(account_id, ids, actor) do
    Provenance
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(&Provenance.source_observation/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp synthesis_item?(item) do
    Map.get(item, :operation) == "reasoning_synthesis" or
      Map.get(item, :operation_prompt_version) == "reason-synthesis-1" or
      Map.get(item, :prompt_version) == "reason-synthesis-1"
  end

  defp subject!(%{subject_type: "scope"}, _account_id, scope_id, _actor),
    do: %{peer_id: nil, scope_id: scope_id}

  defp subject!(item, account_id, _scope_id, actor) do
    peer =
      MemHouse.Accounts.Peer
      |> Ash.Query.filter(key == ^item.subject_ref)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    if is_nil(peer), do: raise(ArgumentError, "reasoner referenced an unknown peer")
    %{peer_id: peer.id, scope_id: nil}
  end

  defp copy_provenance!(knowledge, contributors, actor) do
    ids = Enum.map(contributors, & &1.id)

    Provenance
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(knowledge.account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn source ->
      Provenance
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        knowledge_item_id: knowledge.id,
        scope_id: knowledge.scope_id,
        source_type: source.source_type,
        message_id: source.message_id,
        document_version_id: source.document_version_id,
        extracting_provider: knowledge.extracting_provider,
        extracting_model: knowledge.extracting_model,
        extracting_model_version: knowledge.extracting_model_version,
        prompt_version: knowledge.prompt_version,
        pipeline_version: knowledge.pipeline_version,
        occurred_at: source.occurred_at
      })
      |> Ash.create!(actor: actor)
    end)
  end

  defp active_family_member(account_id, family_key, actor) do
    KnowledgeItem
    |> Ash.Query.filter(deduction_family_key == ^family_key and state == "active")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read_one!(actor: actor)
  end

  defp operation_prompt_version(item) do
    Map.get(item, :operation_prompt_version) || Map.get(item, :prompt_version)
  end

  defp relation!(source, target, kind, actor) do
    existing =
      KnowledgeRelation
      |> Ash.Query.filter(
        source_knowledge_id == ^source.id and target_knowledge_id == ^target.id and kind == ^kind
      )
      |> Ash.Query.set_tenant(source.account_id)
      |> Ash.read_one!(actor: actor)

    unless existing do
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
        action: "reasoning.deduction_relation_recorded",
        resource_type: "knowledge_relation",
        resource_id: edge.id,
        metadata: %{
          "source_knowledge_id" => source.id,
          "target_knowledge_id" => target.id,
          "kind" => kind
        }
      })
    end
  end

  defp knowledge!(account_id, id, actor) do
    KnowledgeItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: KnowledgeItem
      row -> row
    end
  end

  defp key(account_id, scope_id, item, contributors),
    do:
      digest([
        account_id,
        scope_id,
        item.statement,
        Enum.sort(Enum.map(contributors, & &1.id)),
        item.provider,
        item.model,
        item.model_version,
        operation_prompt_version(item),
        item.pipeline_version
      ])

  defp family_key(account_id, scope_id, item, subject),
    do:
      digest([account_id, scope_id, item.statement, item.kind, subject.peer_id, subject.scope_id])

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
end
