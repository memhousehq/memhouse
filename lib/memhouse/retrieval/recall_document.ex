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

  Ordinary refresh and disaster rebuild use the same complete scope snapshot.
  Upsert and stale-row deletion run in one Account-scoped transaction, so
  replay is deterministic and erasure cannot leave an orphan.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.{KnowledgeItem, Provenance}

  require Ash.Query

  @doc "Rebuilds the complete non-authoritative recall projection for one scope."
  def rebuild_scope(account_id, scope_id), do: project_scope(account_id, scope_id)

  @doc "Refreshes through the same canonical snapshot path as a full rebuild."
  def refresh_scope(account_id, scope_id), do: project_scope(account_id, scope_id)

  defp project_scope(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        items = source_items!(account_id, scope_id, actor)
        provenance_ids = provenance_ids!(account_id, scope_id, actor)

        Enum.each(items, fn item ->
          MemHouse.Retrieval.RecallDocument
          |> Ash.Changeset.new()
          |> Ash.Changeset.set_tenant(account_id)
          |> Ash.Changeset.for_create(
            :upsert_from_pipeline,
            recall_attributes(item, Map.get(provenance_ids, item.id, []))
          )
          |> Ash.create!(actor: actor)
        end)

        source_ids = MapSet.new(items, & &1.id)

        stale =
          MemHouse.Retrieval.RecallDocument
          |> Ash.Query.filter(scope_id == ^scope_id)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)
          |> Enum.reject(&MapSet.member?(source_ids, &1.knowledge_item_id))

        Enum.each(stale, fn document ->
          document
          |> Ash.Changeset.for_destroy(:erase)
          |> Ash.Changeset.set_tenant(account_id)
          |> Ash.destroy!(actor: actor)
        end)

        {:ok, %{projected: length(items), removed: length(stale)}}
      end
    )
  end

  defp source_items!(account_id, scope_id, actor) do
    now = MemHouse.Clock.utc_now()

    KnowledgeItem
    |> Ash.Query.filter(
      scope_id == ^scope_id and state in ["active", "provisional"] and is_nil(deleted_at) and
        (is_nil(expires_at) or expires_at > ^now) and not is_nil(embedding)
    )
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
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp provenance_ids!(account_id, scope_id, actor) do
    Provenance
    |> Ash.Query.filter(scope_id == ^scope_id)
    |> Ash.Query.select([:id, :knowledge_item_id])
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.knowledge_item_id, & &1.id)
  end

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

  defp classification(%{extracting_model: "system:dream-time-consolidator"}),
    do: {"derived", "consolidation"}

  defp classification(_item), do: {"direct", "extraction"}
end
