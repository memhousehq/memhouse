# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule VanishingSubjectProvider do
  @moduledoc """
  Test model provider that deliberately invalidates the write following its answer.

  The failure reveals whether the model call incorrectly shares the subsequent database
  transaction. It is test-only and mutates the fixture peer solely to force that write error.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Repo

  # The peer key `ingest_attrs/3` derives for the Account key `f2-metered-failure`, and the
  # name it is moved to. Both are literals rather than parameters because the provider
  # behaviour gives a provider no way to receive test-specific configuration.
  @subject_key "f2-metered-failure-peer"
  @moved_key "f2-metered-failure-peer-moved"

  @doc """
  Answers one extraction and renames its subject peer, so the write that follows raises.

  Returns a `Result` whose value is a single schema-valid candidate, with token counts set so
  the usage row this call produces is recognisable.
  """
  @impl true
  def structured(_config, _messages, _schema, _opts) do
    Ecto.Adapters.SQL.query!(Repo, "UPDATE peers SET key = $1 WHERE key = $2", [
      @moved_key,
      @subject_key
    ])

    {:ok,
     %Result{
       value: %{
         "items" => [
           %{
             "supporting_span" => "Avery prefers concise weekly release summaries.",
             "statement" => "Avery prefers concise weekly release summaries.",
             "kind" => "preference",
             "subject_type" => "peer",
             "subject_ref" => @subject_key,
             "confidence_level" => "stated_explicitly",
             "sensitivity" => "internal",
             "target_level" => "peer"
           }
         ]
       },
       usage: %{input_tokens: 11, output_tokens: 4},
       metadata: %{}
     }}
  end

  @doc "Unused capability; returns an error so an unexpected call fails the test."
  @impl true
  def chat(_config, _messages, _opts), do: {:error, :not_implemented}

  @doc "Unused capability; returns an error so an unexpected call fails the test."
  @impl true
  def embed(_config, _texts, _opts), do: {:error, :not_implemented}

  @doc "Unused capability; returns an error so an unexpected call fails the test."
  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :not_implemented}
end

defmodule ReclaimingBatchProvider do
  @moduledoc """
  Test provider that pauses one batch after its claims commit but before effects persist.

  The test process uses that gap to expire and replace one claim. Delegating the
  response to the deterministic provider keeps the returned batch schema-valid
  without any network or model call.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Providers.Deterministic

  @doc "Pauses the batch until the owning test selects a deterministic or error response."
  @impl true
  def structured(config, messages, schema, opts) do
    controller = Application.fetch_env!(:memhouse, :reclaiming_batch_test_controller)
    anchor_ids = Enum.map(Keyword.fetch!(opts, :batch_observations), & &1.anchor_id)

    send(controller, {:batch_claims_ready, self(), anchor_ids})

    receive do
      :persist_batch_results -> Deterministic.structured(config, messages, schema, opts)
      {:return_batch_result, result} -> result
    after
      5_000 -> {:error, :batch_reclaim_test_timeout}
    end
  end

  @doc "Delegates unused chat calls to the offline deterministic provider."
  @impl true
  defdelegate chat(config, messages, opts), to: Deterministic

  @doc "Delegates unused embedding calls to the offline deterministic provider."
  @impl true
  defdelegate embed(config, texts, opts), to: Deterministic

  @doc "Delegates unused reranking calls to the offline deterministic provider."
  @impl true
  defdelegate rerank(config, query, documents, opts), to: Deterministic
end

defmodule MemHouse.F2TransactionalWritesAuditJobsTest do
  @moduledoc """
  Pins the coupling between a durable write, its audit entry, its processing record,
    and its background job: either all four exist or none of them do.

    One transaction, four effects.
  """

  use MemHouse.DataCase, async: false

  import ExUnit.CaptureLog

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Audit
  alias MemHouse.Governance.AuditEvent
  alias MemHouse.Memory
  alias MemHouse.Observations.Message
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.Changes.ExecuteRun
  alias MemHouse.Pipeline.Idempotency
  alias MemHouse.Pipeline.Reconciler

  require Ash.Query

  # Clears every credential a provider could pick up, so nothing here can reach a network
  # endpoint. The provider-outage test below deliberately writes a broken configuration back.
  # Both values are global to the node, so this module is not async and both are restored
  # afterwards.
  setup do
    original_api_key = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:memhouse, :models)

    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:memhouse, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      if original_api_key do
        System.put_env("OPENROUTER_API_KEY", original_api_key)
      else
        System.delete_env("OPENROUTER_API_KEY")
      end

      Application.put_env(:memhouse, :models, original_models)
    end)

    :ok
  end

  test "raw observation, audit, extraction, and coalesced source refresh commit together" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-commit", "commit-session"))

    account_id = account_id!("f2-commit")

    # One query with sub-selects, deliberately: it observes the observation row, the audit
    # event, and both durable run/job pairs at a single point in time. Separate queries could
    # each pass against a half-committed state.
    #
    # The job is matched on the Account tenant and the lane name in its arguments, because the
    # test has no handle on the job id. Job arguments hold ids, a replay key, and a lane name;
    # no content and no secret may be placed there, since anyone who can read the queue table
    # can read them.
    assert %{
             rows: [
               [
                 "message.ingested",
                 content_hash,
                 message_count,
                 extraction_run_count,
                 extraction_job_count,
                 refresh_run_count,
                 refresh_job_count
               ]
             ]
           } =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT audit.action,
                      audit.content_hash,
                      (SELECT count(*) FROM messages WHERE id = $1),
                      (SELECT count(*) FROM pipeline_runs
                       WHERE target_id = $1 AND kind = 'extraction'),
                      (SELECT count(*) FROM oban_jobs
                       WHERE args->>'tenant' = $2
                         AND args->>'pipeline_kind' = 'extraction'),
                      (SELECT count(*) FROM pipeline_runs
                       WHERE target_id = $3 AND kind = 'projection_refresh'),
                      (SELECT count(*) FROM oban_jobs
                       WHERE args->>'tenant' = $2
                         AND args->>'pipeline_kind' = 'projection_refresh')
               FROM audit_events AS audit
               WHERE audit.resource_id = $1
               """,
               [
                 Ecto.UUID.dump!(message["id"]),
                 account_id,
                 Ecto.UUID.dump!(message["scope_id"])
               ]
             )

    # The audit event points at the content by digest. Recomputing the digest from the stored
    # message proves the reference is real without the audit row ever holding the text.
    assert content_hash == Idempotency.content_hash(message["content"])
    assert message_count == 1
    assert extraction_run_count == 1
    assert extraction_job_count == 1
    assert refresh_run_count == 1
    assert refresh_job_count == 1

    # Ingest does not schedule an Account-wide sweep. The hourly maintenance
    # scheduler owns reconciliation, so request volume cannot flood its serial queue.
    assert scalar!(
             """
             SELECT count(*) FROM pipeline_runs
             WHERE account_id = $1 AND kind = 'reconciler'
             """,
             [Ecto.UUID.dump!(account_id)]
           ) == 0
  end

  test "forced failure after audit and enqueue rolls back raw write, audit, run, and job" do
    assert {:ok, _seed} =
             Memory.ingest_message(ingest_attrs("f2-rollback", "seed-session"))

    # Snapshot of message, audit, processing-record, and job counts taken before the doomed
    # write. The seed ingest above exists so these counts start non-zero and a rollback that
    # wiped everything would also be caught.
    before = account_counts("f2-rollback")
    {session_id, scope_id, peer_id} = observation_ids!("f2-rollback")

    # The private context flag makes the create fail *after* the audit event and the enqueue
    # have already run inside the transaction — the exact window where a non-transactional
    # implementation would leave an orphaned audit entry and a job for a row that never
    # existed. The flag is reachable only from a changeset's private context, never from
    # request input, and the production code path that honours it is here for this test: do
    # not delete it as dead code.
    assert_raise RuntimeError, ~r/forced F2 rollback/, fn ->
      DataLayer.with_account_key("f2-rollback", fn account, actor ->
        Message
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.set_context(%{
          memhouse_actor: actor,
          private: %{f2_force_rollback?: true}
        })
        |> Ash.Changeset.for_create(:create, %{
          session_id: session_id,
          scope_id: scope_id,
          peer_id: peer_id,
          role: "user",
          content: "This observation must roll back with its audit and job.",
          occurred_at: Clock.utc_now()
        })
        |> Ash.create(actor: actor)
      end)
    end

    # All four counters unchanged. A single one moving means that write escaped the
    # transaction and the four effects are no longer atomic.
    assert account_counts("f2-rollback") == before
  end

  test "reconciliation terminates a cancelled job and replays it on a later sweep" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-cancelled-reaper", "cancelled-session"))

    account_id = account_id!("f2-cancelled-reaper")

    %{rows: [[run_id, replay_key]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        UPDATE pipeline_runs
        SET updated_at = now() - interval '10 minutes'
        WHERE target_id = $1 AND kind = 'extraction'
        RETURNING id, idempotency_key
        """,
        [Ecto.UUID.dump!(message["id"])]
      )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      UPDATE oban_jobs SET state = 'cancelled', cancelled_at = now()
      WHERE args->>'idempotency_key' = $1
      """,
      [replay_key]
    )

    assert {:ok, %{terminated: 1}} = MemHouse.Pipeline.Reconciler.run(account_id)

    assert %{rows: [["cancelled", "ObanJobCancelled"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT status, last_error_class FROM pipeline_runs WHERE id = $1",
               [run_id]
             )

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE pipeline_runs SET updated_at = now() - interval '10 minutes' WHERE id = $1",
      [run_id]
    )

    assert {:ok, %{replayed: 1}} = MemHouse.Pipeline.Reconciler.run(account_id)

    assert %{rows: [["pending", 1]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT run.status,
                      count(job.id) FILTER (WHERE job.state = 'available')
               FROM pipeline_runs AS run
               LEFT JOIN oban_jobs AS job
                 ON job.args->>'idempotency_key' = run.idempotency_key
               WHERE run.id = $1
               GROUP BY run.status
               """,
               [run_id]
             )

    # Oban inserts through its own connection in this test lane, so remove the
    # two test jobs explicitly instead of leaving them for a later drain test.
    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM oban_jobs WHERE args->>'idempotency_key' = $1",
      [replay_key]
    )
  end

  test "AshOban extraction executes the ingest Reactor and marks durable processing complete" do
    # Ingest returns as soon as the observation is durable, leaving the work to the queue, so
    # this test exercises the normal background path.
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-drain", "drain-session"))

    # Runs the queued job in this process. It can see the test's uncommitted rows only because
    # the sandbox connection is shared, which is why this module cannot be async.
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :ingest)

    # Three facts in one row: the observation is marked processed, knowledge was produced from
    # it, and the durable processing record reached `completed`. The completion marker is what
    # keeps the reconciler from picking the message up again forever.
    assert %{rows: [[completed_at, 1, "completed"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT message.extraction_completed_at,
                      (SELECT count(*) FROM knowledge_items
                       WHERE $1 = ANY(source_message_ids)),
                      run.status
               FROM messages AS message
               JOIN pipeline_runs AS run ON run.target_id = message.id
               WHERE message.id = $1 AND run.kind = 'extraction'
               """,
               [Ecto.UUID.dump!(message["id"])]
             )

    assert %NaiveDateTime{} = completed_at
  end

  test "one ingest worker atomically completes adjacent anchors through one provider call" do
    batching = Application.fetch_env!(:memhouse, :extraction_batching)
    Application.put_env(:memhouse, :extraction_batching, Keyword.put(batching, :enabled, true))
    on_exit(fn -> Application.put_env(:memhouse, :extraction_batching, batching) end)

    handler = {__MODULE__, self(), :ingest_batch_operation}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, measurements, metadata, _config ->
          send(parent, {:ingest_batch_operation, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, first} =
             Memory.ingest_message(
               ingest_attrs("f2-batch", "batch-session",
                 content: "Avery owns the release checklist."
               )
             )

    assert {:ok, second} =
             Memory.ingest_message(
               ingest_attrs("f2-batch", "batch-session",
                 content: "Avery prefers concise weekly summaries."
               )
             )

    assert %{failure: 0} = Oban.drain_queue(queue: :ingest)

    assert_receive {:ingest_batch_operation, measurements, metadata}
    assert metadata.operation == "ingest_batch"
    assert metadata.status == "ok"
    assert measurements.anchors == 2
    assert measurements.calls == 1
    assert measurements.failures == 0
    refute inspect({measurements, metadata}) =~ "Avery owns"

    account_id = account_id!("f2-batch")

    assert %{rows: [[2, 2, 1]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*) FILTER (WHERE message.extraction_completed_at IS NOT NULL),
                      count(*) FILTER (WHERE run.status = 'completed'),
                      (SELECT count(*)
                       FROM usage_events
                       WHERE account_id = $1 AND model_role = 'ingest_extractor')
               FROM messages AS message
               JOIN pipeline_runs AS run ON run.target_id = message.id
               WHERE message.id = ANY($2) AND run.kind = 'extraction'
               """,
               [
                 Ecto.UUID.dump!(account_id),
                 [Ecto.UUID.dump!(first["id"]), Ecto.UUID.dump!(second["id"])]
               ]
             )

    assert %{rows: [[2]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(DISTINCT message_id)
               FROM provenances
               WHERE source_type = 'message' AND message_id = ANY($1)
               """,
               [[Ecto.UUID.dump!(first["id"]), Ecto.UUID.dump!(second["id"])]]
             )

    # The drainer updates Oban through its own connection, outside this test's
    # sandbox transaction. Remove both account-local jobs so the cancelled
    # sibling cannot appear in a later queue-count assertion.
    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM oban_jobs WHERE args->>'tenant' = $1",
      [account_id]
    )
  end

  test "default extraction keeps adjacent messages on independent provider calls" do
    refute MemHouse.Pipeline.ExtractionAdmission.enabled?()
    handler = {__MODULE__, self(), :default_single_anchor}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, measurements, metadata, _config ->
          send(parent, {:operation, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, first} =
             Memory.ingest_message(
               ingest_attrs("f2-single-default", "single-session",
                 content: "Avery owns the release checklist."
               )
             )

    assert {:ok, second} =
             Memory.ingest_message(
               ingest_attrs("f2-single-default", "single-session",
                 content: "Avery prefers concise weekly summaries."
               )
             )

    assert %{failure: 0} = Oban.drain_queue(queue: :ingest)

    refute_receive {:operation, _measurements, %{operation: "ingest_batch"}}
    account_id = account_id!("f2-single-default")

    assert %{rows: [[2, 2]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*) FILTER (WHERE run.status = 'completed'),
                      (SELECT count(*)
                       FROM usage_events
                       WHERE account_id = $1 AND model_role = 'ingest_extractor')
               FROM pipeline_runs AS run
               WHERE run.target_id = ANY($2) AND run.kind = 'extraction'
               """,
               [
                 Ecto.UUID.dump!(account_id),
                 [Ecto.UUID.dump!(first["id"]), Ecto.UUID.dump!(second["id"])]
               ]
             )
  end

  test "two workers cannot claim one extraction anchor twice" do
    assert {:ok, first} =
             Memory.ingest_message(ingest_attrs("f2-claim-race", "claim-race-session"))

    assert {:ok, second} =
             Memory.ingest_message(ingest_attrs("f2-claim-race", "claim-race-session"))

    account_id = account_id!("f2-claim-race")
    ids = [first["id"], second["id"]]

    claims =
      1..2
      |> Enum.map(fn _worker ->
        Task.async(fn ->
          DataLayer.with_account_id(
            account_id,
            [role: :system, pipeline?: true],
            fn _account, actor ->
              {:ok, runs} =
                Pipeline.claim_extraction_runs(
                  account_id,
                  ids,
                  Ecto.UUID.generate(),
                  actor
                )

              Enum.map(runs, & &1.target_id)
            end
          )
        end)
      end)
      |> Task.await_many(5_000)

    assert claims |> List.flatten() |> Enum.sort() == Enum.sort(ids)
    assert Enum.count(claims, &(&1 != [])) == 1

    assert %{rows: [[2]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*)
               FROM pipeline_runs
               WHERE target_id = ANY($1) AND status = 'processing'
               """,
               [[Ecto.UUID.dump!(first["id"]), Ecto.UUID.dump!(second["id"])]]
             )
  end

  test "reconciliation releases stale claims but excludes terminal anchors" do
    assert {:ok, retryable} =
             Memory.ingest_message(ingest_attrs("f2-claim-repair", "claim-repair-session"))

    assert {:ok, poison} =
             Memory.ingest_message(ingest_attrs("f2-claim-repair", "claim-repair-session"))

    assert {:ok, operator_repair} =
             Memory.ingest_message(ingest_attrs("f2-claim-repair", "claim-repair-session"))

    account_id = account_id!("f2-claim-repair")

    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        {:ok, runs} =
          Pipeline.claim_extraction_runs(
            account_id,
            [retryable["id"], poison["id"], operator_repair["id"]],
            Ecto.UUID.generate(),
            actor
          )

        poison_run = Enum.find(runs, &(&1.target_id == poison["id"]))
        repairable_run = Enum.find(runs, &(&1.target_id == operator_repair["id"]))

        {:ok, _run} =
          Pipeline.classify_extraction_run(
            poison_run,
            "terminal",
            "structured_validation_exhausted",
            "stale-claim-test",
            actor
          )

        {:ok, _run} =
          Pipeline.classify_extraction_run(
            repairable_run,
            "repairable",
            "provider_output_truncated",
            "stale-claim-test",
            actor
          )
      end
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      UPDATE pipeline_runs
      SET updated_at = now() - interval '30 minutes'
      WHERE target_id = ANY($1)
      """,
      [
        [
          Ecto.UUID.dump!(retryable["id"]),
          Ecto.UUID.dump!(poison["id"]),
          Ecto.UUID.dump!(operator_repair["id"])
        ]
      ]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      UPDATE messages
      SET inserted_at = now() - interval '10 minutes'
      WHERE id = ANY($1)
      """,
      [
        [
          Ecto.UUID.dump!(retryable["id"]),
          Ecto.UUID.dump!(poison["id"]),
          Ecto.UUID.dump!(operator_repair["id"])
        ]
      ]
    )

    assert {:ok, %{expired_claims: 1, messages: 1}} = Reconciler.run(account_id)

    assert %{
             rows: [
               ["failed", "BatchClaimExpired"],
               ["repairable", "provider_output_truncated"],
               ["terminal", terminal_reason]
             ]
           } =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT status, last_error_class
               FROM pipeline_runs
               WHERE target_id = ANY($1)
               ORDER BY status
               """,
               [
                 [
                   Ecto.UUID.dump!(retryable["id"]),
                   Ecto.UUID.dump!(poison["id"]),
                   Ecto.UUID.dump!(operator_repair["id"])
                 ]
               ]
             )

    assert terminal_reason == "structured_validation_exhausted"
  end

  test "an expired late worker cannot commit over a replacement claim" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-claim-fence", "claim-fence-session"))

    account_id = account_id!("f2-claim-fence")
    first_claim_id = Ecto.UUID.generate()

    stale_run =
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          {:ok, [claimed]} =
            Pipeline.claim_extraction_runs(
              account_id,
              [message["id"]],
              first_claim_id,
              actor
            )

          claimed
        end
      )

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE pipeline_runs SET updated_at = now() - interval '30 minutes' WHERE id = $1",
      [Ecto.UUID.dump!(stale_run.id)]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE messages SET inserted_at = now() - interval '30 minutes' WHERE id = $1",
      [Ecto.UUID.dump!(message["id"])]
    )

    assert {:ok, %{expired_claims: 1, messages: 1}} = Reconciler.run(account_id)

    replacement_claim_id = Ecto.UUID.generate()

    replacement_run =
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          {:ok, [claimed]} =
            Pipeline.claim_extraction_runs(
              account_id,
              [message["id"]],
              replacement_claim_id,
              actor
            )

          claimed
        end
      )

    prepared = Memory.prepare_message_extraction_for_account(message["id"], account_id)

    assert {:error, :stale_extraction_claim} =
             Memory.persist_message_extraction_result!(
               stale_run,
               prepared.message,
               %{status: :ok, items: []},
               "stale-admission"
             )

    assert %{rows: [["processing", ^replacement_claim_id, nil]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT run.status, run.batch_claim_id::text, message.extraction_completed_at
               FROM pipeline_runs AS run
               JOIN messages AS message ON message.id = run.target_id
               WHERE run.id = $1
               """,
               [Ecto.UUID.dump!(replacement_run.id)]
             )
  end

  test "a stale anchor result is isolated while an owned sibling commits and the stale anchor replays" do
    batching = Application.fetch_env!(:memhouse, :extraction_batching)
    original_provider = Application.get_env(:memhouse, :model_provider)

    Application.put_env(:memhouse, :extraction_batching, Keyword.put(batching, :enabled, true))
    Application.put_env(:memhouse, :model_provider, ReclaimingBatchProvider)
    Application.put_env(:memhouse, :reclaiming_batch_test_controller, self())

    on_exit(fn ->
      Application.put_env(:memhouse, :extraction_batching, batching)
      Application.delete_env(:memhouse, :reclaiming_batch_test_controller)

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    assert {:ok, first} =
             Memory.ingest_message(ingest_attrs("f2-batch-stale", "batch-stale-session"))

    assert {:ok, second} =
             Memory.ingest_message(ingest_attrs("f2-batch-stale", "batch-stale-session"))

    account_id = account_id!("f2-batch-stale")
    first_id = first["id"]
    second_id = second["id"]

    first_run =
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          PipelineRun
          |> Ash.Query.filter(kind == "extraction" and target_id == ^first_id)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read_one!(actor: actor)
        end
      )

    batch_task = Task.async(fn -> MemHouse.Pipeline.ExtractionBatcher.run(first_run) end)

    assert_receive {:batch_claims_ready, provider, anchor_ids}, 5_000
    assert anchor_ids == [first_id, second_id]

    # Only the first anchor loses its lease. The sibling remains owned by the
    # paused batch and must still commit after the first persistence attempt is
    # rejected by its exact claim fence.
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE pipeline_runs SET updated_at = now() - interval '30 minutes' WHERE target_id = $1",
      [Ecto.UUID.dump!(first_id)]
    )

    assert {:ok, %{expired_claims: 1, messages: 0}} = Reconciler.run(account_id)

    assert %{rows: [["failed", nil, "BatchClaimExpired"], ["processing", claim_id, nil]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT status, batch_claim_id::text, last_error_class
               FROM pipeline_runs
               WHERE target_id = ANY($1)
               ORDER BY target_id = $2 DESC
               """,
               [
                 [Ecto.UUID.dump!(first_id), Ecto.UUID.dump!(second_id)],
                 Ecto.UUID.dump!(first_id)
               ]
             )

    assert is_binary(claim_id)
    replacement_claim_id = Ecto.UUID.generate()

    replacement_run =
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          {:ok, [claimed]} =
            Pipeline.claim_extraction_runs(
              account_id,
              [first_id],
              replacement_claim_id,
              actor
            )

          claimed
        end
      )

    send(provider, :persist_batch_results)

    assert {:ok,
            %{
              status: "processed",
              anchors: %{
                ^first_id => "stale_extraction_claim",
                ^second_id => "completed"
              }
            }} = Task.await(batch_task, 5_000)

    # The rejected first anchor transaction left no partial knowledge or
    # completion stamp, and the stale worker did not clear the replacement
    # claim. The later sibling nonetheless committed its whole effect set.
    assert %{
             rows: [
               ["processing", ^replacement_claim_id, nil, 0],
               ["completed", nil, completed_at, 1]
             ]
           } =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT run.status,
                      run.batch_claim_id::text,
                      message.extraction_completed_at,
                      (SELECT count(*) FROM knowledge_items
                       WHERE message.id = ANY(source_message_ids))
               FROM pipeline_runs AS run
               JOIN messages AS message ON message.id = run.target_id
               WHERE run.target_id = ANY($1)
               ORDER BY run.target_id = $2 DESC
               """,
               [
                 [Ecto.UUID.dump!(first_id), Ecto.UUID.dump!(second_id)],
                 Ecto.UUID.dump!(first_id)
               ]
             )

    assert %NaiveDateTime{} = completed_at

    # The replacement is independently durable and replayable. Expiring it
    # records the same content-safe failure class; a fresh worker then claims
    # and completes only this still-unfinished anchor.
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE pipeline_runs SET updated_at = now() - interval '30 minutes' WHERE id = $1",
      [Ecto.UUID.dump!(replacement_run.id)]
    )

    assert {:ok, %{expired_claims: 1, messages: 0}} = Reconciler.run(account_id)

    assert %{rows: [["failed", nil, "BatchClaimExpired"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT status, batch_claim_id, last_error_class FROM pipeline_runs WHERE id = $1",
               [Ecto.UUID.dump!(replacement_run.id)]
             )

    Application.put_env(:memhouse, :model_provider, MemHouse.Model.Providers.Deterministic)

    assert {:ok,
            %{
              status: "processed",
              anchors: %{^first_id => "completed"}
            }} = MemHouse.Pipeline.ExtractionBatcher.run(replacement_run)

    assert %{rows: [[2, 2, 2]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT count(*) FILTER (WHERE run.status = 'completed'),
                      count(*) FILTER (WHERE message.extraction_completed_at IS NOT NULL),
                      count(*) FILTER (WHERE EXISTS (
                        SELECT 1 FROM knowledge_items
                        WHERE message.id = ANY(source_message_ids)
                      ))
               FROM pipeline_runs AS run
               JOIN messages AS message ON message.id = run.target_id
               WHERE run.target_id = ANY($1)
               """,
               [[Ecto.UUID.dump!(first_id), Ecto.UUID.dump!(second_id)]]
             )
  end

  test "a retryable batch failure reports every claimed anchor before returning the provider error" do
    original_batching = Application.fetch_env!(:memhouse, :extraction_batching)
    original_provider = Application.get_env(:memhouse, :model_provider)

    Application.put_env(
      :memhouse,
      :extraction_batching,
      Keyword.put(original_batching, :enabled, true)
    )

    Application.put_env(:memhouse, :model_provider, ReclaimingBatchProvider)
    Application.put_env(:memhouse, :reclaiming_batch_test_controller, self())

    on_exit(fn ->
      Application.put_env(:memhouse, :extraction_batching, original_batching)
      Application.delete_env(:memhouse, :reclaiming_batch_test_controller)
      restore_model_provider(original_provider)
    end)

    assert {:ok, first} =
             Memory.ingest_message(ingest_attrs("f2-batch-retryable", "batch-retryable-session"))

    assert {:ok, second} =
             Memory.ingest_message(ingest_attrs("f2-batch-retryable", "batch-retryable-session"))

    first_id = first["id"]
    second_id = second["id"]
    account_id = account_id!("f2-batch-retryable")
    first_run = extraction_run!(account_id, first_id)
    handler = attach_batch_telemetry(:retryable_batch)

    batch_task = Task.async(fn -> MemHouse.Pipeline.ExtractionBatcher.run(first_run) end)

    assert_receive {:batch_claims_ready, provider, [^first_id, ^second_id]}, 5_000
    send(provider, {:return_batch_result, {:error, :provider_unavailable}})

    assert {:error, :provider_unavailable} = Task.await(batch_task, 5_000)

    assert_receive {^handler, measurements, metadata}, 5_000
    assert metadata.operation == "ingest_batch"
    assert metadata.status == "failed"
    assert metadata.failure_class == "provider_transient"
    assert measurements.calls == 1
    assert measurements.anchors == 2
    assert measurements.failures == 2
    assert measurements.stale_claims == 0

    assert %{rows: [["failed", "provider_transient"], ["failed", "provider_transient"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT status, last_error_class
               FROM pipeline_runs
               WHERE target_id = ANY($1)
               ORDER BY target_id
               """,
               [[Ecto.UUID.dump!(first_id), Ecto.UUID.dump!(second_id)]]
             )
  end

  test "an oversized classified batch keeps telemetry detail out of its public result" do
    original_batching = Application.fetch_env!(:memhouse, :extraction_batching)

    Application.put_env(
      :memhouse,
      :extraction_batching,
      original_batching
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:target_tokens, 128)
      |> Keyword.put(:context_limit_tokens, 128)
      |> Keyword.put(:reserved_output_tokens, 64)
      |> Keyword.put(:safety_margin_tokens, 64)
    )

    on_exit(fn -> Application.put_env(:memhouse, :extraction_batching, original_batching) end)

    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-batch-oversized", "batch-oversized-session"))

    account_id = account_id!("f2-batch-oversized")
    run = extraction_run!(account_id, message["id"])
    handler = attach_batch_telemetry(:oversized_batch)

    assert {:ok, %{status: "repairable", run_status: "persisted", anchor_count: 1}} ==
             MemHouse.Pipeline.ExtractionBatcher.run(run)

    assert_receive {^handler, measurements, metadata}, 5_000
    assert metadata.status == "repairable"
    assert metadata.failure_class == "oversized"
    assert measurements.anchors == 1
    assert measurements.failures == 1
    assert measurements.stale_claims == 0
  end

  test "stale claims remain a distinct subset of repairable and terminal batch failures" do
    original_batching = Application.fetch_env!(:memhouse, :extraction_batching)
    original_provider = Application.get_env(:memhouse, :model_provider)

    Application.put_env(
      :memhouse,
      :extraction_batching,
      Keyword.put(original_batching, :enabled, true)
    )

    Application.put_env(:memhouse, :model_provider, ReclaimingBatchProvider)
    Application.put_env(:memhouse, :reclaiming_batch_test_controller, self())

    on_exit(fn ->
      Application.put_env(:memhouse, :extraction_batching, original_batching)
      Application.delete_env(:memhouse, :reclaiming_batch_test_controller)
      restore_model_provider(original_provider)
    end)

    cases = [
      {"repairable", "repairable", %ReqLLM.Error.Invalid.Parameter{parameter: :model},
       "configuration", 1},
      {"terminal", "terminal", {:structured_validation_failed, ["shape"]},
       "structured_validation_exhausted", 1},
      {"all-stale", "repairable", %ReqLLM.Error.Invalid.Parameter{parameter: :model},
       "stale_extraction_claim", 2}
    ]

    for {case_name, expected_status, provider_error, expected_failure_class, stale_count} <-
          cases do
      account_key = "f2-batch-stale-#{case_name}"
      session_id = "batch-stale-#{case_name}-session"

      assert {:ok, first} = Memory.ingest_message(ingest_attrs(account_key, session_id))
      assert {:ok, second} = Memory.ingest_message(ingest_attrs(account_key, session_id))

      first_id = first["id"]
      second_id = second["id"]
      account_id = account_id!(account_key)
      first_run = extraction_run!(account_id, first_id)
      handler = attach_batch_telemetry({:stale_batch, case_name})

      batch_task = Task.async(fn -> MemHouse.Pipeline.ExtractionBatcher.run(first_run) end)

      assert_receive {:batch_claims_ready, provider, [^first_id, ^second_id]}, 5_000

      stale_ids = Enum.take([first_id, second_id], stale_count)

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE pipeline_runs SET updated_at = now() - interval '30 minutes' WHERE target_id = ANY($1)",
        [Enum.map(stale_ids, &Ecto.UUID.dump!/1)]
      )

      assert {:ok, %{expired_claims: ^stale_count}} = Reconciler.run(account_id)

      replacement_claim_id = Ecto.UUID.generate()

      assert ^stale_count =
               account_id
               |> DataLayer.with_account_id(
                 [role: :system, pipeline?: true],
                 fn _account, actor ->
                   {:ok, claimed} =
                     Pipeline.claim_extraction_runs(
                       account_id,
                       stale_ids,
                       replacement_claim_id,
                       actor
                     )

                   length(claimed)
                 end
               )

      send(provider, {:return_batch_result, {:error, provider_error}})

      expected_anchors =
        Map.new([first_id, second_id], fn id ->
          if id in stale_ids,
            do: {id, "stale_extraction_claim"},
            else: {id, expected_status}
        end)

      assert {:ok, %{status: ^expected_status, anchors: ^expected_anchors} = public_result} =
               Task.await(batch_task, 5_000)

      refute Map.has_key?(public_result, :failure_class)

      assert_receive {^handler, measurements, metadata}, 5_000
      assert metadata.status == "partial"
      assert metadata.failure_class == expected_failure_class
      assert measurements.calls == 1
      assert measurements.anchors == 2
      assert measurements.failures == 2
      assert measurements.stale_claims == stale_count
    end
  end

  test "a background job finds and finishes its run on a connection with no Account declared" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-undeclared", "undeclared-session"))

    # The condition every background job actually meets, and the one nothing else in this
    # file reproduces. A job runs with no request behind it, so the pooled connection its
    # first query lands on has never had an Account declared to it, and the row-level
    # security policy on `pipeline_runs` compares every row — read or written — against
    # exactly that declaration.
    #
    # Under the SQL sandbox the ingest above leaves its declaration installed for the rest of
    # this test, which hides that condition completely. Clearing it is what puts the
    # connection back into the state the job runner meets in production.
    clear_account_declaration!()

    # Undeclared, the job's opening read of its own run row returns nothing. The job runner
    # reads an empty result as "this record no longer matches the trigger" and cancels
    # cleanly, so the queue reports neither a success nor a failure and the work is silently
    # abandoned: ingest returns 200, nothing is ever extracted, and nothing is searchable.
    assert %{success: 1, failure: 0, cancelled: 0, discard: 0} = Oban.drain_queue(queue: :ingest)

    # Proof the job saw the row and wrote back to it: the observation is marked extracted,
    # knowledge came out of it, and the run reached `completed`. The status write is the half
    # that the read fix alone would not cover — an undeclared UPDATE matches no row, which
    # Ash raises as a stale record and the runner also turns into a cancellation.
    assert %{rows: [[completed_at, 1, "completed"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT message.extraction_completed_at,
                      (SELECT count(*) FROM knowledge_items
                       WHERE $1 = ANY(source_message_ids)),
                      run.status
               FROM messages AS message
               JOIN pipeline_runs AS run ON run.target_id = message.id
               WHERE message.id = $1 AND run.kind = 'extraction'
               """,
               [Ecto.UUID.dump!(message["id"])]
             )

    assert %NaiveDateTime{} = completed_at
  end

  test "the failure path records an attempt on a connection with no Account declared" do
    assert {:ok, message} =
             Memory.ingest_message(
               ingest_attrs("f2-undeclared-failure", "undeclared-failure-session")
             )

    account_id = account_id!("f2-undeclared-failure")

    # Loading the run and its internal actor through the ordinary scoped helper, so the only
    # thing this test changes about the write below is whether an Account is declared.
    {run, actor} =
      DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account,
                                                                                 actor ->
        run =
          PipelineRun
          |> Ash.Query.set_tenant(account_id)
          |> Ash.Query.filter(kind == "extraction")
          |> Ash.read_one!(actor: actor)

        {run, actor}
      end)

    assert run.target_id == message["id"]

    # The job runner invokes this action from its error handler, which runs after the work
    # has already failed and outside any transaction of ours — the same undeclared connection
    # as the trigger read. If the attempt cannot be recorded there, a run that exhausted its
    # retries is left looking pending forever and the reconciler keeps re-queueing it.
    clear_account_declaration!()

    # The job runner marks this context on everything it does, and the resource's policy
    # bypasses role checks for it — a background job carries no authenticated caller. Setting
    # it here is what leaves the database wall as the only thing the write still has to
    # satisfy, which is the thing under test.
    log =
      capture_log(
        [
          level: :error,
          metadata: [
            :account_id,
            :scope_id,
            :pipeline_run_id,
            :target_type,
            :target_id,
            :message_id,
            :attempt_count,
            :error_class
          ]
        ],
        fn ->
          result =
            run
            |> Ash.Changeset.new()
            |> Ash.Changeset.set_tenant(account_id)
            |> Ash.Changeset.set_context(%{private: %{ash_oban?: true}})
            |> Ash.Changeset.for_action(:mark_failed, %{
              error: %RuntimeError{message: "secret provider detail"}
            })
            |> Ash.update(actor: actor)

          send(self(), {:failed_run, result})
        end
      )

    assert_receive {:failed_run, {:ok, failed}}

    assert failed.status == "failed"
    assert failed.attempt_count == run.attempt_count + 1
    # Only a classification is stored; the message the error carried never reaches the row.
    assert failed.last_error_class == "RuntimeError"
    assert log =~ "pipeline extraction failed"
    assert log =~ "account_id=#{account_id}"
    assert log =~ "pipeline_run_id=#{run.id}"
    assert log =~ "message_id=#{message["id"]}"
    assert log =~ "attempt_count=#{run.attempt_count + 1}"
    assert log =~ "error_class=RuntimeError"
    refute log =~ "secret provider detail"
  end

  test "a crash callback cannot downgrade an anchor committed earlier in the batch" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-batch-crash", "batch-crash-session"))

    account_id = account_id!("f2-batch-crash")

    {stale_run, actor} =
      DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account,
                                                                                 actor ->
        run =
          PipelineRun
          |> Ash.Query.set_tenant(account_id)
          |> Ash.Query.filter(kind == "extraction" and target_id == ^message["id"])
          |> Ash.read_one!(actor: actor)

        {:ok, [claimed]} =
          Pipeline.claim_extraction_runs(
            account_id,
            [message["id"]],
            Ecto.UUID.generate(),
            actor
          )

        {:ok, completed} =
          Pipeline.complete_extraction_run(claimed, "batch-crash-test", actor)

        assert completed.status == "completed"
        {run, actor}
      end)

    # This is the stale record the outer Oban job retained before the batched
    # workflow committed the first anchor and then crashed on a later sibling.
    clear_account_declaration!()

    assert {:ok, preserved} =
             stale_run
             |> Ash.Changeset.new()
             |> Ash.Changeset.set_tenant(account_id)
             |> Ash.Changeset.set_context(%{private: %{ash_oban?: true}})
             |> Ash.Changeset.for_action(:mark_failed, %{
               error: %RuntimeError{message: "later sibling crashed"}
             })
             |> Ash.update(actor: actor)

    assert preserved.status == "completed"
    assert preserved.attempt_count == stale_run.attempt_count + 1
    assert is_nil(preserved.last_error_class)
  end

  test "a delegated stale execute cannot downgrade an anchor its owner completed" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-batch-delegated", "batch-delegated-session"))

    account_id = account_id!("f2-batch-delegated")

    {stale_run, actor} =
      DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account,
                                                                                 actor ->
        run =
          PipelineRun
          |> Ash.Query.set_tenant(account_id)
          |> Ash.Query.filter(kind == "extraction" and target_id == ^message["id"])
          |> Ash.read_one!(actor: actor)

        {:ok, [claimed]} =
          Pipeline.claim_extraction_runs(
            account_id,
            [message["id"]],
            Ecto.UUID.generate(),
            actor
          )

        {:ok, completed} =
          Pipeline.complete_extraction_run(claimed, "delegated-race-test", actor)

        assert completed.status == "completed"
        {run, actor}
      end)

    clear_account_declaration!()

    assert {:ok, preserved} =
             stale_run
             |> Ash.Changeset.new()
             |> Ash.Changeset.set_tenant(account_id)
             |> Ash.Changeset.set_context(%{private: %{ash_oban?: true}})
             |> Ash.Changeset.for_action(:execute, %{})
             |> Ash.update(actor: actor)

    assert preserved.status == "completed"
    assert preserved.attempt_count == stale_run.attempt_count + 1
    assert is_nil(preserved.batch_claim_id)
  end

  test "a persisted batch outcome cannot overwrite a concurrent operator requeue" do
    assert {:ok, message} =
             Memory.ingest_message(
               ingest_attrs("f2-batch-requeue-race", "batch-requeue-race-session")
             )

    account_id = account_id!("f2-batch-requeue-race")

    terminal_run =
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          {:ok, [claimed]} =
            Pipeline.claim_extraction_runs(
              account_id,
              [message["id"]],
              Ecto.UUID.generate(),
              actor
            )

          {:ok, terminal} =
            Pipeline.classify_extraction_run(
              claimed,
              "terminal",
              "structured_validation_exhausted",
              "requeue-race-test",
              actor
            )

          {:ok, pending} =
            terminal
            |> Ash.Changeset.for_update(:requeue_extraction_anchor, %{})
            |> Ash.Changeset.set_tenant(account_id)
            |> Ash.update(actor: actor)

          assert pending.status == "pending"
          terminal
        end
      )

    outcome_changeset =
      terminal_run
      |> Ash.Changeset.new()
      |> ExecuteRun.apply_outcome({:ok, %{run_status: "persisted"}})

    refute Ash.Changeset.changing_attribute?(outcome_changeset, :status)
    refute Ash.Changeset.changing_attribute?(outcome_changeset, :processed_at)
    refute Ash.Changeset.changing_attribute?(outcome_changeset, :attempt_count)

    assert %{rows: [["pending", nil, nil]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT status, batch_claim_id, last_error_class
               FROM pipeline_runs
               WHERE id = $1
               """,
               [Ecto.UUID.dump!(terminal_run.id)]
             )
  end

  test "pipeline replay merges provenance and never duplicates knowledge or lifecycle" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-replay", "replay-session"))

    account_id = account_id!("f2-replay")

    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account_id)

    # The baseline is taken after the first extraction.
    before = knowledge_counts(account_id)

    # Two more extractions of the same observation stand in for the ways replay really happens:
    # a retried job or a reconciler sweep. Each returns
    # the knowledge as if it had just produced it — replay is a normal outcome, not an error.
    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account_id)

    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account_id)

    # Nothing new was written: not a duplicate knowledge item, not a second creation lifecycle
    # event, not a repeated attribution, provenance, or audit entry. Duplicates here would
    # inflate corroboration counts, so a statement could be promoted for having been said once.
    assert knowledge_counts(account_id) == before
  end

  test "provider unavailability cannot prevent raw persistence and transactional enqueue" do
    # Points the legacy `:models` credential and base URL at a port nothing listens on, so any
    # provider call made under this configuration would fail on connect rather than hang. The
    # ingest below returns before extraction, so no model call is attempted here; what the
    # assertions prove is that the durable observation and its processing record do not depend
    # on extraction having produced anything.
    models =
      :memhouse
      |> Application.fetch_env!(:models)
      |> Keyword.merge(
        api_key: "configured-but-unavailable",
        base_url: "http://127.0.0.1:1"
      )

    Application.put_env(:memhouse, :models, models)

    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-provider-down", "provider-session"))

    # Ingest returns the observation with no "knowledge" key at all, so the
    # caller is never handed a fabricated or fallback result while extraction is still pending.
    refute Map.has_key?(message, "knowledge")

    # The observation is stored and still marked unprocessed, so the reconciler will pick it up.
    assert scalar!(
             """
             SELECT count(*)
             FROM messages
             WHERE id = $1
               AND extraction_completed_at IS NULL
             """,
             [Ecto.UUID.dump!(message["id"])]
           ) == 1

    # And the durable processing record survives the provider failure, so the work is retryable
    # rather than lost.
    assert scalar!(
             "SELECT count(*) FROM pipeline_runs WHERE target_id = $1 AND kind = 'extraction'",
             [Ecto.UUID.dump!(message["id"])]
           ) == 1
  end

  test "per-Account audit events form a verifiable content-safe hash chain" do
    content = "Hash-chain evidence never stores this raw statement in audit metadata."

    assert {:ok, message} =
             Memory.ingest_message(
               ingest_attrs("f2-audit-chain", "audit-session", content: content)
             )

    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account_id!("f2-audit-chain"))

    # Reading audit needs an admin, curator, or system role; ordinary members and readers have
    # no route to it. Sorting by insertion order with the id as a tiebreak reproduces the order
    # the chain was built in, which is the only order in which the links verify.
    events =
      DataLayer.with_account_key(
        "f2-audit-chain",
        [role: :system, pipeline?: true],
        fn account, actor ->
          AuditEvent
          |> Ash.Query.sort(inserted_at: :asc, id: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
        end
      )

    # A floor rather than an exact count, so adding a new audited action elsewhere does not
    # break this test. The named actions are the ones a single ingest must always leave behind:
    # the knowledge moved state, and both governance gates recorded what they decided.
    assert length(events) >= 4
    assert Enum.any?(events, &(&1.action == "knowledge.transitioned"))
    assert Enum.any?(events, &(&1.action == "gate_a.defer"))
    assert Enum.any?(events, &(&1.action == "gate_b.provisional"))

    # Walk the chain, carrying the previous event's hash. The accumulator starts at nil because
    # the first event of an Account links to nothing.
    events
    |> Enum.reduce(nil, fn event, previous_hash ->
      # Each link points at its predecessor, and the hash is a full 64-character hex SHA-256.
      # A gap or a re-pointed link means an event was removed or inserted after the fact.
      assert event.previous_hash == previous_hash
      assert event.event_hash =~ ~r/\A[0-9a-f]{64}\z/

      # Content safety: the observed text must not appear anywhere in the event metadata.
      # Inspecting the whole term catches it however deeply it was nested.
      refute inspect(event.metadata) =~ content

      # Recompute the hash from the stored fields. This exact field set, in this shape, defines
      # the chain: adding, removing, or re-typing any of them changes every future hash and
      # invalidates every chain already written, so it is a migration, not a tweak.
      payload = %{
        account_id: event.account_id,
        category: event.category,
        action: event.action,
        resource_type: event.resource_type,
        resource_id: event.resource_id,
        content_hash: event.content_hash,
        metadata: event.metadata,
        occurred_at: DateTime.to_iso8601(event.occurred_at),
        previous_hash: event.previous_hash
      }

      assert event.event_hash == Audit.content_hash(payload)
      event.event_hash
    end)
  end

  test "F2 registers every job lane, continuation Reactor, and deterministic key family" do
    # The complete set of background lanes. Listing them exactly means a new lane cannot be
    # added without a reviewer noticing that it also needs an idempotency key family, a
    # reconciler story, and content-free job arguments.
    trigger_names =
      PipelineRun
      |> AshOban.Info.oban_triggers()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert trigger_names ==
             Enum.sort([
               :answer_correlation,
               :connector_sync,
               :dream_time,
               :entity_resolution,
               :expiry,
               :extraction,
               :import_rebuild,
               :projection_refresh,
               :reembed,
               :reconciler,
               :revalidation,
               :validation_continuation
             ])

    # Each lane's orchestration module must exist and compile. A trigger whose workflow module
    # is missing would only fail when a real job ran, in production, at retry time.
    assert Code.ensure_loaded?(MemHouse.Pipeline.Workflows.IngestExtraction)
    assert Code.ensure_loaded?(MemHouse.Pipeline.Workflows.DreamTimeReasoning)
    assert Code.ensure_loaded?(MemHouse.Pipeline.Workflows.ValidationContinuation)
    assert Code.ensure_loaded?(MemHouse.Pipeline.Workflows.AnswerCorrelationContinuation)
    assert Code.ensure_loaded?(MemHouse.Retrieval.Reembed)

    # Idempotency keys need two opposite properties, and both are checked here.
    #
    # Stable: identical inputs give an identical key, so a retry or a reconciler sweep lands on
    # the work that already exists instead of starting a second copy.
    message_id = Ecto.UUID.generate()
    message_key = Idempotency.message_extraction(message_id, "content-hash")

    assert message_key ==
             Idempotency.message_extraction(message_id, "content-hash")

    # Distinct: different lanes and different inputs must never collide, or one piece of work
    # would be discarded as a duplicate of an unrelated one and never run at all. The pairs
    # below are the collisions that could plausibly happen if a key were built from too few
    # components — two lanes sharing a scope and watermark, one import with two manifests.
    assert message_key != Idempotency.document_extraction(Ecto.UUID.generate(), "content-hash")

    scope_id = Ecto.UUID.generate()
    assert Idempotency.dream_time(scope_id, 42) == Idempotency.dream_time(scope_id, 42)

    assert Idempotency.projection_refresh(scope_id, 42) !=
             Idempotency.entity_resolution(scope_id, 42)

    changed_at = ~U[2026-08-14 10:00:01.123456Z]
    same_bucket = ~U[2026-08-14 10:00:09.999999Z]
    next_bucket = ~U[2026-08-14 10:00:10.000000Z]

    assert Idempotency.derived_refresh(scope_id, :projection_refresh, changed_at, 10) ==
             Idempotency.derived_refresh(scope_id, :projection_refresh, same_bucket, 10)

    assert Idempotency.derived_refresh(scope_id, :projection_refresh, changed_at, 10) !=
             Idempotency.derived_refresh(scope_id, :projection_refresh, next_bucket, 10)

    assert Idempotency.derived_refresh(scope_id, :projection_refresh, changed_at, 10) !=
             Idempotency.derived_refresh(scope_id, :entity_resolution, changed_at, 10)

    assert Idempotency.import_rebuild("import-1", "manifest-a") !=
             Idempotency.import_rebuild("import-1", "manifest-b")

    identity = %{provider: "ortex", model: "qwen3", version: "1", dimensions: 1024}
    assert Idempotency.reembed(scope_id, identity) == Idempotency.reembed(scope_id, identity)

    # The audit categories are a closed vocabulary. Every audited action must fall into one of
    # them, so operators can filter and retain the trail without knowing each action name.
    assert Enum.sort(Audit.categories()) ==
             Enum.sort(
               ~w(attribution configuration deletion gate governance lifecycle observation)
             )
  end

  test "re-embed enqueue exposes durable progress and reuses the target identity" do
    assert {:ok, _message} =
             Memory.ingest_message(ingest_attrs("f2-reembed", "reembed-session"))

    account_id = account_id!("f2-reembed")

    identity = %{
      "provider" => "ortex",
      "model" => "Qwen/Qwen3-Embedding-0.6B",
      "version" => "onnx-1-qwen3-1024",
      "dimensions" => 1024
    }

    {first, repeated} =
      DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account,
                                                                                 actor ->
        {:ok, first} = MemHouse.Pipeline.enqueue_reembed(account_id, identity, actor)
        {:ok, repeated} = MemHouse.Pipeline.enqueue_reembed(account_id, identity, actor)
        {first, repeated}
      end)

    assert first.id == repeated.id

    assert first.payload == %{
             "phase" => "knowledge",
             "cursor" => nil,
             "knowledge_processed" => 0,
             "chunks_processed" => 0,
             "scopes_processed" => 0,
             "identity" => identity
           }
  end

  test "a billed model call stays metered when the write that follows it fails" do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("f2-metered-failure", "metered-failure-session"))

    account_id = account_id!("f2-metered-failure")

    original_provider = Application.get_env(:memhouse, :model_provider)

    on_exit(fn ->
      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    Application.put_env(:memhouse, :model_provider, VanishingSubjectProvider)

    # The provider renames the subject peer as a side effect of answering, so the candidate it
    # returns names a peer key that existed when the prompt was built and no longer exists
    # when the write runs. Subject resolution refuses to re-attribute the statement to the
    # speaker and raises instead, which is the failure this test needs.
    assert_raise ArgumentError, ~r/unknown peer/, fn ->
      Memory.extract_message_for_account(message["id"], account_id)
    end

    # The call was made and billed. Rolling its ledger row back with the failed write would
    # understate real spend and hide a vendor charge the operator still owes, so the usage
    # write must not share a transaction with the knowledge write.
    assert scalar!(
             """
             SELECT count(*) FROM usage_events
             WHERE account_id = $1 AND model_role = 'ingest_extractor'
             """,
             [Ecto.UUID.dump!(account_id)]
           ) == 1

    # The failure still left nothing half-written and nothing claimed as processed, so the
    # durable job retries the whole extraction.
    assert knowledge_counts(account_id) == {0, 0, 0, 0, 1}

    assert scalar!(
             "SELECT count(*) FROM messages WHERE id = $1 AND extraction_completed_at IS NULL",
             [Ecto.UUID.dump!(message["id"])]
           ) == 1
  end

  test "F2 Oban configuration lets this node hold peer leadership so retryable jobs are staged" do
    # Oban's stager (core infrastructure in this Oban version, not a plugin) only promotes
    # `scheduled`/`retryable` jobs past their `scheduled_at` time while this node holds peer
    # leadership. `AshOban.config/2` forces `peer: false` onto the base config whenever
    # `:plugins` is not already a non-empty list, and Oban folds a literal `peer: false` into
    # `{Oban.Peers.Isolated, [leader?: false]}` — leadership this node can never win. A job
    # that fails once and is scheduled for backoff retry then never runs again: nothing
    # promotes it back to `available`, and nothing raises, so the stall is silent.
    # `MemHouse.Application.oban_config/0` is what the supervision tree actually starts
    # Oban with, so this pins the fixed value rather than the raw `AshOban.config/2` merge.
    merged = MemHouse.Application.oban_config()

    refute merged[:peer] == false

    # `config/test.exs` merges `testing: :manual` into `:memhouse, Oban`, and Oban's own
    # config normalization deliberately forces an unelectable peer whenever `testing` is
    # `:manual`/`:inline` — correct test isolation, not the bug this test guards. Forcing
    # `testing: :disabled` here simulates how the merged config resolves in production,
    # independent of that ambient test-env override.
    production_config = Oban.Config.new(Keyword.put(merged, :testing, :disabled))

    refute match?({Oban.Peers.Isolated, [leader?: false]}, production_config.peer)
    assert match?({Oban.Peers.Database, _}, production_config.peer)
  end

  # Builds one ingest payload. Every test uses its own Account key so the count assertions are
  # not disturbed by rows another test in this file created. Overrides are given as a keyword
  # list purely for readability at the call sites and are converted to the string keys the
  # ingest entry point expects.
  defp extraction_run!(account_id, target_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        PipelineRun
        |> Ash.Query.filter(kind == "extraction" and target_id == ^target_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read_one!(actor: actor)
      end
    )
  end

  defp attach_batch_telemetry(name) do
    handler = {__MODULE__, self(), name}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, measurements, %{operation: "ingest_batch"} = metadata, _config ->
          send(parent, {handler, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp restore_model_provider(nil), do: Application.delete_env(:memhouse, :model_provider)

  defp restore_model_provider(provider),
    do: Application.put_env(:memhouse, :model_provider, provider)

  defp ingest_attrs(account_key, session_id, overrides \\ []) do
    %{
      "account_key" => account_key,
      "session_id" => session_id,
      "scope_path" => "/f2/#{account_key}",
      "peer_key" => "#{account_key}-peer",
      "role" => "user",
      "content" => "Avery prefers concise weekly release summaries."
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  # Puts this connection back into the state a freshly checked-out one is in: no Account
  # declared, so every row-level-security policy on a tenant table denies until something
  # declares one. That is the state every background job starts from, and the sandbox
  # otherwise hides it, because the seeding transaction's declaration lasts for the whole
  # test. The settings are transaction-local, so this affects only the running test.
  defp clear_account_declaration! do
    Ecto.Adapters.SQL.query!(Repo, "SELECT set_config('memhouse.account_id', '', true)", [])
    Ecto.Adapters.SQL.query!(Repo, "SELECT set_config('memhouse.account_key', '', true)", [])
  end

  # Resolves the Account identifier as text, because the counting queries below compare it
  # against the job arguments, where it is stored as a JSON string rather than a UUID.
  defp account_id!(account_key) do
    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT id::text FROM accounts WHERE key = $1",
        [account_key]
      )

    id
  end

  # Returns the session, scope, and peer the seed ingest created, so the rollback test can
  # build a second observation against real parents. It reads them from the database rather
  # than creating fresh ones, because creating them would itself add rows and move the
  # before/after counts the test compares.
  defp observation_ids!(account_key) do
    %{rows: [[session_id, scope_id, peer_id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT session.id::text, scope.id::text, peer.id::text
        FROM sessions AS session
        JOIN accounts AS account ON account.id = session.account_id
        JOIN scopes AS scope ON scope.id = session.scope_id
        JOIN peers AS peer ON peer.id = session.peer_id
        WHERE account.key = $1
        LIMIT 1
        """,
        [account_key]
      )

    {session_id, scope_id, peer_id}
  end

  # The four counts that must move together: observations, audit events, processing records,
  # and queued jobs. Read in one statement so the tuple is a consistent snapshot. Jobs are
  # matched on the Account carried in their arguments, since the queue table is not itself an
  # Account-scoped resource.
  defp account_counts(account_key) do
    account_id = account_id!(account_key)

    %{rows: [[messages, audits, runs, jobs]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          (SELECT count(*) FROM messages WHERE account_id = $1),
          (SELECT count(*) FROM audit_events WHERE account_id = $1),
          (SELECT count(*) FROM pipeline_runs WHERE account_id = $1),
          (SELECT count(*) FROM oban_jobs WHERE args->>'tenant' = $2)
        """,
        [Ecto.UUID.dump!(account_id), account_id]
      )

    {messages, audits, runs, jobs}
  end

  # Everything a replayed extraction could wrongly duplicate: the knowledge item itself, its
  # lifecycle history, who said it, where it came from, and the audit trail. All five are
  # compared as one tuple so a single leaked duplicate fails the test.
  defp knowledge_counts(account_id) do
    %{rows: [[knowledge, lifecycle, attributions, provenances, audits]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          (SELECT count(*) FROM knowledge_items WHERE account_id = $1),
          (SELECT count(*) FROM knowledge_lifecycle_events WHERE account_id = $1),
          (SELECT count(*) FROM attributions WHERE account_id = $1),
          (SELECT count(*) FROM provenances WHERE account_id = $1),
          (SELECT count(*) FROM audit_events WHERE account_id = $1)
        """,
        [Ecto.UUID.dump!(account_id)]
      )

    {knowledge, lifecycle, attributions, provenances, audits}
  end

  # Runs a parameterized query expected to return exactly one column of one row, and fails the
  # match if it returns anything else.
  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(Repo, sql, params)
    value
  end
end
