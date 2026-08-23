# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Ingest do
  @moduledoc """
  Executes the synchronous or durable batched ingest path for evaluation cases.

  Batched evaluation first commits every raw message and its ordinary extraction
  `PipelineRun`, then drives those durable runs through the real
  `MemHouse.Pipeline.ExtractionBatcher`. Governed knowledge is read back by source
  message after the runs finish; no second extraction call is made.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline.{ExtractionAdmission, ExtractionBatcher}

  require Ash.Query

  @doc "Returns the runner's `{source_message, extraction_result}` tuples."
  def run(messages, account_key, scope_path, opts)
      when is_list(messages) and is_binary(account_key) and is_binary(scope_path) do
    prepared = Enum.map(messages, &{&1, attrs(&1, account_key, scope_path)})
    configured? = ExtractionAdmission.enabled?()
    requested? = Keyword.get(opts, :extraction_batching, configured?)

    if requested? != configured? do
      raise ArgumentError,
            "evaluation extraction batching option does not match the runtime feature switch"
    end

    if requested? do
      run_batched(prepared, account_key)
    else
      run_synchronous(prepared, account_key)
    end
  end

  defp run_synchronous(prepared, account_key) do
    Enum.map(prepared, fn {source, attrs} ->
      result =
        with {:ok, stored} <- Memory.ingest_message(attrs),
             {:ok, knowledge} <- Memory.extract_message(stored["id"], account_key) do
          {:ok, stored, knowledge}
        end

      {source, result}
    end)
  end

  defp run_batched(prepared, account_key) do
    ingested =
      Enum.map(prepared, fn {source, attrs} ->
        {source, Memory.ingest_message(attrs)}
      end)

    stored =
      for {_source, {:ok, message}} <- ingested,
          do: message

    failures =
      for {_source, {:error, error}} <- ingested,
          do: error

    batch_result =
      case failures do
        [] -> execute_pending_runs(account_key, Enum.map(stored, & &1["id"]))
        [_error | _rest] -> {:error, :batch_skipped_after_ingest_failure}
      end

    Enum.map(ingested, fn
      {source, {:error, error}} ->
        {source, {:error, error}}

      {source, {:ok, message}} ->
        result =
          with :ok <- batch_result,
               {:ok, knowledge} <- knowledge_for_message(account_key, message["id"]) do
            {:ok, message, knowledge}
          end

        {source, result}
    end)
  end

  defp execute_pending_runs(_account_key, []), do: :ok

  defp execute_pending_runs(account_key, message_ids) do
    runs =
      DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                   actor ->
        extraction_runs(account.id, actor, message_ids)
      end)

    Enum.reduce_while(runs, :ok, fn run, :ok ->
      case ExtractionBatcher.run(run) do
        {:ok, %{status: status}} when status in ["processed", "delegated"] ->
          {:cont, :ok}

        {:ok, %{status: status}} ->
          {:halt, {:error, {:extraction_batch_failed, status}}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp extraction_runs(account_id, actor, message_ids) do
    PipelineRun
    |> Ash.Query.filter(
      kind == "extraction" and target_type == "message" and target_id in ^message_ids and
        status in ["pending", "failed"]
    )
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor, page: [limit: length(message_ids)])
    |> Map.fetch!(:results)
  end

  defp knowledge_for_message(account_key, message_id) do
    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account, actor ->
      items =
        KnowledgeItem
        |> Ash.Query.filter(^message_id in source_message_ids)
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor)
        |> Enum.map(&public_map/1)

      {:ok, items}
    end)
  end

  defp attrs(message, account_key, scope_path) do
    message
    |> Map.take([:peer_key, :session_id, :role, :content, :occurred_at])
    |> Map.update!(:session_id, &"#{scope_path}:#{&1}")
    |> Map.put(:scope_path, scope_path)
    |> Map.put(:account_key, account_key)
  end

  defp public_map(record) do
    record.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Enum.map(& &1.name)
    |> then(&Map.take(record, &1))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
