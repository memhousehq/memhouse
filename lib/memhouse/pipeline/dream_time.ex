# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.DreamTime do
  @moduledoc """
  Runs incremental, replay-safe dream-time reasoning one scope at a time.

  The Account job is only a dispatcher. Each scope takes its own advisory lock,
  reads the durable input watermark, and calls the provider outside a database
  transaction. A second short transaction applies governed output, schedules
  derived-cache refreshes, and advances the watermark together.

  Provider and write errors leave the watermark unchanged. A later run then
  reuses the same input. The run key includes the scope watermark, role, and
  prompt identity so retries do not create a second pass.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Clock
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Model.Reasoner
  alias MemHouse.Operations.DreamTimeWatermark
  alias MemHouse.Pipeline.{Consolidator, DeductionEffects, Idempotency, Lock, ReasoningEffects}
  alias MemHouse.Pipeline.DreamTime.Gate
  alias MemHouse.Retrieval
  alias MemHouse.Retrieval.Query

  require Ash.Query

  @epoch ~U[1970-01-01 00:00:00.000000Z]

  defmodule InvalidCandidate do
    @moduledoc """
    Identifies a retrieval result that does not satisfy the knowledge candidate contract.

    The error contains only the candidate position and reason. It never copies
    statement text or other candidate content into logs or durable job state.
    """

    defexception [:position, :reason]

    @doc false
    @impl true
    def message(%__MODULE__{position: position, reason: reason}) do
      "invalid dream-time retrieval candidate at position #{position}: #{reason}"
    end
  end

  @doc """
  Dispatches one incremental pass for every Account scope that has new active knowledge.

  Returns `{:ok, counts}`. A provider or durable-write failure returns an error
  and leaves that scope watermark unchanged, so the durable job can retry.
  """
  def run(account_id) do
    scopes = affected_scopes(account_id)

    Enum.reduce_while(
      scopes,
      {:ok, %{scopes: 0, throttled: 0, items: 0, relations: 0}},
      fn scope_id, {:ok, counts} ->
        case run_scope(account_id, scope_id) do
          {:ok, %{status: :no_delta}} ->
            {:cont, {:ok, counts}}

          {:ok, %{status: :skipped}} ->
            {:cont, {:ok, counts}}

          {:ok, %{status: :throttled}} ->
            {:cont, {:ok, %{counts | throttled: counts.throttled + 1}}}

          {:ok, result} ->
            {:cont,
             {:ok,
              %{
                counts
                | scopes: counts.scopes + 1,
                  items: counts.items + result.items,
                  relations: counts.relations + result.relations
              }}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    )
  end

  @doc false
  def run_scope(account_id, scope_id) do
    with {:ok, snapshot} <- snapshot(account_id, scope_id),
         {:ok, reasoning} <- reason(snapshot) do
      apply(account_id, scope_id, snapshot, reasoning)
    end
  end

  # The read phase deliberately ends before retrieval/model work. A provider
  # call may take minutes; holding the Account connection would make a later
  # durable write fail after the billable request had already happened.
  defp snapshot(account_id, scope_id) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      Lock.acquire!(account_id, lock_key(scope_id))
      watermark = watermark(account_id, scope_id, actor)
      delta = changed_items(account_id, scope_id, watermark, actor)
      latest_change_at = delta |> List.last() |> then(&(&1 && &1.updated_at))
      config = Application.fetch_env!(:memhouse, :dream_time_gates)

      case Gate.decide(
             length(delta),
             latest_change_at,
             watermark.last_completed_at,
             Clock.utc_now(),
             config
           ) do
        {:skip, reason} ->
          emit_gate(account_id, scope_id, :skip, reason, length(delta), false)
          status = if reason == :no_delta, do: :no_delta, else: :skipped
          {:ok, %{status: status, reason: reason}}

        {:run, limits} ->
          # Consolidation is deterministic and commits before the provider call.
          # A provider failure can leave this useful, governed maintenance behind,
          # but cannot advance the reasoning watermark.
          original_boundary = delta |> Enum.take(limits.max_delta_items) |> List.last()
          Consolidator.run_scope!(account_id, scope_id, actor)
          delta = changed_items(account_id, scope_id, watermark, actor)
          inputs = active_items(account_id, scope_id, actor)

          selected_delta = Enum.take(delta, limits.max_delta_items)
          boundary = List.last(selected_delta)

          if boundary do
            partial? = length(delta) > length(selected_delta)
            emit_gate(account_id, scope_id, :run, :eligible, length(delta), partial?)

            {:ok,
             %{
               status: :ready,
               account_id: account_id,
               scope_id: scope_id,
               actor: actor,
               watermark: watermark,
               input_watermark: boundary.updated_at,
               input_watermark_id: boundary.id,
               delta: selected_delta,
               inputs: Enum.take(inputs, limits.max_working_set_items),
               limits: limits,
               partial?: partial?
             }}
          else
            # Deterministic consolidation consumed every eligible duplicate.
            # Advancing to the original boundary prevents that same maintenance
            # from being rediscovered while no model work was performed.
            advance!(
              account_id,
              scope_id,
              original_boundary.updated_at,
              original_boundary.id,
              actor
            )

            emit_gate(account_id, scope_id, :skip, :consolidated, length(delta), false)
            {:ok, %{status: :no_delta, reason: :consolidated}}
          end
      end
    end)
  end

  defp reason(%{status: :no_delta}), do: {:ok, %{status: :no_delta}}
  defp reason(%{status: :skipped, reason: reason}), do: {:ok, %{status: :skipped, reason: reason}}

  defp reason(snapshot) do
    if MemHouse.Operations.Budget.admit?(snapshot.account_id, snapshot.scope_id, :dream_time) do
      with {:ok, working_set} <- thorough_working_set(snapshot) do
        context = reasoning_context(snapshot, working_set)

        case Reasoner.reason_operations(
               %{delta: serialise(snapshot.delta), working_set: serialise(working_set)},
               context,
               total_timeout: snapshot.limits.max_elapsed_ms
             ) do
          {:ok, result, _provenance} ->
            {:ok, %{status: :ready, result: result, input_ids: Enum.map(working_set, & &1.id)}}

          {:error, error} ->
            {:error, error}
        end
      end
    else
      {:ok, %{status: :throttled}}
    end
  end

  defp apply(_account_id, _scope_id, _snapshot, %{status: :no_delta}),
    do: {:ok, %{status: :no_delta, items: 0, relations: 0}}

  defp apply(_account_id, _scope_id, _snapshot, %{status: :skipped, reason: reason}),
    do: {:ok, %{status: :skipped, reason: reason, items: 0, relations: 0}}

  defp apply(_account_id, _scope_id, _snapshot, %{status: :throttled}),
    do: {:ok, %{status: :throttled, items: 0, relations: 0}}

  defp apply(account_id, scope_id, snapshot, %{result: result, input_ids: input_ids}) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      Lock.acquire!(account_id, lock_key(scope_id))
      # Applying a stale response is safe because the watermark advances only
      # to the snapshot boundary. New rows remain a delta for the next pass.
      items = Enum.map(result.items, &DeductionEffects.apply!(&1, account_id, scope_id, actor))

      relations =
        ReasoningEffects.complete!(
          account_id,
          scope_id,
          input_ids,
          result.relations,
          actor
        )

      advance!(
        account_id,
        scope_id,
        snapshot.input_watermark,
        snapshot.input_watermark_id,
        actor
      )

      # The governing transitions above enqueue the same per-scope derived work
      # with deterministic watermarks. This explicit pair covers relation-only
      # output too and coalesces with any transition-triggered refresh.
      refresh!(account_id, scope_id, snapshot.input_watermark, actor)

      {:ok, %{status: :completed, items: length(items), relations: relations}}
    end)
  end

  defp affected_scopes(account_id) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      KnowledgeItem
      |> Ash.Query.filter(state == "active" and is_nil(deleted_at))
      |> Ash.Query.select([:scope_id])
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.scope_id)
      |> Enum.uniq()
    end)
  end

  defp thorough_working_set(snapshot) do
    query = %Query{
      account_id: snapshot.account_id,
      actor: snapshot.actor,
      text: Enum.map_join(snapshot.delta, "\n", & &1.statement),
      target: :knowledge,
      scope_ids: [snapshot.scope_id],
      max_candidates: snapshot.limits.max_working_set_items,
      # Reasoning over the scope's corpus is done on nobody's behalf, so it must
      # not be narrowed to a reader that does not exist.
      internal_reader?: true
    }

    retrieved =
      Retrieval.retrieve(query, :thorough, deadline?: false, internal?: true, concurrent?: false)

    with {:ok, ids} <- candidate_ids(retrieved.candidates) do
      records = load_candidates(snapshot, ids)

      {:ok,
       Enum.uniq_by(snapshot.inputs ++ records, & &1.id)
       |> Enum.take(snapshot.limits.max_working_set_items)}
    end
  end

  @doc false
  def candidate_ids(candidates) when is_list(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"candidate_type" => "knowledge", "id" => id}, position}, {:ok, ids}
      when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, id} ->
            {:cont, {:ok, [id | ids]}}

          :error ->
            {:halt,
             {:error, %InvalidCandidate{position: position, reason: "invalid knowledge id"}}}
        end

      {%{"candidate_type" => "knowledge"}, position}, _acc ->
        {:halt, {:error, %InvalidCandidate{position: position, reason: "missing knowledge id"}}}

      {%{"candidate_type" => _type}, position}, _acc ->
        {:halt,
         {:error, %InvalidCandidate{position: position, reason: "unexpected candidate type"}}}

      {_candidate, position}, _acc ->
        {:halt, {:error, %InvalidCandidate{position: position, reason: "missing knowledge id"}}}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp load_candidates(snapshot, ids) do
    records_by_id =
      KnowledgeItem
      |> Ash.Query.filter(
        id in ^ids and scope_id == ^snapshot.scope_id and state == "active" and is_nil(deleted_at)
      )
      |> Ash.Query.set_tenant(snapshot.account_id)
      |> Ash.read!(actor: snapshot.actor)
      |> Map.new(&{&1.id, &1})

    Enum.flat_map(ids, fn id ->
      case Map.fetch(records_by_id, id) do
        {:ok, record} -> [record]
        :error -> []
      end
    end)
  end

  defp reasoning_context(snapshot, inputs) do
    {sensitivity, target_level} =
      snapshot.delta
      |> Enum.map(&{&1.sensitivity, &1.target_level})
      |> Enum.max_by(fn {sensitivity, target_level} -> {sensitivity, target_level} end)

    %{
      account_id: snapshot.account_id,
      scope_id: snapshot.scope_id,
      actor: snapshot.actor,
      reasoning_inheritance: %{sensitivity: sensitivity, target_level: target_level},
      reasoning_inputs:
        Enum.map(
          inputs,
          &%{
            id: &1.id,
            account_id: &1.account_id,
            scope_id: &1.scope_id,
            state: &1.state,
            sensitivity: &1.sensitivity,
            target_level: &1.target_level
          }
        )
    }
  end

  defp watermark(account_id, scope_id, actor) do
    DreamTimeWatermark
    |> Ash.Query.filter(scope_id == ^scope_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil ->
        %{input_watermark: @epoch, input_watermark_id: nil, last_completed_at: nil}

      watermark ->
        %{
          input_watermark: watermark.input_watermark,
          input_watermark_id: watermark.input_watermark_id,
          last_completed_at: watermark.updated_at
        }
    end
  end

  defp changed_items(account_id, scope_id, watermark, actor) do
    query =
      KnowledgeItem
      |> Ash.Query.filter(
        scope_id == ^scope_id and state == "active" and is_nil(deleted_at) and
          is_nil(deduction_key) and
          (is_nil(extracting_model) or extracting_model != "system:dream-time-consolidator")
      )

    query =
      if watermark.input_watermark_id do
        Ash.Query.filter(
          query,
          updated_at > ^watermark.input_watermark or
            (updated_at == ^watermark.input_watermark and id > ^watermark.input_watermark_id)
        )
      else
        Ash.Query.filter(query, updated_at > ^watermark.input_watermark)
      end

    query
    |> Ash.Query.sort(updated_at: :asc, id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp active_items(account_id, scope_id, actor) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id == ^scope_id and state == "active" and is_nil(deleted_at))
    |> Ash.Query.sort(updated_at: :desc, id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp advance!(account_id, scope_id, value, value_id, actor) do
    existing =
      DreamTimeWatermark
      |> Ash.Query.filter(scope_id == ^scope_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    if existing do
      existing
      |> Ash.Changeset.for_update(:advance, %{
        input_watermark: value,
        input_watermark_id: value_id
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    else
      DreamTimeWatermark
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.Changeset.for_create(:start, %{
        scope_id: scope_id,
        input_watermark: value,
        input_watermark_id: value_id
      })
      |> Ash.create!(actor: actor)
    end
  end

  defp refresh!(account_id, scope_id, watermark, actor) do
    value = DateTime.to_iso8601(watermark)

    Enum.each(
      [
        {"projection_refresh", Idempotency.projection_refresh(scope_id, value)},
        {"entity_resolution", Idempotency.entity_resolution(scope_id, value)}
      ],
      fn {kind, idempotency_key} ->
        {:ok, _run} =
          MemHouse.Pipeline.enqueue(
            kind,
            account_id,
            %{
              scope_id: scope_id,
              target_type: "scope",
              target_id: scope_id,
              idempotency_key: idempotency_key,
              payload: %{"watermark" => value}
            },
            actor
          )
      end
    )
  end

  defp serialise(items) do
    Enum.map(items, fn item ->
      Map.take(item, [
        :id,
        :statement,
        :kind,
        :confidence,
        :sensitivity,
        :target_level,
        :updated_at
      ])
    end)
  end

  defp lock_key(scope_id), do: "dream-time:#{scope_id}"

  defp emit_gate(account_id, scope_id, decision, reason, delta_count, partial?) do
    :telemetry.execute(
      [:memhouse, :pipeline, :dream_gate],
      %{eligible_changes: delta_count},
      %{
        account_id: account_id,
        scope_id: scope_id,
        decision: decision,
        reason: reason,
        partial: partial?
      }
    )
  end
end
