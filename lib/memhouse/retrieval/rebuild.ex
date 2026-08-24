# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Rebuild do
  @moduledoc """
  Rebuilds one scope's derived caches in dependency order.

  All output is reconstructible. Vectors must precede recall documents and
  entities/mentions, which must precede context projections; reordering can
  build plausible projections from stale indexes.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Retrieval.Coverage
  alias MemHouse.Retrieval.MaintenancePlan

  @doc """
  Rebuilds one scope's embeddings, entity index, and context projections.

  Stops at the first error. Completed stages remain committed; replay is the recovery path.

  A successful rebuild emits `[:memhouse, :retrieval, :projection_refresh]`
  carrying indexed/projected/removed counts and coverage read from persisted
  scope state after the refresh writes complete, so an operator can alert on a
  scope whose vectors never arrived instead of waiting for a user to report
  missing recall. It is the only signal this lane produces: the stage counts
  below are returned to the caller and stored nowhere.

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

  Source messages missing the current embedding identity and statements
  without vectors enter their respective batched embedder calls. Entity and
  projection stages still refresh the scope because lifecycle changes can
  remove sources as well as add them. Raw-message creation schedules this same
  operation, so a zero-fact extraction still receives source indexing.
  """
  def refresh_scope(account_id, scope_id),
    do: refresh_scope(account_id, scope_id, MaintenancePlan.for_profile(:current))

  @doc "Runs a coalesced refresh from the immutable plan captured by its pipeline run."
  def refresh_scope(account_id, scope_id, payload_or_plan) do
    plan =
      if Map.has_key?(payload_or_plan, :stages),
        do: payload_or_plan,
        else: MaintenancePlan.from_payload(payload_or_plan)

    with {:ok, sources} <- MemHouse.Retrieval.SourceIndexer.refresh_scope(account_id, scope_id),
         {:ok, index} <- MemHouse.Retrieval.Indexer.refresh_scope(account_id, scope_id),
         {:ok, recall_documents} <-
           MemHouse.Retrieval.RecallProjector.refresh_scope(account_id, scope_id),
         {:ok, entities} <- run_entities(plan, account_id, scope_id),
         {:ok, projections} <- run_projections(plan, account_id, scope_id) do
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

  defp run_entities(plan, account_id, scope_id) do
    if MaintenancePlan.scheduled?(plan, "entities") do
      MemHouse.Retrieval.EntityResolver.rebuild_scope(account_id, scope_id)
    else
      {:ok, skipped()}
    end
  end

  defp run_projections(plan, account_id, scope_id) do
    if MaintenancePlan.scheduled?(plan, "context_projections") do
      MemHouse.Context.Builder.refresh_scope(account_id, scope_id)
    else
      {:ok, skipped()}
    end
  end

  defp skipped, do: %{status: "skipped", reason_class: "profile_disabled"}

  # Measured after the write phase in its own short Account-scoped transaction,
  # so the event describes what a reader would now find rather than what this
  # run intended to write. Ids and counts only.
  defp emit_coverage(account_id, scope_id, index, recall_documents) do
    coverage =
      DataLayer.in_account_transaction(account_id, fn ->
        Coverage.scope(account_id, scope_id, nil, true)
      end)

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
