# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Workflows.IngestExtraction do
  @moduledoc """
  The workflow that turns one committed raw observation into proposed knowledge.

  The durable ingest lane dispatches to the same Account-scoped entry points as inline ingest.
  Its output enters governance as proposals.

  The step reads content by target id; jobs and runs carry no observation text.

  Retry is safe because target id and content hash form the replay key. Steps must not depend on
  first-attempt-only state.

  A run whose `target_type` is neither a message nor a document version makes
  the step raise a `CaseClauseError`, which Reactor turns into an error result
  and the job records as a failed attempt. That is intentional: the enqueue side
  controls the target type, so an unknown one means the row was written by
  something that bypassed it.
  """

  use Ash.Reactor

  alias MemHouse.Retrieval.MaintenancePlan

  input(:pipeline_run)

  step :extract do
    argument :pipeline_run, input(:pipeline_run)
    # Runs in the job's process so the Account-scoped transaction the extraction
    # opens — and the transaction-local settings that scope it — stay on this
    # connection.
    async? false

    run fn %{pipeline_run: run}, _context ->
      run.payload
      |> MaintenancePlan.from_payload()
      |> MaintenancePlan.with_plan(fn ->
        case run.target_type do
          "message" ->
            if MemHouse.Pipeline.ExtractionAdmission.enabled?() do
              MemHouse.Pipeline.ExtractionBatcher.run(run)
            else
              MemHouse.Memory.extract_message_for_account(run.target_id, run.account_id)
            end

          "document_version" ->
            MemHouse.Documents.process_version_for_account(run.target_id, run.account_id)
        end
      end)
    end
  end

  return :extract
end

defmodule MemHouse.Pipeline.Workflows.DreamTimeReasoning do
  @moduledoc """
  Background reasoning and derived-cache maintenance for one Account.

  Three lanes share this workflow because they are all off-request consolidation
  work rather than user-facing latency:

  - `dream_time` dispatches incremental per-scope reasoning, then runs
    Account-wide queue aging and query decay;
  - `entity_resolution` rebuilds the entity and mention caches for the run's
    scope;
  - `projection_refresh` runs the full derived-cache rebuild for that scope —
    the vector index, the entity caches, and the projections.

  Vectors, entities, mentions, and projections are rebuildable derived caches:
  they can be discarded and recomputed from surviving governed statements, so
  nothing this workflow writes to them is a system of record.

  Only the `dream_time` branch consults the Account budget. When admission is
  refused the step returns a throttled result and reports success, so the run
  completes rather than retrying and consuming the budget it was just denied. Do
  not turn that into an error: a retry loop is exactly what the throttle exists
  to prevent.

  Ordinary governed writes enqueue only `projection_refresh`. Its scope-window
  key and trailing delay coalesce a burst, and its dependency-ordered rebuild
  includes entity resolution. The separate entity lane remains for explicit
  maintenance work and compatible queued jobs.
  """

  use Ash.Reactor

  require Logger

  input(:pipeline_run)

  step :reason do
    argument :pipeline_run, input(:pipeline_run)
    # Rebuilds stay on the job's process so their Account-scoped transaction —
    # and the transaction-local settings that scope it — apply to the connection
    # doing the work.
    async? false

    run fn %{pipeline_run: run}, _context ->
      case run.kind do
        "dream_time" ->
          case dream_mode(run) do
            :idle_scope -> run_idle_scope(run)
            :account -> run_account_dream(run)
            :invalid -> {:ok, %{status: "rejected", reason_class: "invalid_dream_target"}}
          end

        "entity_resolution" ->
          MemHouse.Retrieval.EntityResolver.rebuild_scope(run.account_id, run.scope_id)

        "projection_refresh" ->
          if run.payload["mode"] == "coalesced" do
            MemHouse.Retrieval.Rebuild.refresh_scope(run.account_id, run.scope_id, run.payload)
          else
            MemHouse.Retrieval.rebuild_scope(run.account_id, run.scope_id)
          end

        _other ->
          MemHouse.Pipeline.Workflows.Stage.run(run)
      end
    end
  end

  return :reason

  defp dream_mode(%{payload: %{"mode" => "idle_scope"}} = run)
       when run.target_type == "scope" and run.scope_id == run.target_id,
       do: :idle_scope

  defp dream_mode(run)
       when run.target_type == "account" and run.target_id == run.account_id do
    if run.payload["mode"] == "idle_scope", do: :invalid, else: :account
  end

  defp dream_mode(_run), do: :invalid

  defp run_idle_scope(run) do
    # The generation check runs under the same scope lock as governance
    # scheduling and returns before retrieval or a provider call.
    if MemHouse.Operations.Budget.admit?(run.account_id, run.scope_id, :dream_time) do
      handle_dream_result(
        MemHouse.Pipeline.DreamTime.run_scheduled_scope(
          run.account_id,
          run.scope_id,
          run.payload["activity_at"],
          run.payload["activity_id"]
        ),
        run
      )
    else
      {:ok, %{status: "throttled", lane: "dream_time"}}
    end
  end

  defp run_account_dream(run) do
    # Budget refusal is a completed run, not a failure: retrying would queue
    # the same denied work again.
    if MemHouse.Operations.Budget.admit?(run.account_id, run.scope_id, :dream_time) do
      case handle_dream_result(MemHouse.Pipeline.DreamTime.run(run.account_id), run) do
        {:ok, reasoning} ->
          case MemHouse.Governance.Sweeper.run(run.account_id, "dream_time") do
            {:ok, sweep} ->
              {:ok, %{reasoning: reasoning, sweep: sweep}}

            {:error, error} ->
              # Reasoning has already committed and may have been billed. Do
              # not retry it because independent maintenance failed.
              Logger.error("dream-time governance sweep failed",
                account_id: run.account_id,
                pipeline_run_id: run.id,
                error_class: error_class(error)
              )

              {:ok, %{reasoning: reasoning, sweep: %{status: "failed"}}}
          end

        error ->
          error
      end
    else
      {:ok, %{status: "throttled", lane: "dream_time"}}
    end
  end

  defp error_class(%module{}), do: inspect(module)
  defp error_class(_error), do: "unknown"

  defp handle_dream_result(result, run) do
    case result do
      {:ok, reasoning} ->
        {:ok, reasoning}

      {:error, %MemHouse.Pipeline.DreamTime.InvalidCandidate{} = error} ->
        Logger.error("dream-time retrieval candidate rejected",
          account_id: run.account_id,
          pipeline_run_id: run.id,
          error_class: inspect(error.__struct__)
        )

        {:ok, %{status: "rejected", reason_class: "invalid_retrieval_candidate"}}

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule MemHouse.Pipeline.Workflows.ValidationContinuation do
  @moduledoc """
  Compatibility workflow for validation-continuation jobs written before issue 175.

  Current gate decisions create their validation rows and peer questions inline,
  so they do not enqueue this lane. Keep this no-op workflow and its trigger
  until deployments no longer have pre-change jobs to drain.

  The run records no new effect. It only lets a previously committed job
  complete successfully after an upgrade.
  """

  use Ash.Reactor

  input(:pipeline_run)

  step :continue_validation do
    argument :pipeline_run, input(:pipeline_run)
    async? false

    run fn %{pipeline_run: run}, _context ->
      MemHouse.Pipeline.Workflows.Stage.run(run)
    end
  end

  return :continue_validation
end

defmodule MemHouse.Pipeline.Workflows.AnswerCorrelationContinuation do
  @moduledoc """
  The durable continuation queued when a peer answers a validation question.

  Resolving an inline question records the verdict synchronously and enqueues
  this run, keyed by the question and the session the answer arrived in, so a
  repeated delivery or a retry converges on one run.

  This lane writes no knowledge. An answer becomes knowledge only by travelling
  the ordinary path — raw observation, extraction, governance — which is why the
  lane may safely be replayed.

  Like the other continuation lane, the step currently returns a typed durable
  continuation and does nothing else. Adding behaviour here must preserve the
  existing replay key so already-queued runs keep their identity.
  """

  use Ash.Reactor

  input(:pipeline_run)

  step :correlate_answer do
    argument :pipeline_run, input(:pipeline_run)
    async? false

    run fn %{pipeline_run: run}, _context ->
      MemHouse.Pipeline.Workflows.Stage.run(run)
    end
  end

  return :correlate_answer
end

defmodule MemHouse.Pipeline.Workflows.Maintenance do
  @moduledoc """
  The catch-all lane for upkeep work: sweeps, connector syncs, import rebuilds,
  and reconciliation.

  It handles several lanes and also serves as the fallback for any run whose
  kind this release does not recognise. That fallback matters during upgrades
  and downgrades: a queued row written by a different version completes as a
  durable continuation instead of failing forever and blocking its Account's
  queue.

  What each branch does:

  - `reconciler` re-enqueues Account-local observations that never finished
    processing;
  - `revalidation` and `expiry` run the governance sweeps that move stale
    knowledge out of active use;
  - `connector_sync` pulls one page from a connector and advances its cursor
    only after every item on that page has been applied;
  - `import_rebuild` recomputes what the archive left out after a logical
    import — per document version the full parse, chunk, embed, and extract
    derivation, and per scope the vector index, entity caches, and projections.
    Archives deliberately exclude those caches, so this lane is how an imported
    Account becomes searchable.

  Every branch is safe to run again. Sweeps are convergent, connector syncs
  treat an unchanged content hash as a no-op, and rebuild work recomputes caches
  that are allowed to be thrown away.
  """

  use Ash.Reactor

  input(:pipeline_run)

  step :maintain do
    argument :pipeline_run, input(:pipeline_run)
    async? false

    run fn %{pipeline_run: run}, _context ->
      case run.kind do
        "reconciler" ->
          MemHouse.Pipeline.Reconciler.run(run.account_id)

        kind when kind in ["revalidation", "expiry"] ->
          MemHouse.Governance.Sweeper.run(run.account_id, kind)

        "connector_sync" ->
          MemHouse.Documents.sync_connector_for_account(run.target_id, run.account_id)

        "import_rebuild" when run.target_type == "document_version" ->
          MemHouse.Documents.rebuild_version_for_account(run.target_id, run.account_id)

        "import_rebuild" when run.target_type == "scope" ->
          MemHouse.Retrieval.Rebuild.scope(run.account_id, run.target_id)

        "reembed" ->
          MemHouse.Retrieval.Reembed.run(run)

        # Unknown or not-yet-implemented lane: complete as a durable
        # continuation rather than failing a row this release cannot interpret.
        _other ->
          MemHouse.Pipeline.Workflows.Stage.run(run)
      end
    end
  end

  return :maintain
end

defmodule MemHouse.Pipeline.Workflows.Stage do
  @moduledoc """
  The typed "nothing further to do" result shared by every pipeline lane.

  A lane whose behaviour is not implemented in this release, or a run whose kind
  this release does not recognise, ends here. Returning a successful, explicitly
  labelled continuation keeps the durable run row, its replay key, and its
  transactional coupling real while the lane's behaviour is still absent — and,
  crucially, stops an unrecognised row from retrying until it exhausts its
  attempts and clogs the queue.

  It writes nothing. A `continuation: "durable"` result means "this run was
  accepted and closed without further work", not a completed domain operation.
  """

  @doc """
  Returns the content-free continuation result for a run.

  The result echoes the run's lane and target identifiers only; no observation
  content, statement, or payload is included.
  """
  def run(run) do
    {:ok,
     %{
       kind: run.kind,
       target_type: run.target_type,
       target_id: run.target_id,
       continuation: "durable"
     }}
  end
end
