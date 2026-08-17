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
  alias MemHouse.Observability
  alias MemHouse.Observations.Message
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.ExtractionAdmission
  alias MemHouse.Pipeline.Extractor

  require Ash.Query

  @doc "Processes the message named by an extraction PipelineRun."
  def run(run) do
    started_at = System.monotonic_time(:millisecond)
    result = do_run(run)
    emit_aggregate(run, result, System.monotonic_time(:millisecond) - started_at)
    result
  end

  defp do_run(run) do
    claim_id = Ecto.UUID.generate()
    actor_opts = [role: :system, pipeline?: true]

    DataLayer.with_account_id(run.account_id, actor_opts, fn _account, actor ->
      Pipeline.claim_extraction_runs(run.account_id, [run.target_id], claim_id, actor)
    end)
    |> case do
      {:ok, [claimed_run]} -> process_claimed(claimed_run, claim_id)
      {:ok, []} -> {:ok, %{status: "delegated", run_status: "delegated"}}
      {:error, error} -> {:error, error}
    end
  end

  defp emit_aggregate(run, result, elapsed_ms) do
    {status, calls, anchors, failures, failure_class} = aggregate_result(result)

    Observability.emit_operation(
      :ingest_batch,
      %{
        anchors: anchors,
        attempts: if(status == "delegated", do: 0, else: 1),
        calls: calls,
        items: anchors,
        failures: failures,
        elapsed_ms: elapsed_ms
      },
      %{
        run_id: run.id,
        version: ExtractionAdmission.config()[:identity],
        status: status,
        failure_class: failure_class,
        account_id: run.account_id,
        scope_id: run.scope_id
      }
    )
  end

  defp aggregate_result({:ok, %{status: "processed", anchors: anchors}}),
    do: {"ok", 1, map_size(anchors), 0, nil}

  defp aggregate_result({:ok, %{status: "delegated"}}),
    do: {"delegated", 0, 0, 0, nil}

  defp aggregate_result({:ok, %{status: status} = result})
       when status in ["repairable", "terminal"] do
    anchors = Map.get(result, :anchor_count, 1)
    {status, 1, anchors, anchors, status}
  end

  defp aggregate_result({:error, error}) do
    {_disposition, reason_class} = failure_class(error)
    {"failed", 1, 1, 1, reason_class}
  end

  defp process_claimed(run, claim_id) do
    anchor = Memory.prepare_message_extraction_for_account(run.target_id, run.account_id)

    prepared =
      [anchor | adjacent_candidates(anchor, run.account_id)]
      |> fit_request()

    case prepared do
      [] ->
        mark_all([run], "repairable", "oversized", ExtractionAdmission.config()[:identity])
        {:ok, %{status: "repairable", run_status: "persisted", anchor_count: 1}}

      selected ->
        claim_and_extract(run, claim_id, selected)
    end
  end

  defp claim_and_extract(run, claim_id, [anchor | siblings]) do
    identity = ExtractionAdmission.config()[:identity]
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

    case Extractor.extract_batch(prepared) do
      {:ok, results} ->
        statuses =
          Enum.map(results, fn result ->
            result_run = Map.fetch!(runs, result.anchor_id)
            result_anchor = Enum.find(prepared, &(&1.message["id"] == result.anchor_id))

            Memory.persist_message_extraction_result!(
              result_run,
              result_anchor.message,
              result,
              result.admission_identity
            )

            status = if result.status == :ok, do: "completed", else: Atom.to_string(result.status)
            {result.anchor_id, status}
          end)
          |> Map.new()

        {:ok, %{status: "processed", run_status: "persisted", anchors: statuses}}

      {:error, error} ->
        case failure_class(error) do
          {:repairable, reason_class} ->
            mark_all(Map.values(runs), "repairable", reason_class, identity)
            {:ok, %{status: "repairable", run_status: "persisted", anchor_count: map_size(runs)}}

          {:terminal, reason_class} ->
            mark_all(Map.values(runs), "terminal", reason_class, identity)
            {:ok, %{status: "terminal", run_status: "persisted", anchor_count: map_size(runs)}}

          {:retryable, reason_class} ->
            # Record every claimed anchor before returning the provider error.
            # AshOban's error callback may run as well; its convergent failed
            # update keeps the same replayable state.
            mark_all(Map.values(runs), "failed", reason_class, identity)
            {:error, error}
        end
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

    case ExtractionAdmission.admit(
           messages,
           MemHouse.Model.Schema.ExtractionBatch.json_schema()
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
    Enum.each(runs, fn run ->
      DataLayer.with_account_id(
        run.account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          {:ok, _run} =
            Pipeline.classify_extraction_run(
              run,
              status,
              reason_class,
              admission_identity,
              actor
            )
        end
      )
    end)
  end

  @doc false
  def failure_class({:repairable, reason, _details}), do: {:repairable, Atom.to_string(reason)}

  def failure_class({:prompt_version_mismatch, _details}),
    do: {:repairable, "configuration"}

  def failure_class({:structured_validation_failed, _details}),
    do: {:terminal, "structured_validation_exhausted"}

  def failure_class(:provider_output_truncated),
    do: {:repairable, "provider_output_truncated"}

  def failure_class(:provider_content_filtered),
    do: {:repairable, "provider_content_filtered"}

  def failure_class(:missing_structured_object),
    do: {:repairable, "missing_structured_object"}

  def failure_class(%{class: class}) when class in [:invalid, :validation],
    do: {:repairable, "configuration"}

  def failure_class(%ReqLLM.Error.API.Request{status: status})
      when status in [400, 401, 403, 404, 405, 422],
      do: {:repairable, "provider_configuration"}

  def failure_class(_error), do: {:retryable, "provider_transient"}
end
