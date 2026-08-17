# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.SourceIndexer do
  @moduledoc """
  Builds the derived semantic index for immutable source messages.

  Reads and writes happen in short Account-scoped transactions around one
  provider call. A failed call writes nothing, preserving the last usable
  vector; replay overwrites the same message rows and is therefore idempotent.
  Ordinary refresh indexes both missing vectors and vectors whose provider,
  model, model version, or dimensions differ from the Account's current
  embedder. An embedding-identity change therefore converges through the same
  durable projection-refresh and reconciliation path as an interrupted first
  index.
  """

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Model.Config
  alias MemHouse.Model.Embedding
  alias MemHouse.Observations.Message
  alias MemHouse.Retrieval.DiskannLabels

  require Ash.Query

  def rebuild_scope(account_id, scope_id), do: index_scope(account_id, scope_id, false)
  def refresh_scope(account_id, scope_id), do: index_scope(account_id, scope_id, true)

  defp index_scope(account_id, scope_id, missing_only?) do
    label = DiskannLabels.ensure_scope!(account_id, scope_id)
    {messages, actor} = read_messages!(account_id, scope_id, missing_only?)

    case messages do
      [] -> {:ok, %{indexed: 0}}
      messages -> embed_then_write(messages, account_id, scope_id, actor, label)
    end
  end

  defp read_messages!(account_id, scope_id, refresh_only?) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        identity =
          :embedder
          |> Config.resolve(%{account_id: account_id, actor: actor})
          |> Config.embedding_identity()

        query =
          Message |> Ash.Query.filter(scope_id == ^scope_id) |> Ash.Query.select([:id, :content])

        query =
          if refresh_only? do
            Ash.Query.filter(
              query,
              is_nil(embedding) or is_nil(embedding_provider) or
                embedding_provider != ^identity.provider or is_nil(embedding_model) or
                embedding_model != ^identity.model or is_nil(embedding_version) or
                embedding_version != ^identity.version or is_nil(embedding_dimensions) or
                embedding_dimensions != ^identity.dimensions
            )
          else
            query
          end

        messages =
          query
          |> Ash.Query.sort(occurred_at: :asc, id: :asc)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        {messages, actor}
      end
    )
  end

  defp embed_then_write(messages, account_id, scope_id, actor, label) do
    context = %{account_id: account_id, scope_id: scope_id, actor: actor}

    with {:ok, result} <- Embedding.embed(Enum.map(messages, & &1.content), context) do
      indexed_at = Clock.utc_now()

      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          Enum.each(Enum.zip(messages, result.vectors), fn {message, vector} ->
            message
            |> Ash.Changeset.for_update(:index_from_pipeline, %{
              embedding: vector,
              embedding_provider: result.provider,
              embedding_model: result.model,
              embedding_version: result.version,
              embedding_dimensions: result.dimensions,
              diskann_labels: [label],
              source_indexed_at: indexed_at
            })
            |> Ash.Changeset.set_tenant(account_id)
            |> Ash.update!(actor: actor)
          end)
        end
      )

      {:ok, %{indexed: length(messages)}}
    end
  end
end
