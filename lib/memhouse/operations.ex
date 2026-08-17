# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations do
  @moduledoc """
  Ash domain for durable usage and pipeline execution records.

  Operational rows are content-safe: they may contain ids, counts, timings, versions, and error
  classes, never memory content, document bytes, prompts, credentials, cursors, or secrets.
  """

  use Ash.Domain

  resources do
    resource MemHouse.Operations.UsageEvent
    resource MemHouse.Operations.DreamTimeWatermark
    resource MemHouse.Operations.PipelineRun
  end
end

defmodule MemHouse.Operations.UsageEvent do
  @moduledoc """
  Retained ledger for HTTP and model usage.

  This table is authoritative; ETS budget counters are rebuildable. Writers store exact counts
  and reviewed content-safe metadata with complete model provenance. Only internal actors write
  events, while Account administrators may read summaries.
  """

  use MemHouse.Resource, domain: MemHouse.Operations, table: "usage_events"

  # Rows belong to exactly one Account. Attribute multitenancy makes the tenant
  # a required part of every read and write, so a caller that forgets to set it
  # gets an error rather than another Account's usage.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    destroy :prune do
      require_atomic? false
    end

    create :record do
      accept [
        :call_id,
        :scope_id,
        :peer_id,
        :operation,
        :model_role,
        :provider,
        :model_name,
        :model_version,
        :prompt_version,
        :pipeline_version,
        :input_tokens,
        :output_tokens,
        :embedding_tokens,
        :duration_ms,
        :status,
        :metadata,
        :occurred_at
      ]

      # Exactly two outcomes are meaningful for cost and error-rate reporting.
      # Anything finer belongs in the metadata allowlist, not in this column,
      # because summaries group on it.
      validate attribute_in(:status, ~w(ok error))
    end
  end

  policies do
    # Applies to every action, including reads: an actor only ever sees rows
    # belonging to its own Account.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Writing the ledger is internal. External callers cause rows to appear by
    # making requests, but must never author one directly — a caller that could
    # write its own usage rows could understate what it consumed.
    policy action(:record) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:prune) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Totals span the whole Account rather than one scope, so reading them is an
    # administrator capability; ordinary members and readers get nothing.
    policy action_type(:read) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id

    # Tenant column. Not public: it is derived from the authenticated identity,
    # never accepted from a request.
    attribute :account_id, :uuid, allow_nil?: false

    # Caller-generated id for one emission. The identity below turns an
    # accidental double emission into a constraint error instead of a silent
    # double charge.
    attribute :call_id, :uuid, allow_nil?: false, public?: true

    # Both nullable: not every metered call happens inside a scope, and internal
    # work has no calling peer.
    attribute :scope_id, :uuid
    attribute :peer_id, :uuid

    # Coarse operation name such as "api.ingest" or a model operation. Keep the
    # cardinality bounded and free of record ids; this column is grouped on and
    # is visible to operators.
    attribute :operation, :string, allow_nil?: false, public?: true
    # Full model provenance, so a recorded cost can always be attributed to the
    # exact configuration that produced it. Non-model rows carry placeholders
    # rather than nulls.
    attribute :model_role, :string, allow_nil?: false, public?: true
    attribute :provider, :string, allow_nil?: false, public?: true
    attribute :model_name, :string, allow_nil?: false, public?: true
    attribute :model_version, :string, allow_nil?: false, public?: true
    attribute :prompt_version, :string, allow_nil?: false, public?: true
    attribute :pipeline_version, :string, allow_nil?: false, public?: true

    # Token counts default to zero so that rows for non-model work still sum
    # cleanly alongside model rows.
    attribute :input_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :output_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :embedding_tokens, :integer, allow_nil?: false, default: 0, public?: true
    attribute :duration_ms, :integer, allow_nil?: false, default: 0, public?: true

    attribute :status, :string, allow_nil?: false, default: "ok", public?: true

    # Not public. Writers pass only allowlisted, content-free keys (counts,
    # error classes, HTTP status); everything else is dropped before it arrives.
    attribute :metadata, :map, allow_nil?: false, default: %{}

    # When the metered call happened, supplied by the writer. Distinct from the
    # insert timestamp, which is only when the row landed in the table.
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  identities do
    # Backed by a unique index. Because the resource is tenant-scoped, the index
    # covers (account_id, call_id): a retry that reuses a call id within the
    # Account is rejected rather than counted twice.
    identity :call_id, [:call_id]
  end
end

defmodule MemHouse.Operations.DreamTimeWatermark do
  @moduledoc """
  Durable per-scope progress for incremental dream-time reasoning.

  The watermark advances only in the transaction that applies a completed
  reasoning pass. It is operational state, not a cache: losing it could skip
  governed knowledge during a later pass.
  """

  use MemHouse.Resource, domain: MemHouse.Operations, table: "dream_time_watermarks"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :start do
      accept [:scope_id, :input_watermark, :input_watermark_id]
      upsert? true
      upsert_identity :scope
      upsert_fields [:input_watermark, :input_watermark_id, :updated_at]
    end

    update :advance do
      accept [:input_watermark, :input_watermark_id]
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update]) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :input_watermark, :utc_datetime_usec, allow_nil?: false
    # Completes the cursor when several rows share one timestamp. Without the
    # id tie-break a bounded pass could skip same-microsecond rows forever.
    attribute :input_watermark_id, :uuid
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :scope, [:scope_id]
  end
end

defmodule MemHouse.Operations.PipelineRun do
  @moduledoc """
  Durable state and idempotency record for one pipeline unit.

  Source creation, audit, run creation, and AshOban enqueue commit together. Replay keys prevent
  duplicate work, job arguments remain content-free, and stalled durable sources retain a
  reconciler path.
  """

  use MemHouse.Resource,
    domain: MemHouse.Operations,
    table: "pipeline_runs",
    extensions: [AshOban]

  import AshOban.Changes.BuiltinChanges

  # Runs belong to exactly one Account, and the background job inherits that
  # tenant from the record, so executing work can never cross Accounts.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    # Keyset pagination is not optional here: AshOban streams the trigger's
    # read action, and it refuses at compile time to use one without it.
    read :read do
      primary? true

      pagination do
        keyset? true
      end
    end

    # The read every background job performs on itself, and the only read that
    # runs with nothing upstream having declared an Account to the database.
    #
    # A job starts by reading its own run row back to confirm the work is still
    # outstanding. That read lands on a pooled connection no request ever
    # touched, and this table's row-level security policy hides every row until
    # a transaction declares which Account is acting. Undeclared, the read
    # returns nothing, the job runner reads that as its trigger no longer
    # applying, and it cancels itself while the work stays undone and invisible.
    #
    # The transaction and the preparation are one mechanism: the preparation
    # declares the Account, and the transaction is what makes that declaration
    # last beyond the statement that installs it. Every trigger points its
    # worker at this action rather than at the primary read, which stays as it
    # was for callers that already hold an Account-scoped transaction.
    read :for_trigger do
      transaction? true

      prepare MemHouse.Pipeline.Preparations.DeclareAccount
    end

    # A caller may inspect only the extraction run for a message whose scope it
    # can already read. This keeps queue enumeration operator-only while making
    # an accepted asynchronous ingest observable to its submitter.
    read :ingest_status do
      argument :message_id, :uuid, allow_nil?: false

      filter expr(
               kind == "extraction" and target_type == "message" and
                 target_id == ^arg(:message_id)
             )
    end

    # One enqueue action per lane. They are identical apart from the lane name
    # they stamp and the trigger they fire, and each one follows the same
    # pattern: upsert on the deterministic replay key, rewrite nothing but that
    # key on conflict, then insert the job in the same transaction. Adding a
    # lane means repeating the pattern exactly, self-referential upsert set and
    # all.
    create :enqueue_extraction do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      # Deliberately a no-op update: re-enqueueing must not disturb the state of
      # a run that already exists.
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "extraction")
      change run_oban_trigger(:extraction)
    end

    create :enqueue_dream_time do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "dream_time")
      change run_oban_trigger(:dream_time)
    end

    create :enqueue_revalidation do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "revalidation")
      change run_oban_trigger(:revalidation)
    end

    create :enqueue_expiry do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "expiry")
      change run_oban_trigger(:expiry)
    end

    create :enqueue_projection_refresh do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "projection_refresh")

      # The delay exceeds the ten-second bucket, so execution starts only after the bucket closes.
      change run_oban_trigger(:projection_refresh, schedule_in: 15)
    end

    create :enqueue_connector_sync do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "connector_sync")
      change run_oban_trigger(:connector_sync)
    end

    create :enqueue_import_rebuild do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "import_rebuild")
      change run_oban_trigger(:import_rebuild)
    end

    create :enqueue_reconciler do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "reconciler")
      change run_oban_trigger(:reconciler)
    end

    create :enqueue_entity_resolution do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "entity_resolution")
      change run_oban_trigger(:entity_resolution)
    end

    create :enqueue_reembed do
      accept [:target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "reembed")
      change run_oban_trigger(:reembed)
    end

    update :record_reembed_progress do
      accept [:payload]
      require_atomic? false
    end

    create :enqueue_validation_continuation do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "validation_continuation")
      change run_oban_trigger(:validation_continuation)
    end

    create :enqueue_answer_correlation do
      accept [:scope_id, :target_type, :target_id, :idempotency_key, :payload]
      upsert? true
      upsert_identity :idempotency_key
      upsert_fields [:idempotency_key]
      change set_attribute(:kind, "answer_correlation")
      change run_oban_trigger(:answer_correlation)
    end

    # The job body. It runs the lane's workflow and then records the outcome on
    # this row.
    #
    # The workflow must not run inside this transaction: lanes open and commit
    # their own (raw writes, governance decisions, projection rebuilds), and
    # holding one long-lived transaction across all of them would keep locks for
    # the entire duration of the work. That separation is now enforced by *when*
    # the workflow runs rather than by having no transaction at all — the change
    # below runs it in a before-transaction hook, leaving this transaction to
    # cover only the short status write.
    #
    # That transaction is required. The write lands on a connection with no
    # Account declared, and the row-level security policy on this table refuses
    # a write it cannot match; PostgreSQL then reports zero rows changed and Ash
    # raises a stale-record error, which the job runner reads as the trigger no
    # longer applying. Completed work would be recorded as never having run.
    update :execute do
      require_atomic? false
      change MemHouse.Pipeline.Changes.DeclareAccount
      change MemHouse.Pipeline.Changes.ExecuteRun
    end

    # A running extraction job marks its own replay row before looking for
    # siblings. Opportunistic batch claims use the same action over a filtered
    # query, so an executing sibling and a batch owner race on one atomic status
    # transition and exactly one wins.
    update :claim_extraction_batch do
      accept [:batch_claim_id]
      change set_attribute(:status, "processing")
      change set_attribute(:last_error_class, nil)
    end

    # Called inside the same short Account transaction that persists one
    # anchor's governed candidates and message completion stamp.
    update :complete_extraction_anchor do
      accept [:attempt_count, :processed_at, :payload]
      change set_attribute(:status, "completed")
      change set_attribute(:last_error_class, nil)
      change set_attribute(:batch_claim_id, nil)
    end

    update :classify_extraction_anchor do
      accept [:status, :attempt_count, :last_error_class, :processed_at, :payload]
      validate attribute_in(:status, ~w(failed repairable terminal))
      change set_attribute(:batch_claim_id, nil)
    end

    update :requeue_extraction_anchor do
      require_atomic? false
      accept [:payload]

      validate {MemHouse.Operations.Validations.CurrentStatusIn,
                statuses: ~w(repairable terminal)}

      change set_attribute(:status, "pending")
      change set_attribute(:last_error_class, nil)
      change set_attribute(:processed_at, nil)
      change set_attribute(:batch_claim_id, nil)
    end

    update :expire_extraction_claim do
      change set_attribute(:status, "failed")
      change set_attribute(:last_error_class, "BatchClaimExpired")
      change set_attribute(:processed_at, nil)
      change set_attribute(:batch_claim_id, nil)
    end

    # Failure path invoked when the job errors. It stores only a classification
    # of the error and bumps the attempt count, leaving the row eligible for a
    # later retry or reconciliation sweep. It carries the same Account
    # declaration as `:execute`, and for the same reason: it runs from the job
    # runner's error handler, where nothing has declared one.
    update :mark_failed do
      argument :error, :term, allow_nil?: false
      require_atomic? false
      change MemHouse.Pipeline.Changes.DeclareAccount
      change MemHouse.Pipeline.Changes.MarkRunFailed
    end

    # Reconciliation records an Oban terminal state before it attempts replay
    # in a later sweep. The reason is a fixed content-safe classification.
    update :mark_terminated do
      accept [:status, :last_error_class, :processed_at]
      require_atomic? false
      validate attribute_in(:status, ~w(cancelled discarded))
      validate {MemHouse.Operations.Validations.CurrentStatusIn, statuses: ~w(pending failed)}
    end

    # The reconciler follows this reset with the lane's ordinary enqueue action
    # in the same Account transaction. The create action owns its one trigger.
    update :requeue_terminated do
      require_atomic? false

      validate {MemHouse.Operations.Validations.CurrentStatusIn,
                statuses: ~w(cancelled discarded)}

      change set_attribute(:status, "pending")
      change set_attribute(:last_error_class, nil)
      change set_attribute(:processed_at, nil)
    end

    destroy :prune do
      require_atomic? false
    end
  end

  policies do
    # Background jobs execute outside any request and therefore carry no
    # authenticated actor. The bypass admits the job runner itself; the tenant
    # still comes from the record, so this widens who may act, not on what.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Enqueueing and completing runs is internal only. An external caller must
    # never be able to schedule, replay, or mark pipeline work.
    policy action_type([:create, :update, :destroy]) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Reading queue state is an operator or internal capability; ordinary
    # members and readers cannot enumerate what an Account is processing.
    policy action([:read, :for_trigger]) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:ingest_status) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end
  end

  oban do
    # The executing job adopts the Account of the row it processes, so tenancy
    # survives the hop from request to background worker.
    use_tenant_from_record?(true)
    shared_context([:job])

    # One trigger per lane. Related lanes share a queue — revalidation and
    # expiry on `:lifecycle`, projection refresh and entity resolution on
    # `:projection`, validation continuation and answer correlation on
    # `:governance` — so a queue's concurrency is shared by the lanes on it.
    # Every trigger repeats the same contract:
    #
    #   * `where` claims only rows of its own lane that are pending or failed,
    #     so a completed run is never re-executed.
    #   * `worker_read_action(:for_trigger)` is what lets the job find its own
    #     row at all. The job runner reads that row before any MemHouse code
    #     runs, on a connection with no Account declared, and this table's
    #     row-level security policy hides every row until one is. Left on the
    #     primary read, the job would see nothing, decide its trigger no longer
    #     applies, and cancel itself with the work undone.
    #   * `scheduler_cron(false)` means no polling scheduler; work is inserted
    #     by the enqueue action, in the caller's transaction.
    #   * `trigger_once?(true)` adds completed to the job's uniqueness states,
    #     so a row whose job is queued, running, or already finished does not
    #     get a second job.
    #   * `max_attempts(5)` bounds retries; after the last attempt Oban
    #     discards the job rather than retrying forever, and the row is left in
    #     whatever state `on_error` recorded.
    #   * `on_error(:mark_failed)` records the error class on the row.
    #   * `extra_args` copies only the replay key and lane name into the job,
    #     keeping content out of Oban's durable arguments.
    triggers do
      trigger :extraction do
        action :execute
        where expr(kind == "extraction" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:ingest)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.Extraction)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.Extraction)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :dream_time do
        action :execute
        where expr(kind == "dream_time" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:dream)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.DreamTime)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.DreamTime)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :revalidation do
        action :execute
        where expr(kind == "revalidation" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:lifecycle)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.Revalidation)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.Revalidation)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :expiry do
        action :execute
        where expr(kind == "expiry" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:lifecycle)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.Expiry)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.Expiry)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :projection_refresh do
        action :execute
        where expr(kind == "projection_refresh" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:projection)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.ProjectionRefresh)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.ProjectionRefresh)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :connector_sync do
        action :execute
        where expr(kind == "connector_sync" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:connector)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.ConnectorSync)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.ConnectorSync)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :import_rebuild do
        action :execute
        where expr(kind == "import_rebuild" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:portability)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.ImportRebuild)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.ImportRebuild)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :reconciler do
        action :execute
        where expr(kind == "reconciler" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:reconciler)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.Reconciler)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.Reconciler)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :entity_resolution do
        action :execute
        where expr(kind == "entity_resolution" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:projection)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.EntityResolution)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.EntityResolution)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :reembed do
        action :execute
        where expr(kind == "reembed" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:projection)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.Reembed)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.Reembed)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :validation_continuation do
        action :execute
        where expr(kind == "validation_continuation" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:governance)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.ValidationContinuation)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.ValidationContinuation)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end

      trigger :answer_correlation do
        action :execute
        where expr(kind == "answer_correlation" and status in ["pending", "failed"])
        worker_read_action(:for_trigger)
        queue(:governance)
        scheduler_cron(false)
        max_attempts(5)
        trigger_once?(true)
        on_error(:mark_failed)
        worker_module_name(MemHouse.Pipeline.Workers.AnswerCorrelation)
        scheduler_module_name(MemHouse.Pipeline.Schedulers.AnswerCorrelation)
        extra_args(&MemHouse.Pipeline.job_args/1)
      end
    end
  end

  attributes do
    uuid_primary_key :id

    # Tenant column, derived from the record that caused the work.
    attribute :account_id, :uuid, allow_nil?: false

    # Nullable: Account-wide lanes such as reconciliation have no single scope.
    attribute :scope_id, :uuid

    # Lane name. Set by the enqueue action rather than accepted from the caller,
    # so a run can never be filed under a lane it will not be executed by.
    attribute :kind, :string, allow_nil?: false, public?: true

    # What the run operates on: the kind of record and its id.
    attribute :target_type, :string, allow_nil?: false, public?: true
    attribute :target_id, :uuid

    # The deterministic replay key. Recomputing it from the same immutable
    # source identity must yield the same string, or replay protection breaks.
    attribute :idempotency_key, :string, allow_nil?: false, public?: true

    # Replay hints only — hashes and watermarks. Never content, never cursors.
    attribute :payload, :map, allow_nil?: false, default: %{}

    attribute :status, :string, allow_nil?: false, default: "pending", public?: true
    attribute :attempt_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :processed_at, :utc_datetime_usec, public?: true

    # A classification such as an exception module name, never a message.
    # Error messages routinely quote the content that caused them.
    attribute :last_error_class, :string, public?: true

    # Fences late workers after reconciliation expires and reclaims a batch.
    # It is operational identity only and never leaves operator/internal APIs.
    attribute :batch_claim_id, :uuid

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Backed by a unique index over (account_id, idempotency_key), since the
    # resource is tenant-scoped. This constraint is the replay guarantee: two
    # concurrent enqueues of the same work resolve to one row.
    identity :idempotency_key, [:idempotency_key]
  end
end

defmodule MemHouse.Operations.Validations.CurrentStatusIn do
  @moduledoc """
  Validates that a PipelineRun's current status is in an allowed set.

  Guards state transitions by checking the pre-update status value.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, opts, _context) do
    allowed_statuses = Keyword.fetch!(opts, :statuses)
    current_status = changeset.data.status

    if current_status in allowed_statuses do
      :ok
    else
      {:error,
       field: :status,
       message:
         "current status must be one of #{inspect(allowed_statuses)}, " <>
           "got #{inspect(current_status)}"}
    end
  end
end
