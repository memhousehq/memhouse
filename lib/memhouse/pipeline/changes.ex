# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Changes.ExecuteRun do
  @moduledoc """
  Runs a pipeline run's workflow and records how it ended, as one update.

  This is every background job's body. Workflow outcome determines the run update.

  ## Ordering

  The workflow is invoked in `before_transaction`, so it runs before this row's
  update is issued and its outcome decides what that update contains. Success
  stamps `completed`, the processing time, and a bumped attempt count, and
  clears any previous error class. Failure adds the error to the changeset,
  which aborts the update and lets the job runner's failure path record the
  attempt instead.

  `before_transaction` keeps the workflow outside the action transaction; lanes own their short
  transactions. Lane commits can survive a later status-update failure, so every lane must remain
  replay-safe under its deterministic key.

  The attempt count is incremented from the row as it was read, not with a
  database-side increment, which is accurate because a run only ever has one
  job in flight at a time.
  """

  use Ash.Resource.Change

  alias MemHouse.Clock
  alias MemHouse.Pipeline

  @doc """
  Attaches the execute-then-record behaviour to the changeset.

  Returns the changeset with a `before_transaction` hook. The hook returns an
  updated changeset on success, or a changeset carrying the workflow's error on
  failure, which prevents the row from being marked completed.
  """
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      run = changeset.data

      case Pipeline.execute(run) do
        {:ok, %{run_status: status}}
        when status in ["processing", "repairable", "terminal"] ->
          changeset
          |> Ash.Changeset.force_change_attribute(:status, status)
          |> Ash.Changeset.force_change_attribute(
            :processed_at,
            if(status == "processing", do: nil, else: Clock.utc_now())
          )
          |> Ash.Changeset.force_change_attribute(:attempt_count, run.attempt_count + 1)

        {:ok, _result} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:status, "completed")
          |> Ash.Changeset.force_change_attribute(:processed_at, Clock.utc_now())
          |> Ash.Changeset.force_change_attribute(:last_error_class, nil)
          |> Ash.Changeset.force_change_attribute(:attempt_count, run.attempt_count + 1)

        # The error travels no further than the changeset: the row keeps its
        # current status and stays eligible for retry and reconciliation.
        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end)
  end
end

defmodule MemHouse.Pipeline.Changes.MarkRunFailed do
  @moduledoc """
  Records a failed attempt on a pipeline run without leaking why it failed.

  The job failure path marks the run failed, increments attempts, and leaves it retryable.

  ## Content safety

  Store only the error struct name, or a generic label for non-struct errors. Messages may contain
  content or credentials and must not enter this durable operator-visible row.
  """

  use Ash.Resource.Change

  alias MemHouse.DataLayer
  alias MemHouse.Operations.PipelineRun

  require Ash.Query
  require Logger

  @doc """
  Marks the run failed and increments its attempt count.

  Reads the `:error` argument supplied by the job runner and stores only its
  classification. Returns the updated changeset; it never fails, because the
  failure path must always be able to record an outcome.
  """
  @impl true
  def change(changeset, _opts, context) do
    error = Ash.Changeset.get_argument(changeset, :error)
    class = error_class(error)
    run = changeset.data

    failed_changeset =
      changeset
      |> Ash.Changeset.force_change_attribute(:status, "failed")
      |> Ash.Changeset.force_change_attribute(:last_error_class, class)
      |> Ash.Changeset.force_change_attribute(
        :attempt_count,
        changeset.data.attempt_count + 1
      )

    if run.kind == "extraction" do
      preserve_committed_anchor(failed_changeset, run, class, context.actor)
    else
      failed_changeset
    end
  end

  # A batched extraction commits each anchor before the outer Oban action
  # records its outcome. If the process crashes after one anchor commit, the
  # error callback still holds the stale row loaded before the workflow. Read
  # the current row inside the outcome transaction so that callback cannot
  # downgrade a completed/isolated anchor back to retryable `failed`.
  defp preserve_committed_anchor(changeset, run, class, actor) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      DataLayer.declare_account!(run.account_id)

      current =
        PipelineRun
        |> Ash.Query.filter(id == ^run.id)
        |> Ash.Query.set_tenant(run.account_id)
        # The enclosing `mark_failed` action has already been authorized. This
        # internal current-row read is additionally constrained by tenant, id,
        # and database RLS; it must also work for AshOban's actorless callback.
        |> Ash.read_one!(actor: actor, authorize?: false)

      cond do
        current.status in ["completed", "repairable", "terminal"] ->
          preserve_current(changeset, current)

        current.status == "failed" and current.attempt_count > run.attempt_count ->
          # The batching workflow classified the provider failure before
          # returning it. Keep that more precise, content-safe class instead of
          # replacing it with Reactor's outer wrapper class.
          log_extraction_failure(run, current.last_error_class)
          preserve_current(changeset, current)

        current.status == "processing" and not is_nil(current.batch_claim_id) ->
          # A stale worker can fail after reconciliation handed the anchor to a
          # new claim. Its outer callback must not cancel the new owner.
          preserve_current(changeset, current)

        true ->
          log_extraction_failure(run, class)
          changeset
      end
    end)
  end

  defp preserve_current(changeset, current) do
    changeset
    |> Ash.Changeset.force_change_attribute(:status, current.status)
    |> Ash.Changeset.force_change_attribute(:last_error_class, current.last_error_class)
    |> Ash.Changeset.force_change_attribute(:attempt_count, current.attempt_count)
    |> Ash.Changeset.force_change_attribute(:processed_at, current.processed_at)
    |> Ash.Changeset.force_change_attribute(:payload, current.payload)
  end

  defp log_extraction_failure(run, class) do
    Logger.error("pipeline extraction failed",
      account_id: run.account_id,
      scope_id: run.scope_id,
      pipeline_run_id: run.id,
      target_type: run.target_type,
      target_id: run.target_id,
      message_id: if(run.target_type == "message", do: run.target_id),
      attempt_count: run.attempt_count + 1,
      error_class: class
    )
  end

  # The struct's module name is a content-free classification. Everything else,
  # including bare strings and tuples that may embed content, collapses to a
  # single generic label rather than being inspected into the row.
  defp error_class(%module{}), do: inspect(module)
  defp error_class(_error), do: "pipeline_error"
end
