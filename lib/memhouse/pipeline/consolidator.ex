# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Consolidator do
  @moduledoc """
  Consolidates active, same-scope knowledge during dream-time.

  Consolidation never reads raw content outside its Account transaction and never
  changes a claim in place. It merges only exact statements or statements with
  the same subject and compatible embeddings. Set aggregates are derived facts:
  they inherit the active sources' visibility and retain every source id.
  """

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.{Audit, Engine}
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation, LifecycleEvent, Provenance}
  alias MemHouse.Pipeline.Lock
  alias MemHouse.Retrieval.Vector

  require Ash.Query

  @similarity_threshold 0.97

  @doc """
  Consolidates every active scope in an Account.

  Returns counts for merged statements and aggregate statements. Raises on a
  failed durable write so the surrounding dream-time transaction rolls back.
  """
  def run(account_id) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      run_account!(account_id, actor)
    end)
  end

  @doc false
  def run_account!(account_id, actor) do
    scopes =
      KnowledgeItem
      |> Ash.Query.filter(state == "active")
      |> Ash.Query.select([:scope_id])
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.scope_id)
      |> Enum.uniq()

    Enum.reduce(scopes, %{merged: 0, aggregates: 0}, fn scope_id, counts ->
      Map.merge(counts, run_scope!(account_id, scope_id, actor), fn _key, left, right ->
        left + right
      end)
    end)
  end

  @doc """
  Consolidates one scope as a pipeline actor.

  This entry point is used by erasure and import rebuilds after their durable
  source rows change. `actor` must be the current Account pipeline actor.
  """
  def run_scope!(account_id, scope_id, actor) do
    Lock.acquire!(account_id, "knowledge-consolidation:#{scope_id}")
    items = active_items(account_id, scope_id, actor)

    merged =
      items
      |> Enum.reject(&derived_aggregate?/1)
      |> duplicate_groups()
      |> Enum.reduce(0, fn group, count -> merge_group!(group, actor) + count end)

    # Re-read after supersession. Aggregates must be built only from the surviving
    # representatives, otherwise a retired duplicate can become a new member.
    aggregates =
      active_items(account_id, scope_id, actor)
      |> Enum.reject(&derived_aggregate?/1)
      |> set_groups()
      |> Enum.reduce(0, fn group, count -> ensure_aggregate!(group, actor) + count end)

    %{merged: merged, aggregates: aggregates}
  end

  defp active_items(account_id, scope_id, actor) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id == ^scope_id and state == "active" and is_nil(deleted_at))
    |> Ash.Query.ensure_selected([:embedding])
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  # Exact hashes are always safe. Near duplicates additionally require the same
  # subject, kind, visibility fields, and embedding identity before cosine can
  # participate. A missing or incomparable vector never causes a merge.
  defp duplicate_groups(items) do
    items
    |> Enum.group_by(&duplicate_key/1)
    |> Map.values()
    |> Enum.flat_map(&semantic_groups/1)
    |> Enum.filter(&(length(&1) > 1))
  end

  defp duplicate_key(item) do
    {item.subject_peer_id, item.subject_scope_id, item.kind, item.sensitivity, item.target_level,
     item.relevant_from, item.relevant_until}
  end

  defp semantic_groups(items) do
    Enum.reduce(items, [], fn item, groups ->
      case Enum.find_index(groups, fn [representative | _rest] ->
             similar?(representative, item)
           end) do
        nil -> [[item] | groups]
        index -> List.update_at(groups, index, &[item | &1])
      end
    end)
  end

  defp similar?(left, right) when left.statement_hash == right.statement_hash, do: true

  defp similar?(left, right) do
    left.embedding_provider == right.embedding_provider and
      left.embedding_model == right.embedding_model and
      left.embedding_version == right.embedding_version and
      left.embedding_dimensions == right.embedding_dimensions and
      not is_nil(left.embedding) and not is_nil(right.embedding) and
      Vector.cosine(left.embedding, right.embedding) >= @similarity_threshold
  end

  defp merge_group!(group, actor) do
    [target | duplicates] = Enum.sort_by(group, &{-&1.corroboration_count, &1.id})
    sources = independent_sources(group, actor)

    target
    |> Ash.Changeset.for_update(:merge_from_pipeline, %{
      confidence: Enum.max(Enum.map(group, & &1.confidence)),
      source_message_ids: source_message_ids(group),
      corroboration_count: max(1, MapSet.size(sources))
    })
    |> Ash.Changeset.set_tenant(target.account_id)
    |> Ash.update!(actor: actor)

    Enum.each(duplicates, fn duplicate ->
      Engine.transition!(
        duplicate,
        actor,
        %{state: "superseded", supersedes_id: target.id, verification: "dream_time_consolidated"},
        reason: "f5_dream_time_consolidated",
        channel: "dream_time"
      )

      copy_provenance!(duplicate, target, actor)
      relation!(target, duplicate, "supports", actor)
    end)

    length(duplicates)
  end

  # The extractor does not persist predicates. Limit aggregates to the stable,
  # unambiguous sentence shape it emits for set membership rather than guessing
  # from arbitrary prose.
  defp set_groups(items) do
    items
    |> Enum.flat_map(fn item ->
      case membership(item.statement) do
        {:ok, subject, noun, member} -> [{item, subject, noun, member}]
        :error -> []
      end
    end)
    |> Enum.group_by(fn {item, subject, noun, _member} ->
      {item.scope_id, item.subject_peer_id, item.subject_scope_id, item.sensitivity,
       item.target_level, subject, noun}
    end)
    |> Map.values()
    |> Enum.filter(&(length(&1) > 1))
  end

  defp membership(statement) do
    case Regex.run(~r/^(.+?) has (?:a|an) ([[:alpha:]][[:alnum:] _-]*) named (.+)\.$/u, statement) do
      [_, subject, noun, member] -> {:ok, subject, noun, member}
      _other -> :error
    end
  end

  defp ensure_aggregate!(group, actor) do
    [{first, subject, noun, _member} | _rest] = group
    members = group |> Enum.map(&elem(&1, 3)) |> Enum.uniq() |> Enum.sort()
    statement = "#{subject} has #{pluralize(noun)}: #{Enum.join(members, ", ")}."

    existing =
      KnowledgeItem
      |> Ash.Query.filter(
        scope_id == ^first.scope_id and extracting_model == "system:dream-time-consolidator" and
          state == "active"
      )
      |> Ash.Query.set_tenant(first.account_id)
      |> Ash.read!(actor: actor)
      |> Enum.find(&(&1.statement == statement))

    if existing do
      0
    else
      prior_id = retire_prior_aggregate!(first, subject, noun, actor)
      aggregate = create_aggregate!(first, statement, group, prior_id, actor)

      Enum.each(group, fn {item, _, _, _} -> relation!(aggregate, item, "derived_from", actor) end)

      1
    end
  end

  defp retire_prior_aggregate!(first, subject, noun, actor) do
    first.account_id
    |> active_items(first.scope_id, actor)
    |> Enum.filter(fn item ->
      derived_aggregate?(item) and
        String.starts_with?(item.statement, "#{subject} has #{pluralize(noun)}:")
    end)
    |> Enum.map(fn item ->
      Engine.transition!(
        item,
        actor,
        %{state: "superseded", verification: "dream_time_aggregate_rebuilt"},
        reason: "f5_dream_time_aggregate_rebuilt",
        channel: "dream_time"
      )

      item.id
    end)
    |> List.first()
  end

  defp create_aggregate!(first, statement, group, prior_id, actor) do
    aggregate =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(first.account_id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        scope_id: first.scope_id,
        subject_peer_id: first.subject_peer_id,
        subject_scope_id: first.subject_scope_id,
        statement: statement,
        kind: "fact",
        confidence: Enum.max(Enum.map(group, fn {item, _, _, _} -> item.confidence end)),
        sensitivity: first.sensitivity,
        state: "proposed",
        target_level: first.target_level,
        verification: "derived_consolidation",
        supersedes_id: prior_id,
        source_message_ids: source_message_ids(Enum.map(group, &elem(&1, 0))),
        corroboration_count:
          group
          |> Enum.map(&elem(&1, 0))
          |> independent_sources(actor)
          |> MapSet.size()
          |> max(1),
        extracting_model: "system:dream-time-consolidator",
        pipeline_version: "f5-1"
      })
      |> Ash.create!(actor: actor)

    copy_group_provenance!(group, aggregate, actor)

    LifecycleEvent
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(aggregate.account_id)
    |> Ash.Changeset.for_create(:record, %{
      knowledge_item_id: aggregate.id,
      scope_id: aggregate.scope_id,
      to_state: "proposed",
      reason: "f5_dream_time_aggregate_proposed",
      occurred_at: Clock.utc_now()
    })
    |> Ash.create!(actor: actor)

    Audit.append!(actor, aggregate.account_id, %{
      scope_id: aggregate.scope_id,
      category: "lifecycle",
      action: "knowledge.created",
      resource_type: "knowledge_item",
      resource_id: aggregate.id,
      content_hash: aggregate.statement_hash,
      metadata: %{"to_state" => "proposed", "derived" => true}
    })

    Engine.transition!(
      aggregate,
      actor,
      %{state: "active", verification: "derived_consolidation"},
      reason: "f5_dream_time_aggregate_created",
      channel: "dream_time"
    )
  end

  defp copy_group_provenance!(group, aggregate, actor) do
    group
    |> Enum.map(&elem(&1, 0))
    |> Enum.each(&copy_provenance!(&1, aggregate, actor))
  end

  defp copy_provenance!(source, target, actor) do
    source.account_id
    |> provenances_for(source.id, actor)
    |> Enum.each(fn provenance ->
      exists =
        Provenance
        |> Ash.Query.filter(
          knowledge_item_id == ^target.id and source_type == ^provenance.source_type
        )
        |> provenance_filter(provenance)
        |> Ash.Query.set_tenant(target.account_id)
        |> Ash.read_one!(actor: actor)

      unless exists do
        Provenance
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(target.account_id)
        |> Ash.Changeset.for_create(:create_from_pipeline, %{
          knowledge_item_id: target.id,
          scope_id: target.scope_id,
          source_type: provenance.source_type,
          message_id: provenance.message_id,
          document_version_id: provenance.document_version_id,
          extracting_provider: provenance.extracting_provider,
          extracting_model: provenance.extracting_model,
          extracting_model_version: provenance.extracting_model_version,
          prompt_version: provenance.prompt_version,
          embedding_provider: provenance.embedding_provider,
          embedding_model: provenance.embedding_model,
          embedding_version: provenance.embedding_version,
          pipeline_version: provenance.pipeline_version,
          occurred_at: provenance.occurred_at
        })
        |> Ash.create!(actor: actor)
      end
    end)
  end

  defp provenance_filter(query, %{source_type: "message", message_id: id}),
    do: Ash.Query.filter(query, message_id == ^id)

  defp provenance_filter(query, %{source_type: "document", document_version_id: id}),
    do: Ash.Query.filter(query, document_version_id == ^id)

  defp provenances_for(account_id, knowledge_id, actor) do
    Provenance
    |> Ash.Query.filter(knowledge_item_id == ^knowledge_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp independent_sources(items, actor) do
    provenances =
      items
      |> Enum.flat_map(&provenances_for(&1.account_id, &1.id, actor))
      |> MapSet.new(fn provenance ->
        {provenance.source_type, provenance.message_id || provenance.document_version_id}
      end)

    if MapSet.size(provenances) > 0 do
      provenances
    else
      MapSet.new(source_message_ids(items), &{:message, &1})
    end
  end

  defp source_message_ids(items),
    do: items |> Enum.flat_map(& &1.source_message_ids) |> Enum.uniq()

  defp derived_aggregate?(item),
    do: item.extracting_model == "system:dream-time-consolidator"

  defp relation!(source, target, kind, actor) do
    existing =
      KnowledgeRelation
      |> Ash.Query.filter(
        source_knowledge_id == ^source.id and target_knowledge_id == ^target.id and kind == ^kind
      )
      |> Ash.Query.set_tenant(source.account_id)
      |> Ash.read_one!(actor: actor)

    unless existing do
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
    end
  end

  defp pluralize(noun) do
    noun = String.trim(noun)
    if String.ends_with?(noun, "s"), do: noun, else: noun <> "s"
  end
end
