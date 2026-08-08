# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Reconciler do
  @moduledoc """
  The safety net that finds durable work no job is going to finish.

  Jobs can die or exhaust retries after durable ingest. This sweep finds unfinished records in one
  Account and enqueues them again.

  Re-enqueueing is safe because the original deterministic key reuses an existing run.

  It only schedules work; it does not mutate observations or write knowledge.

  What it looks for, per Account:

  - messages that were never stamped as extracted;
  - document versions still pending, or whose processing failed;
  - active connectors that are due (or have never run);
  - scopes with active statements but no derived entity mentions.
  """

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Documents.ConnectorConfig
  alias MemHouse.Observations.DocumentVersion
  alias MemHouse.Observations.Message
  alias MemHouse.Pipeline
  alias MemHouse.Retrieval.Store

  require Ash.Query

  @doc """
  Sweeps one Account and re-enqueues everything that looks unfinished.

  The whole sweep runs inside a single Account-scoped transaction under a system
  pipeline actor: the reads need to see rows no ordinary caller may read, and
  every enqueue is required to happen inside a transaction so its run row and
  its job commit together. `account_id` is installed as the transaction-local
  setting row-level security reads, so the sweep cannot reach another tenant's
  rows.

  Returns `{:ok, counts}` with `:messages`, `:documents`, `:connectors`, `:scopes`, and
  `:reconciled` (their sum). The counts report how many enqueues *succeeded*,
  not how much new work was created — a record whose run already exists is
  counted as reconciled because the upsert succeeded. A steady non-zero count
  therefore means "these records keep being re-offered", which is normal while
  work is retrying, not evidence of duplicate processing.

  Raises if the transaction fails, including when a query is denied or the
  Account does not exist.
  """
  @spec run(Ecto.UUID.t()) :: {:ok, map()}
  def run(account_id) do
    counts =
      DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn
        _account, actor ->
          # A message is stamped as extracted only after every knowledge row it
          # produced is written, so an unstamped message is either still in
          # flight or was abandoned. Both cases want the same treatment: offer
          # the work again under its existing replay key.
          messages =
            Message
            |> Ash.Query.filter(is_nil(extraction_completed_at))
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn message ->
              match?({:ok, _run}, Pipeline.enqueue_message_extraction(message, actor))
            end)

          # Failed versions are retried as well as pending ones: a version that
          # exhausted its job attempts has no other route back into processing.
          documents =
            DocumentVersion
            |> Ash.Query.filter(processing_status in ["pending", "failed"])
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn version ->
              match?({:ok, _run}, Pipeline.enqueue_document_extraction(version, actor))
            end)

          now = Clock.utc_now()

          # Nothing polls connectors on a timer, so this sweep is what makes a
          # due connector actually run when no explicit request triggered it. A
          # connector that has never synced has no due time yet, so a null one
          # counts as due.
          connectors =
            ConnectorConfig
            |> Ash.Query.filter(
              status == "active" and (is_nil(next_sync_at) or next_sync_at <= ^now)
            )
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn connector ->
              match?({:ok, _run}, Pipeline.enqueue_connector_sync(connector, actor))
            end)

          scopes =
            account_id
            |> Store.scopes_missing_mentions()
            |> Enum.count(fn row ->
              watermark =
                "mentions:#{row["statement_count"]}:#{row["latest_statement_at"]}"

              match?(
                {:ok, _run},
                Pipeline.enqueue_projection_refresh(
                  account_id,
                  row["scope_id"],
                  watermark,
                  actor
                )
              )
            end)

          %{messages: messages, documents: documents, connectors: connectors, scopes: scopes}
      end)

    {:ok, Map.put(counts, :reconciled, Enum.sum(Map.values(counts)))}
  end
end
