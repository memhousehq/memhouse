# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Rebuild do
  @moduledoc """
  Rebuilds one scope's derived caches in dependency order.

  All output is reconstructible. Vectors must precede recall documents and
  entities/mentions, which must precede context projections; reordering can
  build plausible projections from stale indexes.
  """

  alias MemHouse.Retrieval.Coverage

  @doc """
  Rebuilds one scope's embeddings, entity index, and context projections.

  Stops at the first error. Completed stages remain committed; replay is the recovery path.

  A successful rebuild emits `[:memhouse, :retrieval, :projection_refresh]`
  carrying indexed/projected/removed counts and the resulting coverage, so an operator can
  alert on a scope whose vectors never arrived instead of waiting for a user to
  report missing recall. It is the only signal this lane produces: the stage
  counts below are returned to the caller and stored nowhere.

  Returns `{:ok, %{index: ..., entities: ..., projections: ...}}` with each
  stage's counts, or the first stage error. Raises if an underlying read or
  write fails.
  """
  def scope(account_id, scope_id) do
    with {:ok, sources} <- MemHouse.Retrieval.SourceIndexer.rebuild_scope(account_id, scope_id),
         {:ok, index} <- MemHouse.Retrieval.Indexer.rebuild_scope(account_id, scope_id),
         {:ok, recall_documents} <-
           MemHouse.Retrieval.RecallProjector.rebuild_scope(account_id, scope_id),
         {:ok, entities} <-
           MemHouse.Retrieval.EntityResolver.rebuild_scope(account_id, scope_id),
         {:ok, projections} <- MemHouse.Context.Builder.refresh_scope(account_id, scope_id) do
      emit_coverage(account_id, scope_id, index, recall_documents)

      {:ok,
       %{
         sources: sources,
         index: index,
         recall_documents: recall_documents,
         entities: entities,
         projections: projections
       }}
    end
  end

  @doc """
  Refreshes caches after ordinary governed writes in a scope.

  Only statements without vectors enter the batched embedder call. Entity and
  projection stages still refresh the scope because lifecycle changes can
  remove sources as well as add them.
  """
  def refresh_scope(account_id, scope_id) do
    with {:ok, sources} <- MemHouse.Retrieval.SourceIndexer.refresh_scope(account_id, scope_id),
         {:ok, index} <- MemHouse.Retrieval.Indexer.refresh_scope(account_id, scope_id),
         {:ok, recall_documents} <-
           MemHouse.Retrieval.RecallProjector.refresh_scope(account_id, scope_id),
         {:ok, entities} <-
           MemHouse.Retrieval.EntityResolver.rebuild_scope(account_id, scope_id),
         {:ok, projections} <- MemHouse.Context.Builder.refresh_scope(account_id, scope_id) do
      emit_coverage(account_id, scope_id, index, recall_documents)

      {:ok,
       %{
         sources: sources,
         index: index,
         recall_documents: recall_documents,
         entities: entities,
         projections: projections
       }}
    end
  end

  # Measured after the write phase, so the event describes what a reader would
  # now find rather than what this run intended to write. Ids and counts only.
  defp emit_coverage(account_id, scope_id, index, recall_documents) do
    coverage = Coverage.scope(account_id, scope_id, nil, true)

    :telemetry.execute(
      [:memhouse, :retrieval, :projection_refresh],
      %{
        indexed: index.indexed,
        recall_documents_projected: recall_documents.projected,
        recall_documents_removed: recall_documents.removed,
        statements: coverage.statement_count,
        embedded: coverage.embedded_count,
        mentions: coverage.mention_count,
        coverage: coverage.coverage
      },
      %{account_id: account_id, scope_id: scope_id}
    )
  end
end
