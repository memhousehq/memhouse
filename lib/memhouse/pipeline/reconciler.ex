# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Reconciler do
  @moduledoc """
  The safety net that finds durable work no job is going to finish.

  Jobs can die or exhaust retries after durable ingest. This scheduled sweep finds stale,
  unfinished records in one Account and enqueues one bounded batch again.

  Re-enqueueing is safe because the original deterministic key reuses an existing run.

  It only schedules work; it does not mutate observations or write knowledge.

  What it looks for, per Account:

  - messages that were never stamped as extracted;
  - document versions still pending, or whose processing failed;
  - active connectors that are due (or have never run);
  - scopes with missing or stale source-message embeddings and no recoverable
    projection refresh;
  - scopes with active statements but no derived entity mentions; and
  - scopes with pre-expiry-bound projections that could not be safely upgraded in place.
  """

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Documents.ConnectorConfig
  alias MemHouse.Knowledge.Projection
  alias MemHouse.Model.Config
  alias MemHouse.Observations.DocumentVersion
  alias MemHouse.Observations.Message
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.Idempotency
  alias MemHouse.Retrieval.Store

  require Ash.Query

  @batch_size 100
  @stale_after_seconds 300

  @doc """
  Sweeps one Account and re-enqueues one bounded batch of stale work.

  The whole sweep runs inside a single Account-scoped transaction under a system
  pipeline actor: the reads need to see rows no ordinary caller may read, and
  every enqueue is required to happen inside a transaction so its run row and
  its job commit together. `account_id` is installed as the transaction-local
  setting row-level security reads, so the sweep cannot reach another tenant's
  rows.

  Ordinary work younger than 5 minutes is left to its current job. Batched
  extraction claims use their separately configured lease (20 minutes by
  default, enough for the bounded structured-repair loop). Each source query
  is limited to 100 rows and ordered by insertion time and id. A later hourly
  sweep continues with what remains.

  A cancelled or discarded Oban job first moves its run to the matching terminal state. A
  missing job moves its run to `discarded`. The next sweep replays that deterministic run. This
  two-pass sequence makes the job end durable before recovery starts.

  Returns `{:ok, counts}` with `:expired_claims`, `:replayed`, `:terminated`, `:messages`, `:documents`,
  `:connectors`, `:source_scopes`, `:scopes`, `:legacy_projection_scopes`, and
  `:reconciled` (the successful-enqueue sum). `:expired_claims` separately
  reports stale batch leases recovered before enqueue reconciliation. The
  remaining counts report how many enqueues *succeeded*,
  not how much new work was created — a record whose run already exists is
  counted as reconciled because the upsert succeeded. A steady non-zero count
  therefore means "these records keep being re-offered", which is normal while
  work is retrying, not evidence of duplicate processing.

  Raises if the transaction fails, including when a query is denied or the
  Account does not exist.
  """
  @spec run(Ecto.UUID.t()) :: {:ok, map()}
  def run(account_id) do
    stale_before = DateTime.add(Clock.utc_now(), -@stale_after_seconds, :second)
    claim_stale_before = DateTime.add(Clock.utc_now(), -claim_timeout_seconds(), :second)

    counts =
      DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn
        _account, actor ->
          expired_claims = expire_batch_claims(account_id, actor, claim_stale_before)
          replayed = replay_terminated(account_id, actor, stale_before)
          terminated = terminate_stranded(account_id, actor, stale_before)

          # A message is stamped as extracted only after every knowledge row it
          # produced is written, so an unstamped message is either still in
          # flight or was abandoned. Both cases want the same treatment: offer
          # the work again under its existing replay key.
          messages =
            Message
            |> Ash.Query.filter(is_nil(extraction_completed_at) and inserted_at <= ^stale_before)
            |> Ash.Query.sort(inserted_at: :asc, id: :asc)
            |> Ash.Query.limit(@batch_size)
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn message ->
              not Pipeline.extraction_terminal?(account_id, message.id, actor) and
                match?({:ok, _run}, Pipeline.enqueue_message_extraction(message, actor))
            end)

          # Failed versions are retried as well as pending ones: a version that
          # exhausted its job attempts has no other route back into processing.
          documents =
            DocumentVersion
            |> Ash.Query.filter(
              processing_status in ["pending", "failed"] and inserted_at <= ^stale_before
            )
            |> Ash.Query.sort(inserted_at: :asc, id: :asc)
            |> Ash.Query.limit(@batch_size)
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
            |> Ash.Query.sort(next_sync_at: :asc_nils_first, id: :asc)
            |> Ash.Query.limit(@batch_size)
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn connector ->
              match?({:ok, _run}, Pipeline.enqueue_connector_sync(connector, actor))
            end)

          identity =
            :embedder
            |> Config.resolve(%{account_id: account_id, actor: actor})
            |> Config.embedding_identity()

          # Message creation normally schedules the coalesced scope refresh in
          # its own transaction. This corpus scan is the crash/upgrade safety
          # net: it covers rows created before that hook existed, stale vectors
          # after an embedding-identity change, and a refresh whose job ended.
          # Existing recoverable work wins so an hourly sweep never adds a
          # second provider call while a scope job can still converge.
          source_scopes =
            account_id
            |> Store.scopes_with_stale_source_embeddings(identity, @batch_size)
            |> Enum.count(fn row ->
              scope_id = row["scope_id"]
              plan = Pipeline.maintenance_plan_for_scope(account_id, scope_id, actor)

              not Pipeline.projection_refresh_recoverable?(account_id, scope_id, actor) and
                match?(
                  {:ok, _run},
                  Pipeline.enqueue_projection_refresh(
                    account_id,
                    scope_id,
                    source_refresh_watermark(row, identity),
                    actor,
                    plan
                  )
                )
            end)

          scopes =
            account_id
            |> Store.scopes_missing_mentions(@batch_size)
            |> Enum.count(fn row ->
              plan =
                Pipeline.maintenance_plan_for_scope(account_id, row["scope_id"], actor)

              watermark =
                "mentions:#{row["statement_count"]}:#{row["latest_statement_at"]}"

              MemHouse.Retrieval.MaintenancePlan.scheduled?(plan, "entities") and
                not Pipeline.projection_refresh_recoverable?(
                  account_id,
                  row["scope_id"],
                  actor
                ) and
                match?(
                  {:ok, _run},
                  Pipeline.enqueue_projection_refresh(
                    account_id,
                    row["scope_id"],
                    watermark,
                    actor,
                    plan
                  )
                )
            end)

          legacy_projection_scopes =
            Projection
            |> Ash.Query.filter(validity_version != version and dirty == false)
            |> Ash.Query.select([:id, :scope_id, :updated_at, :version])
            |> Ash.Query.distinct(:scope_id)
            |> Ash.Query.sort(scope_id: :asc, updated_at: :desc, id: :desc)
            |> Ash.Query.limit(@batch_size)
            |> Ash.Query.set_tenant(account_id)
            |> Ash.read!(actor: actor)
            |> Enum.count(fn row ->
              not Pipeline.projection_refresh_recoverable?(account_id, row.scope_id, actor) and
                match?(
                  {:ok, _run},
                  Pipeline.enqueue_projection_refresh(
                    account_id,
                    row.scope_id,
                    projection_validity_watermark(row),
                    actor
                  )
                )
            end)

          %{
            expired_claims: expired_claims,
            replayed: replayed,
            terminated: terminated,
            messages: messages,
            documents: documents,
            connectors: connectors,
            source_scopes: source_scopes,
            scopes: scopes,
            legacy_projection_scopes: legacy_projection_scopes
          }
      end)

    reconciled =
      counts
      |> Map.drop([:expired_claims])
      |> Map.values()
      |> Enum.sum()

    {:ok, Map.put(counts, :reconciled, reconciled)}
  end

  defp claim_timeout_seconds do
    :memhouse
    |> Application.fetch_env!(:extraction_batching)
    |> Keyword.fetch!(:claim_timeout_seconds)
  end

  # Hash the content-free corpus cursor and current vector-space identity. The
  # digest keeps job payloads compact while making a changed corpus or embedder
  # distinct and exact reconciliation repeats idempotent.
  defp source_refresh_watermark(row, identity) do
    cursor = [
      row["scope_id"],
      row["message_count"],
      row["latest_message_at"],
      row["latest_message_id"],
      identity.provider,
      identity.model,
      identity.version,
      identity.dimensions
    ]

    "sources:" <>
      (cursor
       |> :erlang.term_to_binary([:deterministic])
       |> Idempotency.content_hash())
  end

  # The newest clean legacy row identifies this scope's unsafe projection generation. Include
  # both its stable id and update time: an old worker can rewrite the same cache key after a
  # successful upgrade, and its monotonic version plus update time must receive a new durable
  # refresh run.
  defp projection_validity_watermark(projection) do
    generation = [projection.scope_id, projection.id, projection.version, projection.updated_at]

    "projection-validity-v1:" <>
      (generation
       |> :erlang.term_to_binary([:deterministic])
       |> Idempotency.content_hash())
  end

  defp expire_batch_claims(account_id, actor, stale_before) do
    result =
      PipelineRun
      |> Ash.Query.filter(
        kind == "extraction" and target_type == "message" and status == "processing" and
          updated_at <= ^stale_before
      )
      |> Ash.Query.set_tenant(account_id)
      |> Ash.bulk_update!(:expire_extraction_claim, %{},
        actor: actor,
        return_records?: true,
        strategy: [:atomic]
      )

    length(result.records || [])
  end

  defp replay_terminated(account_id, actor, stale_before) do
    PipelineRun
    |> Ash.Query.filter(status in ["cancelled", "discarded"] and updated_at <= ^stale_before)
    |> Ash.Query.sort(updated_at: :asc, id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor, page: [limit: @batch_size])
    |> Map.fetch!(:results)
    |> Enum.count(fn run -> match?({:ok, _run}, Pipeline.requeue_terminated(run, actor)) end)
  end

  defp terminate_stranded(account_id, actor, stale_before) do
    runs =
      PipelineRun
      |> Ash.Query.filter(status in ["pending", "failed"] and updated_at <= ^stale_before)
      |> Ash.Query.sort(updated_at: :asc, id: :asc)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor, page: [limit: @batch_size])
      |> Map.fetch!(:results)

    states = Store.latest_oban_job_states(Enum.map(runs, & &1.idempotency_key))

    Enum.count(runs, fn run ->
      case Map.get(states, run.idempotency_key) do
        "cancelled" ->
          match?(
            {:ok, _run},
            Pipeline.mark_terminated(run, "cancelled", "ObanJobCancelled", actor)
          )

        "discarded" ->
          match?(
            {:ok, _run},
            Pipeline.mark_terminated(run, "discarded", "ObanJobDiscarded", actor)
          )

        nil ->
          match?(
            {:ok, _run},
            Pipeline.mark_terminated(run, "discarded", "ObanJobMissing", actor)
          )

        _active_or_completed ->
          false
      end
    end)
  end
end
