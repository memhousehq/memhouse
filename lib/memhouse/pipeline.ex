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

  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline.Idempotency

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

  Re-enqueues durable observations that did not finish. Equal watermarks share a run; `nil` uses
  the current time and creates distinct work. Pass a watermark to coalesce callers.

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
  Schedules the time-driven lifecycle work for one Account and Cron slot.

  `scheduled_at` is the Cron job's scheduled time. It is part of all replay
  keys, so delayed execution and retries reuse the same dream-time, expiry,
  and revalidation runs. Call inside an Account
  transaction; all run rows and jobs then commit together.

  Returns `{:ok, %{dream_time: run, revalidation: run, expiry: run}}` or an error.
  """
  @spec enqueue_lifecycle_sweeps(Ecto.UUID.t(), map(), DateTime.t()) ::
          {:ok,
           %{dream_time: PipelineRun.t(), revalidation: PipelineRun.t(), expiry: PipelineRun.t()}}
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
           ) do
      {:ok, %{dream_time: dream_time, revalidation: revalidation, expiry: expiry}}
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
end
