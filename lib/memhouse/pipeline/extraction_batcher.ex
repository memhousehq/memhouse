# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.ExtractionBatcher do
  @moduledoc """
  Claims and processes adjacent message anchors through the existing ingest queue.

  The executing message's Oban job first changes its durable replay row to
  `processing`. It may then atomically claim still-pending siblings in the same
  Account, scope, and session. No batch table or second writer exists: every
  anchor keeps its original PipelineRun and completion stamp.

  The provider call holds no database connection. Results commit one anchor at
  a time, each transaction including governed knowledge effects, the message
  completion stamp, and the PipelineRun outcome. A crash can therefore replay
  incomplete anchors without replaying completed siblings.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Memory
  alias MemHouse.Model.ProviderFailure
  alias MemHouse.Observability
  alias MemHouse.Observations.Message
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.ExtractionAdmission
  alias MemHouse.Pipeline.Extractor

  require Ash.Query

  @doc """
  Processes the message named by an extraction `PipelineRun`.

  A processed result includes an `:anchors` map whose values are
  `"completed"`, a durable provider-result classification, or
  `"stale_extraction_claim"`. The last value is an expected concurrency
  outcome: that anchor is skipped without preventing still-owned siblings from
  committing.
  """
  def run(run) do
    started_at = System.monotonic_time(:millisecond)
    {internal_result, accounting} = do_run(run)

    emit_aggregate(
      run,
      internal_result,
      accounting,
      System.monotonic_time(:millisecond) - started_at
    )

    public_result(internal_result)
  end

  defp public_result({:retryable_batch_error, error, _anchor_statuses}), do: {:error, error}

  defp public_result({:classified_batch_result, result, _anchor_statuses, _failure_class}),
    do: result

  defp public_result(result), do: result

  defp do_run(run) do
    claim_id = Ecto.UUID.generate()
    actor_opts = [role: :system, pipeline?: true]

    DataLayer.with_account_id(run.account_id, actor_opts, fn _account, actor ->
      Pipeline.claim_extraction_runs(run.account_id, [run.target_id], claim_id, actor)
    end)
    |> case do
      {:ok, [claimed_run]} ->
        process_claimed(claimed_run, claim_id)

      {:ok, []} ->
        {{:ok, %{status: "delegated", run_status: "delegated"}}, empty_accounting()}

      {:error, error} ->
        {{:error, error}, empty_accounting()}
    end
  end

  defp emit_aggregate(run, result, accounting, elapsed_ms) do
    {status, anchors, failures, stale_claims, failure_class} = aggregate_result(result)

    Observability.emit_operation(
      :ingest_batch,
      %{
        anchors: anchors,
        attempts: if(status == "delegated", do: 0, else: 1),
        # `calls` remains the shared provider-call field. The explicit batch
        # counters distinguish one logical admission from its repair callbacks.
        calls: accounting.provider_attempts,
        batch_requests: accounting.batch_requests,
        provider_attempts: accounting.provider_attempts,
        items: anchors,
        failures: failures,
        stale_claims: stale_claims,
        elapsed_ms: elapsed_ms
      },
      %{
        run_id: run.id,
        version: ExtractionAdmission.config()[:identity] |> Extractor.admission_identity(),
        status: status,
        failure_class: failure_class,
        account_id: run.account_id,
        scope_id: run.scope_id
      }
    )
  end

  defp aggregate_result({:ok, %{status: "processed", anchors: anchors}}),
    do: aggregate_anchor_statuses(anchors, nil, nil)

  defp aggregate_result({:ok, %{status: "delegated"}}),
    do: {"delegated", 0, 0, 0, nil}

  defp aggregate_result(
         {:classified_batch_result, {:ok, %{status: status}}, anchors, failure_class}
       ),
       do: aggregate_anchor_statuses(anchors, status, failure_class)

  defp aggregate_result({:retryable_batch_error, error, anchors}) do
    {_disposition, reason_class} = failure_class(error)
    aggregate_anchor_statuses(anchors, "failed", reason_class)
  end

  defp aggregate_result({:error, error}) do
    {_disposition, reason_class} = failure_class(error)
    {"failed", 1, 1, 0, reason_class}
  end

  defp aggregate_anchor_statuses(anchors, all_failed_status, failure_class) do
    statuses = Map.values(anchors)
    anchor_count = length(statuses)
    completed = Enum.count(statuses, &(&1 == "completed"))
    stale_claims = Enum.count(statuses, &(&1 == "stale_extraction_claim"))
    failures = anchor_count - completed

    classified_failures =
      statuses
      |> Enum.reject(&(&1 in ["completed", "stale_extraction_claim"]))
      |> Enum.uniq()

    status =
      cond do
        failures == 0 -> "ok"
        completed > 0 or stale_claims > 0 -> "partial"
        is_binary(all_failed_status) -> all_failed_status
        length(classified_failures) == 1 -> hd(classified_failures)
        true -> "failed"
      end

    failure_class =
      cond do
        failures == 0 -> nil
        classified_failures == [] -> "stale_extraction_claim"
        is_binary(failure_class) -> failure_class
        length(classified_failures) == 1 -> hd(classified_failures)
        true -> "mixed_anchor_outcomes"
      end

    {status, anchor_count, failures, stale_claims, failure_class}
  end

  defp process_claimed(run, claim_id) do
    anchor = Memory.prepare_message_extraction_for_account(run.target_id, run.account_id)

    prepared =
      [anchor | adjacent_candidates(anchor, run.account_id)]
      |> fit_request()

    case prepared do
      [] ->
        statuses =
          mark_all(
            [run],
            "repairable",
            "oversized",
            ExtractionAdmission.config()[:identity] |> Extractor.admission_identity()
          )

        result =
          {:classified_batch_result,
           {:ok, %{status: "repairable", run_status: "persisted", anchor_count: 1}}, statuses,
           "oversized"}

        {result, accounting(0)}

      selected ->
        claim_and_extract(run, claim_id, selected)
    end
  end

  defp claim_and_extract(run, claim_id, [anchor | siblings]) do
    identity = ExtractionAdmission.config()[:identity] |> Extractor.admission_identity()
    sibling_ids = Enum.map(siblings, & &1.message["id"])

    claimed_siblings =
      if sibling_ids == [] do
        []
      else
        DataLayer.with_account_id(
          run.account_id,
          [role: :system, pipeline?: true],
          fn _account, actor ->
            {:ok, claimed} =
              Pipeline.claim_extraction_runs(run.account_id, sibling_ids, claim_id, actor)

            claimed
          end
        )
      end

    claimed_ids = MapSet.new(claimed_siblings, & &1.target_id)
    siblings = Enum.filter(siblings, &MapSet.member?(claimed_ids, &1.message["id"]))
    prepared = [anchor | siblings]
    runs = Map.new([run | claimed_siblings], &{&1.target_id, &1})

    case Extractor.extract_batch_with_attempts(prepared) do
      {:ok, results, provider_attempts} ->
        statuses =
          Enum.map(results, fn result ->
            result_run = Map.fetch!(runs, result.anchor_id)
            result_anchor = Enum.find(prepared, &(&1.message["id"] == result.anchor_id))
            {result.anchor_id, persist_anchor_result(result_run, result_anchor, result)}
          end)
          |> Map.new()

        result = {:ok, %{status: "processed", run_status: "persisted", anchors: statuses}}
        {result, accounting(provider_attempts)}

      {:error, error, provider_attempts} ->
        result =
          case failure_class(error) do
            {:repairable, reason_class} ->
              statuses = mark_all(Map.values(runs), "repairable", reason_class, identity)

              {:classified_batch_result,
               {:ok,
                %{
                  status: "repairable",
                  run_status: "persisted",
                  anchor_count: map_size(runs),
                  anchors: statuses
                }}, statuses, reason_class}

            {:terminal, reason_class} ->
              statuses = mark_all(Map.values(runs), "terminal", reason_class, identity)

              {:classified_batch_result,
               {:ok,
                %{
                  status: "terminal",
                  run_status: "persisted",
                  anchor_count: map_size(runs),
                  anchors: statuses
                }}, statuses, reason_class}

            {:retryable, reason_class} ->
              # Record every claimed anchor before returning the provider error.
              # AshOban's error callback may run as well; its convergent failed
              # update keeps the same replayable state.
              statuses = mark_all(Map.values(runs), "failed", reason_class, identity)
              {:retryable_batch_error, error, statuses}
          end

        {result, accounting(provider_attempts)}
    end
  end

  defp accounting(provider_attempts)
       when is_integer(provider_attempts) and provider_attempts >= 0,
       do: %{batch_requests: 1, provider_attempts: provider_attempts}

  defp empty_accounting, do: %{batch_requests: 0, provider_attempts: 0}

  defp persist_anchor_result(run, anchor, result) do
    case Memory.persist_message_extraction_result!(
           run,
           anchor.message,
           result,
           result.admission_identity
         ) do
      {:ok, _knowledge} ->
        if result.status == :ok, do: "completed", else: Atom.to_string(result.status)

      {:error, :stale_extraction_claim} ->
        "stale_extraction_claim"
    end
  end

  defp adjacent_candidates(anchor, account_id) do
    message = anchor.message
    max_anchors = ExtractionAdmission.config()[:max_anchors]

    ids =
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          Message
          |> Ash.Query.filter(
            session_id == ^message["session_id"] and scope_id == ^message["scope_id"] and
              is_nil(extraction_completed_at) and occurred_at >= ^message["occurred_at"] and
              id != ^message["id"]
          )
          |> Ash.Query.sort(occurred_at: :asc, inserted_at: :asc, id: :asc)
          |> Ash.Query.limit(max_anchors * 2)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)
          |> Enum.map(& &1.id)
        end
      )

    Enum.map(ids, &Memory.prepare_message_extraction_for_account(&1, account_id))
  end

  defp fit_request(prepared) do
    prepared
    |> ExtractionAdmission.select_prefix(&anchor_admission_material/1)
    |> drop_until_admitted()
  end

  defp anchor_admission_material(anchor) do
    context = anchor.context

    ExtractionAdmission.count(%{
      "anchor_id" => anchor.message["id"],
      "speaker" => anchor.message["peer_key"],
      "scope" => anchor.message["scope_path"],
      "occurred_at" => anchor.message["occurred_at"],
      "participants" => anchor.message["known_peer_keys"],
      "window" =>
        Enum.map(context.window_messages, fn message ->
          Map.take(message, ["id", "peer_key", "occurred_at", "content"])
        end)
    })
  end

  defp drop_until_admitted([]), do: []

  defp drop_until_admitted(prepared) do
    {messages, _context, _opts} = Extractor.batch_request(prepared)
    schema = Extractor.batch_schema()

    case ExtractionAdmission.admit(
           messages,
           schema.json_schema()
         ) do
      {:ok, _admission} ->
        prepared

      {:error, _details} when length(prepared) > 1 ->
        prepared |> Enum.drop(-1) |> drop_until_admitted()

      {:error, _details} ->
        []
    end
  end

  defp mark_all(runs, status, reason_class, admission_identity) do
    Map.new(runs, fn run ->
      outcome =
        DataLayer.with_account_id(
          run.account_id,
          [role: :system, pipeline?: true],
          fn _account, actor ->
            Pipeline.classify_extraction_run(
              run,
              status,
              reason_class,
              admission_identity,
              actor
            )
          end
        )

      persisted_status =
        case outcome do
          {:ok, _run} -> status
          {:error, :stale_extraction_claim} -> "stale_extraction_claim"
        end

      {run.target_id, persisted_status}
    end)
  end

  @doc """
  Classifies a batch-level provider or validation failure for durable handling.

  Returns `{disposition, content_safe_reason_class}`. Repairable and terminal
  results are persisted without retry; retryable results leave each still-owned
  anchor failed so the ordinary durable replay path can run it again.
  """
  def failure_class({:repairable, reason, _details}), do: {:repairable, Atom.to_string(reason)}

  def failure_class({:prompt_version_mismatch, _details}),
    do: {:repairable, "configuration"}

  def failure_class({:structured_validation_failed, _details}),
    do: {:terminal, "structured_validation_exhausted"}

  def failure_class(%MemHouse.Model.ProviderCircuit.OpenError{}),
    do: {:retryable, "provider_circuit_open"}

  def failure_class(error) do
    case ProviderFailure.extraction_disposition(error) do
      {:repairable, _reason_class} = repairable -> repairable
      :transient -> {:retryable, "provider_transient"}
    end
  end
end
