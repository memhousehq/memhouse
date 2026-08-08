# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Indexer do
  @moduledoc """
  Rebuilds semantic-search vectors for one scope.

  Vectors are derived caches. Rebuild uses a short read transaction, an embedding call without a
  database connection, then a short write transaction. Never combine these phases. Each vector
  stores provider, model, version, and dimensions so incompatible spaces are never compared.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Model.Embedding
  alias MemHouse.Retrieval.DiskannLabels

  require Ash.Query

  @doc """
  Re-embeds every indexable statement in one scope.

  Covers both approved statements and provisional ones, since a provisional
  statement is retrievable by the peer it is about and needs a vector too;
  soft-deleted statements are skipped so erased content stays out of the index.

  Replay-safe overwrites happen in the final transaction; embedding failure preserves old vectors.

  Returns `{:ok, %{indexed: n}}`, with zero when the scope has nothing to
  index, or the embedding provider's error tuple. Raises if a read or write
  fails.
  """
  def rebuild_scope(account_id, scope_id) do
    label = DiskannLabels.ensure_scope!(account_id, scope_id)
    {items, actor} = read_items!(account_id, scope_id)

    case items do
      # Some providers reject empty batches.
      [] -> {:ok, %{indexed: 0}}
      items -> embed_then_write(items, account_id, scope_id, actor, label)
    end
  end

  # Read active/provisional, non-deleted items and retain the plain actor for external embedding.
  defp read_items!(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        items =
          KnowledgeItem
          |> Ash.Query.filter(
            scope_id == ^scope_id and state in ["active", "provisional"] and is_nil(deleted_at)
          )
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        {items, actor}
      end
    )
  end

  # Providers must preserve batch order; write only after the whole embedding call succeeds.
  defp embed_then_write(items, account_id, scope_id, actor, label) do
    context = %{account_id: account_id, scope_id: scope_id, actor: actor}

    with {:ok, result} <- Embedding.embed(Enum.map(items, & &1.statement), context) do
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          Enum.each(Enum.zip(items, result.vectors), fn {item, embedding} ->
            item
            # Keep derived index writes separate from meaning and lifecycle actions.
            |> Ash.Changeset.for_update(:index_from_pipeline, %{
              embedding: embedding,
              embedding_provider: result.provider,
              embedding_model: result.model,
              embedding_version: result.version,
              embedding_dimensions: result.dimensions,
              diskann_labels: [label]
            })
            |> Ash.Changeset.set_tenant(account_id)
            |> Ash.update!(actor: actor)
          end)
        end
      )

      {:ok, %{indexed: length(items)}}
    end
  end
end
