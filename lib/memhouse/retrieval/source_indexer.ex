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

  @page_size 100

  @doc """
  Rebuilds every source-message embedding in an Account scope.

  Returns `{:ok, %{indexed: count, embedding_identity: identity}}` after all bounded pages
  commit, including `count: 0` when the scope has no messages. The four-part identity is
  content-free and names the vector space that completed the refresh. Returns the embedder
  error unchanged; pages committed before a later provider failure remain replay-safe.
  Invalid or unauthorized Account/scope identifiers raise through the Account-scoped read.
  """
  def rebuild_scope(account_id, scope_id), do: index_scope(account_id, scope_id, false)

  @doc """
  Embeds source messages that are missing a vector or use a different embedding identity.

  Returns `{:ok, %{indexed: count, embedding_identity: identity}}`, where zero is the
  replay-safe result when the derived index already matches the Account's current provider,
  model, version, and dimensions. Returns the embedder error unchanged; successfully committed
  earlier pages remain valid and the next refresh resumes the remaining stale rows. Invalid or
  unauthorized Account/scope identifiers raise through the Account-scoped read.
  """
  def refresh_scope(account_id, scope_id), do: index_scope(account_id, scope_id, true)

  defp index_scope(account_id, scope_id, missing_only?) do
    label = DiskannLabels.ensure_scope!(account_id, scope_id)
    {actor, identity} = resolve_context!(account_id)

    index_pages(account_id, scope_id, missing_only?, actor, identity, label, nil, 0)
  end

  defp resolve_context!(account_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        identity =
          :embedder
          |> Config.resolve(%{account_id: account_id, actor: actor})
          |> Config.embedding_identity()

        {actor, identity}
      end
    )
  end

  defp index_pages(
         account_id,
         scope_id,
         refresh_only?,
         actor,
         identity,
         label,
         cursor,
         indexed
       ) do
    messages = read_messages!(account_id, scope_id, refresh_only?, identity, cursor)

    case messages do
      [] ->
        {:ok, %{indexed: indexed, embedding_identity: identity}}

      messages ->
        with {:ok, count} <- embed_then_write(messages, account_id, scope_id, actor, label) do
          last = List.last(messages)

          index_pages(
            account_id,
            scope_id,
            refresh_only?,
            actor,
            identity,
            label,
            {last.occurred_at, last.id},
            indexed + count
          )
        end
    end
  end

  defp read_messages!(account_id, scope_id, refresh_only?, identity, cursor) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        query =
          Message
          |> Ash.Query.filter(scope_id == ^scope_id)
          |> Ash.Query.select([:id, :content, :occurred_at])

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

        query =
          case cursor do
            nil ->
              query

            {occurred_at, id} ->
              Ash.Query.filter(
                query,
                occurred_at > ^occurred_at or (occurred_at == ^occurred_at and id > ^id)
              )
          end

        query
        |> Ash.Query.sort(occurred_at: :asc, id: :asc)
        |> Ash.Query.limit(@page_size)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)
      end
    )
  end

  defp embed_then_write(messages, account_id, scope_id, actor, label) do
    context = %{account_id: account_id, scope_id: scope_id, actor: actor}

    with {:ok, result} <- Embedding.embed(Enum.map(messages, & &1.content), context),
         {:ok, pairs} <- pair_messages(messages, result.vectors) do
      indexed_at = Clock.utc_now()

      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          Enum.each(pairs, fn {message, vector} ->
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

      {:ok, length(pairs)}
    end
  end

  defp pair_messages(messages, vectors) when length(messages) == length(vectors),
    do: {:ok, Enum.zip(messages, vectors)}

  defp pair_messages(messages, vectors) do
    {:error,
     {:embedding_cardinality_mismatch, %{expected: length(messages), actual: length(vectors)}}}
  end
end
