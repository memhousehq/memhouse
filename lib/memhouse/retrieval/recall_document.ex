# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.RecallDocument do
  @moduledoc """
  Rebuildable semantic read model for one governed statement.

  A recall document is not another knowledge write path. Its source is the
  canonical `KnowledgeItem`, its vector is copied only after indexing, and it
  is excluded from portability. Retrieval joins the source row and requires
  the recorded watermark to equal the source's current `updated_at` before
  ranking. A lifecycle or content change therefore invalidates a stale row
  immediately, even if projection refresh is delayed.

  `derivation_lane` separates observed (`direct`) memory from dream-time or
  deductive (`derived`) memory. It does not describe evidence strength and
  must not be confused with `KnowledgeItem.evidence_level`.
  """

  use MemHouse.Resource,
    domain: MemHouse.Retrieval,
    table: "recall_documents"

  postgres do
    migration_types diskann_labels: {:array, :smallint}
  end

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :upsert_from_pipeline do
      accept [
        :knowledge_item_id,
        :scope_id,
        :subject_peer_id,
        :subject_scope_id,
        :statement,
        :derivation_lane,
        :operation,
        :provenance_ids,
        :embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :diskann_labels,
        :source_updated_at
      ]

      upsert? true
      upsert_identity :knowledge_item

      upsert_fields [
        :scope_id,
        :subject_peer_id,
        :subject_scope_id,
        :statement,
        :derivation_lane,
        :operation,
        :provenance_ids,
        :embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :diskann_labels,
        :source_updated_at,
        :updated_at
      ]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action([:upsert_from_pipeline, :erase]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :subject_peer_id, :uuid
    attribute :subject_scope_id, :uuid
    attribute :statement, :string, allow_nil?: false
    attribute :derivation_lane, :string, allow_nil?: false, public?: true
    attribute :operation, :string, allow_nil?: false, public?: true
    attribute :provenance_ids, {:array, :uuid}, allow_nil?: false, default: []
    attribute :embedding, :vector, select_by_default?: false
    attribute :embedding_provider, :string
    attribute :embedding_model, :string
    attribute :embedding_version, :string
    attribute :embedding_dimensions, :integer
    attribute :diskann_labels, {:array, :integer}, allow_nil?: false, default: []
    attribute :source_updated_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :knowledge_item, [:knowledge_item_id]
  end
end

defmodule MemHouse.Retrieval.RecallProjector do
  @moduledoc """
  Materializes `RecallDocument` from canonical Knowledge and Provenance rows.

  Ordinary refresh and disaster rebuild use the same canonical scope scan.
  Upserts commit in bounded Account-scoped pages and stale rows are removed
  only after every source page succeeds. Canonical lifecycle and watermark
  checks keep a partially refreshed projection unreadable until replay converges.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.{KnowledgeItem, Provenance}
  alias MemHouse.Pipeline.Consolidator

  @consolidator_marker Consolidator.marker()

  require Ash.Query

  @projection_batch_size 100

  @doc "Rebuilds the complete non-authoritative recall projection for one scope."
  def rebuild_scope(account_id, scope_id), do: project_scope(account_id, scope_id)

  @doc "Refreshes through the same canonical snapshot path as a full rebuild."
  def refresh_scope(account_id, scope_id), do: project_scope(account_id, scope_id)

  defp project_scope(account_id, scope_id) do
    {projected, source_ids} = upsert_source_pages(account_id, scope_id, nil, 0, [])
    removed = remove_stale!(account_id, scope_id, source_ids)

    {:ok, %{projected: projected, removed: removed}}
  end

  defp upsert_source_pages(account_id, scope_id, cursor, count, source_ids) do
    items = upsert_source_page!(account_id, scope_id, cursor)

    case items do
      [] ->
        {count, source_ids}

      items ->
        item_ids = Enum.map(items, & &1.id)

        upsert_source_pages(
          account_id,
          scope_id,
          List.last(items) |> then(&{&1.updated_at, &1.id}),
          count + length(items),
          Enum.reverse(item_ids, source_ids)
        )
    end
  end

  defp upsert_source_page!(account_id, scope_id, cursor) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        items = source_items!(account_id, scope_id, cursor, actor)

        if items != [] do
          item_ids = Enum.map(items, & &1.id)
          provenance_ids = provenance_ids!(account_id, scope_id, item_ids, actor)

          attributes =
            Enum.map(items, fn item ->
              recall_attributes(item, Map.get(provenance_ids, item.id, []))
            end)

          Ash.bulk_create!(
            attributes,
            MemHouse.Retrieval.RecallDocument,
            :upsert_from_pipeline,
            actor: actor,
            tenant: account_id,
            domain: MemHouse.Retrieval,
            batch_size: @projection_batch_size,
            stop_on_error?: true,
            return_errors?: true
          )
        end

        items
      end
    )
  end

  defp source_items!(account_id, scope_id, cursor, actor) do
    now = MemHouse.Clock.utc_now()

    query =
      KnowledgeItem
      |> Ash.Query.filter(
        scope_id == ^scope_id and state in ["active", "provisional"] and is_nil(deleted_at) and
          (is_nil(expires_at) or expires_at > ^now) and not is_nil(embedding)
      )
      |> maybe_after_cursor(cursor)
      |> Ash.Query.select([
        :id,
        :scope_id,
        :subject_peer_id,
        :subject_scope_id,
        :statement,
        :deduction_key,
        :extracting_model,
        :embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :diskann_labels,
        :updated_at
      ])
      |> Ash.Query.sort(updated_at: :asc, id: :asc)
      |> Ash.Query.limit(@projection_batch_size)
      |> Ash.Query.set_tenant(account_id)

    Ash.read!(query, actor: actor)
  end

  defp maybe_after_cursor(query, nil), do: query

  defp maybe_after_cursor(query, {updated_at, id}) do
    Ash.Query.filter(
      query,
      updated_at > ^updated_at or (updated_at == ^updated_at and id > ^id)
    )
  end

  defp provenance_ids!(account_id, scope_id, item_ids, actor) do
    Provenance
    |> Ash.Query.filter(scope_id == ^scope_id and knowledge_item_id in ^item_ids)
    |> Ash.Query.select([:id, :knowledge_item_id])
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.knowledge_item_id, & &1.id)
  end

  defp remove_stale!(account_id, scope_id, source_ids) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        query =
          MemHouse.Retrieval.RecallDocument
          |> Ash.Query.filter(scope_id == ^scope_id)
          |> maybe_exclude_source_ids(source_ids)
          |> Ash.Query.set_tenant(account_id)

        removed = Ash.count!(query, actor: actor)

        Ash.bulk_destroy!(query, :erase, %{},
          actor: actor,
          tenant: account_id,
          domain: MemHouse.Retrieval,
          strategy: [:atomic, :stream],
          stop_on_error?: true,
          return_errors?: true
        )

        removed
      end
    )
  end

  defp maybe_exclude_source_ids(query, []), do: query

  defp maybe_exclude_source_ids(query, source_ids),
    do: Ash.Query.filter(query, knowledge_item_id not in ^source_ids)

  defp recall_attributes(item, provenance_ids) do
    {lane, operation} = classification(item)

    %{
      knowledge_item_id: item.id,
      scope_id: item.scope_id,
      subject_peer_id: item.subject_peer_id,
      subject_scope_id: item.subject_scope_id,
      statement: item.statement,
      derivation_lane: lane,
      operation: operation,
      provenance_ids: provenance_ids,
      embedding: item.embedding,
      embedding_provider: item.embedding_provider,
      embedding_model: item.embedding_model,
      embedding_version: item.embedding_version,
      embedding_dimensions: item.embedding_dimensions,
      diskann_labels: item.diskann_labels,
      source_updated_at: item.updated_at
    }
  end

  defp classification(%{deduction_key: key}) when is_binary(key), do: {"derived", "deduction"}

  defp classification(%{extracting_model: @consolidator_marker}),
    do: {"derived", "consolidation"}

  defp classification(_item), do: {"direct", "extraction"}
end
