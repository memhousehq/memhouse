# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline do
  @moduledoc """
  The only supported way to schedule and run background pipeline work.

  Agents and HTTP callers submit raw observations. Only the pipeline may create, corroborate,
  or activate knowledge.

  ## What enqueueing actually does

  Each `enqueue_*` function upserts a durable `PipelineRun`; its Ash action inserts the job in
  the caller's transaction. Source, audit, and work therefore commit or roll back together.
  Never insert jobs directly.

  ## Idempotency is mandatory, not optional

  Each run has a deterministic `idempotency_key` derived from its immutable input identity.
  Retries, reconciliation, and duplicates converge on one row. Every new lane needs a stable key;
  random ids or enqueue-time timestamps reintroduce duplicate processing.

  ## Content safety

  Payloads and job arguments may contain hashes, ids, watermarks, and short labels. They must not
  contain messages, statements, connector cursors, document bytes, or secrets.

  ## Actor handling

  Enqueue uses a system-pipeline copy of the caller; it never mutates the caller's actor.
  """

  alias MemHouse.Accounts.Account
  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline.{DreamTime, Idempotency, Lock}
  alias MemHouse.Retrieval.MaintenancePlan
  alias MemHouse.Retrieval.Store

  require Ash.Query

  # Public lane name to private Ash action. New lanes need an action, Oban trigger, and stable key.
  @enqueue_actions %{
    "extraction" => :enqueue_extraction,
    "dream_time" => :enqueue_dream_time,
    "revalidation" => :enqueue_revalidation,
    "expiry" => :enqueue_expiry,
    "projection_refresh" => :enqueue_projection_refresh,
    "connector_sync" => :enqueue_connector_sync,
    "import_rebuild" => :enqueue_import_rebuild,
    "reconciler" => :enqueue_reconciler,
    "entity_resolution" => :enqueue_entity_resolution,
    "reembed" => :enqueue_reembed,
    "validation_continuation" => :enqueue_validation_continuation,
    "answer_correlation" => :enqueue_answer_correlation
  }

  @doc """
  Schedules extraction of one raw message.

  Call inside the message transaction so observation and job commit together. The replay key
  combines message id and content hash. Only the hash enters the payload.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec enqueue_message_extraction(struct(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_message_extraction(message, actor) do
    enqueue(
      "extraction",
      message.account_id,
      %{
        scope_id: message.scope_id,
        target_type: "message",
        target_id: message.id,
        idempotency_key: Idempotency.message_extraction(message.id, message.content_hash),
        payload: %{"content_hash" => message.content_hash}
      },
      actor
    )
  end

  @doc """
  Schedules extraction of one immutable document version.

  Version id plus content hash is the replay key. Identical bytes reuse the run; changed bytes
  have a new version and run. The payload contains only the hash.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec enqueue_document_extraction(struct(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_document_extraction(version, actor) do
    enqueue(
      "extraction",
      version.account_id,
      %{
        scope_id: version.scope_id,
        target_type: "document_version",
        target_id: version.id,
        idempotency_key: Idempotency.document_extraction(version.id, version.content_hash),
        payload: %{"content_hash" => version.content_hash}
      },
      actor
    )
  end

  @doc """
  Schedules one sync pass for a connector.

  The replay key combines connector id, current cursor, and due slot. Repeated calls coalesce;
  the next cursor produces new work. The payload carries only `cursor_hash`.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec enqueue_connector_sync(struct(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_connector_sync(connector, actor) do
    # Falls back through due time, last completion, and creation so a connector
    # that has never run still produces a stable slot rather than a moving one.
    scheduled_at = connector.next_sync_at || connector.last_synced_at || connector.inserted_at

    enqueue(
      "connector_sync",
      connector.account_id,
      %{
        scope_id: connector.scope_id,
        target_type: "connector_config",
        target_id: connector.id,
        idempotency_key: Idempotency.connector_sync(connector.id, connector.cursor, scheduled_at),
        payload: %{
          "cursor_hash" =>
            connector.cursor
            |> :erlang.term_to_binary([:deterministic])
            |> Idempotency.content_hash()
        }
      },
      actor
    )
  end

  @doc """
  Schedules a reconciliation sweep for one Account.

  Re-enqueues stale durable work that did not finish. Equal watermarks share a run; `nil` uses
  the current time and creates distinct operator-requested work. Scheduled callers must pass
  their Cron slot so retries coalesce.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec enqueue_reconciler(Ecto.UUID.t(), map(), term()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_reconciler(account_id, actor, watermark \\ nil) do
    watermark = watermark || DateTime.to_iso8601(Clock.utc_now())

    enqueue(
      "reconciler",
      account_id,
      %{
        target_type: "account",
        target_id: account_id,
        idempotency_key: Idempotency.reconciler(account_id, watermark),
        payload: %{"watermark" => to_string(watermark)}
      },
      actor
    )
  end

  @doc """
  Schedules time-driven maintenance for one Account and Cron slot.

  `scheduled_at` is the Cron job's scheduled time. It is part of all replay
  keys, so delayed execution and retries reuse the same dream-time, expiry,
  revalidation, and reconciliation runs. Call inside an Account
  transaction; all run rows and jobs then commit together.

  Returns the four named runs or an error.
  """
  @spec enqueue_lifecycle_sweeps(Ecto.UUID.t(), map(), DateTime.t()) ::
          {:ok,
           %{
             dream_time: PipelineRun.t(),
             revalidation: PipelineRun.t(),
             expiry: PipelineRun.t(),
             reconciler: PipelineRun.t()
           }}
          | {:error, term()}
  def enqueue_lifecycle_sweeps(account_id, actor, %DateTime{} = scheduled_at) do
    payload = %{"scheduled_at" => DateTime.to_iso8601(scheduled_at)}

    with {:ok, dream_time} <-
           enqueue(
             "dream_time",
             account_id,
             %{
               target_type: "account",
               target_id: account_id,
               idempotency_key: Idempotency.account_dream_time(account_id, scheduled_at),
               payload: payload
             },
             actor
           ),
         {:ok, revalidation} <-
           enqueue(
             "revalidation",
             account_id,
             %{
               target_type: "account",
               target_id: account_id,
               idempotency_key:
                 Idempotency.lifecycle_sweep(account_id, "revalidation", scheduled_at),
               payload: payload
             },
             actor
           ),
         {:ok, expiry} <-
           enqueue(
             "expiry",
             account_id,
             %{
               target_type: "account",
               target_id: account_id,
               idempotency_key: Idempotency.lifecycle_sweep(account_id, "expiry", scheduled_at),
               payload: payload
             },
             actor
           ),
         {:ok, reconciler} <- enqueue_reconciler(account_id, actor, scheduled_at) do
      {:ok,
       %{
         dream_time: dream_time,
         revalidation: revalidation,
         expiry: expiry,
         reconciler: reconciler
       }}
    end
  end

  @doc """
  Schedules the ordinary full derived-cache rebuild for one scope.

  Callers supply a stable, content-free watermark. Repeated reconciliation of
  the same corpus therefore reuses one run, while a changed corpus produces new
  work.
  """
  @spec enqueue_projection_refresh(Ecto.UUID.t(), Ecto.UUID.t(), term(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_projection_refresh(account_id, scope_id, watermark, actor) do
    enqueue(
      "projection_refresh",
      account_id,
      %{
        scope_id: scope_id,
        target_type: "scope",
        target_id: scope_id,
        idempotency_key: Idempotency.projection_refresh(scope_id, watermark),
        payload: %{"watermark" => to_string(watermark)}
      },
      actor
    )
  end

  @doc "Enqueues a reconciliation refresh without widening its durable maintenance plan."
  @spec enqueue_projection_refresh(Ecto.UUID.t(), Ecto.UUID.t(), term(), map(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_projection_refresh(account_id, scope_id, watermark, actor, plan) do
    enqueue(
      "projection_refresh",
      account_id,
      %{
        scope_id: scope_id,
        target_type: "scope",
        target_id: scope_id,
        idempotency_key: Idempotency.projection_refresh(scope_id, watermark, plan.id),
        payload: plan |> MaintenancePlan.payload() |> Map.put("watermark", to_string(watermark))
      },
      actor
    )
  end

  @doc """
  Schedules one delayed derived-cache refresh for a burst of governed writes.

  Governed knowledge writes and raw-message creates in the same scope and
  ten-second bucket reuse one durable run. The refresh indexes source messages
  before rebuilding Knowledge-derived caches, so even a message that extracts
  zero facts gets durable semantic-index work.

  A 15-second delay guarantees that the bucket closes before execution, so all
  writes in it are included. The job carries only identifiers and a bucket key.
  """
  @spec enqueue_derived_refresh(Ecto.UUID.t(), Ecto.UUID.t(), DateTime.t(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_derived_refresh(account_id, scope_id, %DateTime{} = changed_at, actor) do
    plan = MaintenancePlan.current()

    enqueue(
      "projection_refresh",
      account_id,
      %{
        scope_id: scope_id,
        target_type: "scope",
        target_id: scope_id,
        idempotency_key:
          Idempotency.derived_refresh(
            scope_id,
            :projection_refresh,
            changed_at,
            10,
            plan.id
          ),
        payload: MaintenancePlan.payload(plan)
      },
      actor
    )
  end

  @doc """
  Durably schedules one scope wakeup after its latest governed activity goes idle.

  The activity timestamp and id are a content-free generation cursor. Exact
  duplicates reuse one run. Later activity creates a later wakeup; the older
  worker checks the generation under the scope lock and exits before any model
  work. Call this inside the governance transaction so knowledge, run, and job
  commit together.
  """
  @spec enqueue_idle_dream_time(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          DateTime.t(),
          Ecto.UUID.t(),
          map()
        ) :: {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue_idle_dream_time(account_id, scope_id, %DateTime{} = activity_at, activity_id, actor) do
    Lock.acquire!(account_id, DreamTime.scope_lock_key(scope_id))
    idle_seconds = dream_idle_seconds!()
    scheduled_at = DateTime.add(activity_at, idle_seconds, :second)
    actor = pipeline_actor(actor)

    PipelineRun
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{memhouse_actor: actor})
    |> Ash.Changeset.for_create(:enqueue_idle_dream_time, %{
      scope_id: scope_id,
      target_type: "scope",
      target_id: scope_id,
      idempotency_key: Idempotency.idle_dream_time(scope_id, activity_at, activity_id),
      payload: %{
        "mode" => "idle_scope",
        "activity_at" => DateTime.to_iso8601(activity_at),
        "activity_id" => activity_id
      },
      scheduled_at: scheduled_at
    })
    |> Ash.create(actor: actor)
  end

  @doc "True only when the experimental durable per-scope idle scheduler is enabled."
  def idle_dream_time_enabled? do
    case Keyword.fetch!(
           Application.fetch_env!(:memhouse, :dream_time_gates),
           :idle_scheduler_enabled
         ) do
      enabled when is_boolean(enabled) ->
        enabled

      invalid ->
        raise ArgumentError,
              "dream idle scheduler enabled flag must be boolean: #{inspect(invalid)}"
    end
  end

  @doc """
  Schedules a resumable Account-wide vector rebuild for one embedding identity.

  One identity creates one durable run. Progress contains only phase, UUID
  cursor, and counts. Repeating the request resumes or returns that run.
  """
  def enqueue_reembed(account_id, identity, actor) do
    enqueue(
      "reembed",
      account_id,
      %{
        target_type: "account",
        target_id: account_id,
        idempotency_key: Idempotency.reembed(account_id, identity),
        payload: %{
          "phase" => "knowledge",
          "cursor" => nil,
          "knowledge_processed" => 0,
          "chunks_processed" => 0,
          "scopes_processed" => 0,
          "identity" => identity
        }
      },
      actor
    )
  end

  @doc """
  Requests an Account reconciliation sweep from an authenticated operator.

  The actor selects the Account. The enqueue runs inside an Account-scoped
  transaction so row-level security applies and the durable run and Oban job
  commit together. The controller authorizes the operator role; this function
  preserves Account selection and transactional enqueue guarantees.

  Returns `{:ok, run}` or `{:error, reason}`.
  """
  @spec request_reconciliation(Actor.t()) :: {:ok, PipelineRun.t()} | {:error, term()}
  def request_reconciliation(%Actor{} = actor) do
    DataLayer.with_actor(actor, fn account, scoped_actor ->
      enqueue_reconciler(account.id, scoped_actor)
    end)
  end

  @doc """
  Requests one immediate Account-wide dream-time pass.

  The request creates a normal durable run. The current timestamp is a new
  replay watermark, so a later operator request is distinct work while Oban
  retries keep the same run.
  """
  @spec request_dream_time(Actor.t()) :: {:ok, PipelineRun.t()} | {:error, term()}
  def request_dream_time(%Actor{} = actor) do
    DataLayer.with_actor(actor, fn account, scoped_actor ->
      scheduled_at = Clock.utc_now()

      enqueue(
        "dream_time",
        account.id,
        %{
          target_type: "account",
          target_id: account.id,
          idempotency_key: Idempotency.account_dream_time(account.id, scheduled_at),
          payload: %{"requested_at" => DateTime.to_iso8601(scheduled_at)}
        },
        scoped_actor
      )
    end)
  end

  @doc """
  Records that the Oban job for a durable run ended without completing it.

  `status` is `"cancelled"` or `"discarded"`. `error_class` is a fixed,
  content-safe classification. Reconciliation uses this before a later sweep
  replays the deterministic run.
  """
  @spec mark_terminated(PipelineRun.t(), String.t(), String.t(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def mark_terminated(%PipelineRun{} = run, status, error_class, actor)
      when status in ["cancelled", "discarded"] and is_binary(error_class) do
    run
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(run.account_id)
    |> Ash.Changeset.for_update(:mark_terminated, %{
      status: status,
      last_error_class: error_class,
      processed_at: Clock.utc_now()
    })
    |> Ash.update(actor: pipeline_actor(actor))
  end

  @doc """
  Replays one run that a prior reconciliation sweep marked terminal.

  The run keeps its deterministic identity. The reset and its lane's ordinary
  enqueue action share the caller's Account transaction, so the replacement
  job cannot commit without the pending state.
  """
  @spec requeue_terminated(PipelineRun.t(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def requeue_terminated(%PipelineRun{} = run, actor)
      when run.status in ["cancelled", "discarded"] do
    actor = pipeline_actor(actor)

    with {:ok, reset} <-
           run
           |> Ash.Changeset.new()
           |> Ash.Changeset.set_tenant(run.account_id)
           |> Ash.Changeset.for_update(:requeue_terminated, %{})
           |> Ash.update(actor: actor) do
      reenqueue(reset, actor)
    end
  end

  @doc """
  Atomically claims eligible message-extraction runs for one batch owner.

  Only pending or failed runs named by `target_ids` can transition to
  `processing`. The returned records carry `claim_id`; all later per-anchor
  completion and classification calls fence on that exact value. A concurrent
  worker that won first simply removes that anchor from the returned list.
  """
  def claim_extraction_runs(account_id, target_ids, claim_id, actor)
      when is_list(target_ids) and is_binary(claim_id) do
    result =
      PipelineRun
      |> Ash.Query.filter(
        kind == "extraction" and target_type == "message" and target_id in ^target_ids and
          status in ["pending", "failed"]
      )
      |> Ash.Query.set_tenant(account_id)
      |> Ash.bulk_update!(:claim_extraction_batch, %{batch_claim_id: claim_id},
        actor: pipeline_actor(actor),
        return_records?: true,
        strategy: [:atomic]
      )

    {:ok, result.records || []}
  end

  @doc """
  Persists a content-safe failure classification for one claimed batch anchor.

  Returns `{:error, :stale_extraction_claim}` when reconciliation or another
  owner has replaced the claim. In that case no attribute is changed.
  """
  def classify_extraction_run(run, status, error_class, admission_identity, actor)
      when status in ["failed", "repairable", "terminal"] and
             not is_nil(run.batch_claim_id) do
    fenced_extraction_update(
      run,
      :classify_extraction_anchor,
      %{
        status: status,
        attempt_count: run.attempt_count + 1,
        last_error_class: error_class,
        processed_at: if(status == "failed", do: nil, else: Clock.utc_now()),
        payload: Map.put(run.payload || %{}, "admission_identity", admission_identity)
      },
      actor
    )
  end

  @doc """
  Completes one claimed batch anchor under its exact claim fence.

  Returns `{:error, :stale_extraction_claim}` when the run is no longer
  processing under the supplied claim. This expected race never clears or
  overwrites the current owner's replacement claim.
  """
  def complete_extraction_run(run, admission_identity, actor)
      when not is_nil(run.batch_claim_id) do
    fenced_extraction_update(
      run,
      :complete_extraction_anchor,
      %{
        attempt_count: run.attempt_count + 1,
        processed_at: Clock.utc_now(),
        payload: Map.put(run.payload || %{}, "admission_identity", admission_identity)
      },
      actor
    )
  end

  defp fenced_extraction_update(run, action, attrs, actor) do
    result =
      PipelineRun
      |> Ash.Query.filter(
        id == ^run.id and status == "processing" and batch_claim_id == ^run.batch_claim_id
      )
      |> Ash.Query.set_tenant(run.account_id)
      |> Ash.bulk_update!(action, attrs,
        actor: pipeline_actor(actor),
        return_records?: true,
        strategy: [:atomic]
      )

    case result.records || [] do
      [updated] -> {:ok, updated}
      [] -> {:error, :stale_extraction_claim}
    end
  end

  @doc "Explicitly requeues a repairable or terminal message extraction."
  def request_extraction_requeue(%Actor{} = actor, message_id) do
    DataLayer.with_actor(actor, fn account, scoped_actor ->
      pipeline_actor = pipeline_actor(scoped_actor)

      run =
        PipelineRun
        |> Ash.Query.filter(
          kind == "extraction" and target_type == "message" and target_id == ^message_id
        )
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline_actor)

      cond do
        is_nil(run) ->
          {:error, :not_found}

        run.status in ["repairable", "terminal"] ->
          with {:ok, reset} <-
                 run
                 |> Ash.Changeset.for_update(:requeue_extraction_anchor, %{})
                 |> Ash.Changeset.set_tenant(account.id)
                 |> Ash.update(actor: pipeline_actor) do
            enqueue(
              reset.kind,
              reset.account_id,
              %{
                scope_id: reset.scope_id,
                target_type: reset.target_type,
                target_id: reset.target_id,
                idempotency_key: reset.idempotency_key,
                payload: reset.payload
              },
              pipeline_actor
            )
          end

        true ->
          {:error, :not_repairable}
      end
    end)
  end

  @doc "Returns this Account's durable Oban schedule for a replay key, or `:error` when absent."
  def scheduled_at(
        %Account{id: account_id},
        %Actor{account_id: account_id},
        idempotency_key
      )
      when is_binary(idempotency_key) do
    case Store.oban_job_scheduled_at(account_id, idempotency_key) do
      nil -> :error
      scheduled_at -> {:ok, scheduled_at}
    end
  end

  @doc """
  Reports whether a message still has extraction work that reconciliation may replay.

  Pending, failed, and actively claimed runs are replayable. Terminal operator
  outcomes are deliberately excluded until an explicit requeue resets them.
  """
  def extraction_replayable?(account_id, message_id, actor) do
    PipelineRun
    |> Ash.Query.filter(
      kind == "extraction" and target_type == "message" and target_id == ^message_id and
        status in ["pending", "failed", "processing"]
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.exists?(actor: pipeline_actor(actor))
  end

  @doc """
  Reports whether message extraction ended in an operator-visible terminal state.

  Repairable and terminal outcomes require an explicit requeue. Missing,
  completed, pending, failed, and processing rows do not block reconciliation
  from idempotently offering an unstamped message again.
  """
  def extraction_terminal?(account_id, message_id, actor) do
    PipelineRun
    |> Ash.Query.filter(
      kind == "extraction" and target_type == "message" and target_id == ^message_id and
        status in ["repairable", "terminal"]
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.exists?(actor: pipeline_actor(actor))
  end

  @doc """
  Reports whether a scope already has durable projection-refresh work that
  reconciliation can recover.

  Pending, failed, and processing runs may still finish through their existing
  job. Cancelled and discarded runs remain recoverable by the reconciler's
  terminal replay pass. Completed runs are excluded: if the source corpus is
  still stale after completion, a new corpus watermark must schedule new work.
  """
  def projection_refresh_recoverable?(account_id, scope_id, actor) do
    PipelineRun
    |> Ash.Query.filter(
      kind == "projection_refresh" and target_type == "scope" and target_id == ^scope_id and
        status in ["pending", "failed", "processing", "cancelled", "discarded"]
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.exists?(actor: pipeline_actor(actor))
  end

  @doc "Returns the latest durable maintenance contract for a scope, or full legacy behavior."
  @spec maintenance_plan_for_scope(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: map()
  def maintenance_plan_for_scope(account_id, scope_id, actor) do
    run =
      PipelineRun
      |> Ash.Query.filter(
        kind == "projection_refresh" and target_type == "scope" and target_id == ^scope_id
      )
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: pipeline_actor(actor))

    MaintenancePlan.from_payload(if(run, do: run.payload, else: %{}))
  end

  @doc """
  Generic enqueue for a named lane.

  `kind` must be one of the known lane names; an unknown lane raises
  `KeyError`, because silently dropping work would be worse than crashing the
  caller's transaction. `attrs` must include a deterministic `idempotency_key`
  and may include `scope_id`, `target_type`, `target_id`, and a content-free
  `payload`.

  `account_id` sets the tenant explicitly. A system-pipeline copy of the actor satisfies the
  internal write policy.

  Returns `{:ok, run}` or `{:error, reason}`. Failure leaves no orphaned job.
  """
  @spec enqueue(String.t(), Ecto.UUID.t(), map(), map()) ::
          {:ok, PipelineRun.t()} | {:error, term()}
  def enqueue(kind, account_id, attrs, actor)
      when is_binary(kind) and is_binary(account_id) and is_map(attrs) do
    action = Map.fetch!(@enqueue_actions, kind)
    actor = pipeline_actor(actor)

    PipelineRun
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{memhouse_actor: actor})
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create(actor: actor)
  end

  @doc """
  Runs the workflow for a durable run row.

  Selects and executes the lane workflow. Unknown lanes use maintenance so older queued rows can
  complete after an upgrade.

  Execution is deliberately synchronous (`async? false`), so every step runs in
  the job's own process. Account isolation comes from transaction-local
  PostgreSQL settings that each lane installs when it opens its own
  Account-scoped transaction; a step running in another process would be on a
  different connection, outside that transaction, and would lose the scoping.

  Returns `{:ok, result}` or `{:error, reason}`. Errors remain retryable; lanes are replay-safe.
  """
  @spec execute(PipelineRun.t()) :: {:ok, term()} | {:error, term()}
  def execute(%PipelineRun{kind: kind} = run) do
    reactor =
      case kind do
        "extraction" -> MemHouse.Pipeline.Workflows.IngestExtraction
        "dream_time" -> MemHouse.Pipeline.Workflows.DreamTimeReasoning
        "entity_resolution" -> MemHouse.Pipeline.Workflows.DreamTimeReasoning
        "projection_refresh" -> MemHouse.Pipeline.Workflows.DreamTimeReasoning
        "validation_continuation" -> MemHouse.Pipeline.Workflows.ValidationContinuation
        "answer_correlation" -> MemHouse.Pipeline.Workflows.AnswerCorrelationContinuation
        "connector_sync" -> MemHouse.Pipeline.Workflows.Maintenance
        _other -> MemHouse.Pipeline.Workflows.Maintenance
      end

    Reactor.run(reactor, %{pipeline_run: run}, %{}, async?: false)
  end

  @doc """
  Builds the extra arguments copied onto a background job.

  Deliberately minimal: the replay key and the lane name, nothing else. Job
  arguments are durable and visible to anyone inspecting the queue, so content,
  payloads, and secrets must never be added here. Everything a lane needs is
  read from the run row at execution time.
  """
  @spec job_args(PipelineRun.t()) :: map()
  def job_args(run) do
    %{
      "idempotency_key" => run.idempotency_key,
      "pipeline_kind" => run.kind
    }
  end

  # Both clauses build a copy. Enqueueing is an internal capability, so the run
  # resource only admits the `:system` role or the pipeline flag; the caller's
  # own role is never mutated, and the copy keeps the caller's `account_id`,
  # which the run's policy still compares against the row.
  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  defp pipeline_actor(actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end

  defp reenqueue(
         %PipelineRun{kind: "dream_time", payload: %{"mode" => "idle_scope"}} = run,
         actor
       ) do
    with {:ok, activity_at, activity_id} <- idle_activity(run.payload) do
      enqueue_idle_dream_time(run.account_id, run.scope_id, activity_at, activity_id, actor)
    end
  end

  defp reenqueue(run, actor) do
    enqueue(
      run.kind,
      run.account_id,
      %{
        scope_id: run.scope_id,
        target_type: run.target_type,
        target_id: run.target_id,
        idempotency_key: run.idempotency_key,
        payload: run.payload
      },
      actor
    )
  end

  defp idle_activity(%{"activity_at" => value, "activity_id" => activity_id})
       when is_binary(value) and is_binary(activity_id) do
    with {:ok, activity_at, 0} <- DateTime.from_iso8601(value),
         {:ok, activity_id} <- Ecto.UUID.cast(activity_id) do
      {:ok, activity_at, activity_id}
    else
      _error -> {:error, :invalid_idle_dream_payload}
    end
  end

  defp idle_activity(_payload), do: {:error, :invalid_idle_dream_payload}

  defp dream_idle_seconds! do
    :memhouse
    |> Application.fetch_env!(:dream_time_gates)
    |> Keyword.fetch!(:idle_seconds)
  end
end
