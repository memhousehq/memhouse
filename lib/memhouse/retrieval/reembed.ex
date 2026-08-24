# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Reembed do
  @moduledoc """
  Resumes the Account-wide transition to the configured embedding identity.

  Knowledge, active document chunks, and scope entity caches run in separate
  phases. Each batch commits its vector writes before the durable cursor moves.
  A failed job therefore repeats at most one idempotent batch.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Documents.DocumentChunk
  alias MemHouse.Knowledge.{KnowledgeItem, Lifecycle}
  alias MemHouse.Model.Config
  alias MemHouse.Model.Embedding
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Retrieval.DiskannLabels
  alias MemHouse.Topology.Scope

  require Ash.Query
  require Ash.Expr

  @batch_size 50

  @doc """
  Runs or resumes a re-embed pipeline row until every phase completes.

  Returns the final content-free progress map, or the embedding provider error.
  """
  def run(%PipelineRun{} = run) do
    with :ok <- ensure_target_identity(run) do
      case run.payload["phase"] || "knowledge" do
        "knowledge" -> rebuild_knowledge(run)
        "chunks" -> rebuild_chunks(run)
        "scopes" -> rebuild_scopes(run)
        "complete" -> {:ok, run.payload}
      end
    end
  end

  defp ensure_target_identity(run) do
    current =
      DataLayer.with_account_id(run.account_id, [role: :system, pipeline?: true], fn _account,
                                                                                     actor ->
        :embedder
        |> Config.resolve(%{account_id: run.account_id, actor: actor})
        |> Config.embedding_identity()
      end)

    Embedding.ensure_compatible(run.payload["identity"], current)
  end

  defp rebuild_knowledge(run) do
    {items, actor} = read_batch(run, KnowledgeItem, knowledge_filter(run.payload["cursor"]))

    case items do
      [] -> run |> advance("chunks", nil) |> rebuild_chunks()
      items -> embed_knowledge(run, items, actor)
    end
  end

  defp embed_knowledge(run, items, actor) do
    context = %{account_id: run.account_id, actor: actor}

    with {:ok, embedding} <-
           Embedding.embed(Enum.map(items, & &1.statement), context,
             stored_identity: run.payload["identity"],
             purpose: :document
           ) do
      write_knowledge!(run.account_id, items, embedding)

      run
      |> advance("knowledge", List.last(items).id, knowledge_processed: length(items))
      |> rebuild_knowledge()
    end
  end

  defp rebuild_chunks(run) do
    {chunks, actor} = read_batch(run, DocumentChunk, chunk_filter(run.payload["cursor"]))

    case chunks do
      [] -> run |> advance("scopes", nil) |> rebuild_scopes()
      chunks -> embed_chunks(run, chunks, actor)
    end
  end

  defp embed_chunks(run, chunks, actor) do
    context = %{account_id: run.account_id, actor: actor}

    with {:ok, embedding} <-
           Embedding.embed(Enum.map(chunks, & &1.text), context,
             stored_identity: run.payload["identity"],
             purpose: :document
           ) do
      write_chunks!(run.account_id, chunks, embedding)

      run
      |> advance("chunks", List.last(chunks).id, chunks_processed: length(chunks))
      |> rebuild_chunks()
    end
  end

  defp rebuild_scopes(run) do
    {scopes, _actor} = read_batch(run, Scope, cursor_filter(run.payload["cursor"]))

    case scopes do
      [] -> {:ok, advance(run, "complete", nil).payload}
      scopes -> rebuild_scope_batch(run, scopes)
    end
  end

  defp rebuild_scope_batch(run, scopes) do
    updated =
      Enum.reduce(scopes, run, fn scope, current ->
        {:ok, _result} =
          MemHouse.Retrieval.EntityResolver.rebuild_scope(run.account_id, scope.id)

        advance(current, "scopes", scope.id, scopes_processed: 1)
      end)

    rebuild_scopes(updated)
  end

  defp read_batch(run, resource, filter) do
    DataLayer.with_account_id(run.account_id, [role: :system, pipeline?: true], fn _account,
                                                                                   actor ->
      rows =
        resource
        |> Ash.Query.filter(^filter)
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.limit(@batch_size)
        |> Ash.Query.set_tenant(run.account_id)
        |> Ash.read!(actor: actor)

      {rows, actor}
    end)
  end

  defp knowledge_filter(nil) do
    retrievable_states = Lifecycle.retrievable_states()
    Ash.Expr.expr(state in ^retrievable_states and is_nil(deleted_at))
  end

  defp knowledge_filter(cursor) do
    retrievable_states = Lifecycle.retrievable_states()
    Ash.Expr.expr(state in ^retrievable_states and is_nil(deleted_at) and id > ^cursor)
  end

  defp chunk_filter(nil), do: Ash.Expr.expr(status == "active")
  defp chunk_filter(cursor), do: Ash.Expr.expr(status == "active" and id > ^cursor)
  defp cursor_filter(nil), do: Ash.Expr.expr(true)
  defp cursor_filter(cursor), do: Ash.Expr.expr(id > ^cursor)

  defp write_knowledge!(account_id, items, embedding) do
    write_vectors!(account_id, items, embedding, :index_from_pipeline)
  end

  defp write_chunks!(account_id, chunks, embedding) do
    write_vectors!(account_id, chunks, embedding, :reindex_from_pipeline)
  end

  defp write_vectors!(account_id, rows, embedding, action) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      Enum.zip(rows, embedding.vectors)
      |> Enum.each(fn {row, vector} ->
        label = DiskannLabels.ensure_scope!(account_id, row.scope_id)

        row
        |> Ash.Changeset.for_update(action, %{
          embedding: vector,
          embedding_provider: embedding.provider,
          embedding_model: embedding.model,
          embedding_version: embedding.version,
          embedding_dimensions: embedding.dimensions,
          diskann_labels: [label]
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: actor)
      end)
    end)
  end

  defp advance(run, phase, cursor, increments \\ []) do
    payload =
      run.payload
      |> Map.put("phase", phase)
      |> Map.put("cursor", cursor)
      |> increment("knowledge_processed", Keyword.get(increments, :knowledge_processed, 0))
      |> increment("chunks_processed", Keyword.get(increments, :chunks_processed, 0))
      |> increment("scopes_processed", Keyword.get(increments, :scopes_processed, 0))

    DataLayer.with_account_id(run.account_id, [role: :system, pipeline?: true], fn _account,
                                                                                   actor ->
      run
      |> Ash.Changeset.for_update(:record_reembed_progress, %{payload: payload})
      |> Ash.Changeset.set_tenant(run.account_id)
      |> Ash.update!(actor: actor)
    end)
  end

  defp increment(payload, _key, 0), do: payload
  defp increment(payload, key, count), do: Map.update(payload, key, count, &(&1 + count))
end
