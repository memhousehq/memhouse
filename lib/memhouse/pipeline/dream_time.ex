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

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.{KnowledgeItem, Provenance}
  alias MemHouse.Model.Reasoner
  alias MemHouse.Observability
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
    started_at = Clock.monotonic_ms()
    result = do_run(account_id)
    emit_aggregate(account_id, result, Clock.monotonic_ms() - started_at)
    public_result(result)
  end

  defp do_run(account_id) do
    scopes = affected_scopes(account_id)

    Enum.reduce_while(
      scopes,
      {:ok,
       %{
         scopes: 0,
         throttled: 0,
         items: 0,
         relations: 0,
         model_calls: 0,
         input_tokens: 0,
         output_tokens: 0
       }},
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
                  relations: counts.relations + result.relations,
                  model_calls: counts.model_calls + Map.get(result, :model_calls, 0),
                  input_tokens: counts.input_tokens + Map.get(result, :input_tokens, 0),
                  output_tokens: counts.output_tokens + Map.get(result, :output_tokens, 0)
              }}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end
    )
  end

  defp emit_aggregate(account_id, result, elapsed_ms) do
    {status, counts, failures, failure_class} =
      case result do
        {:ok, counts} -> {"ok", counts, 0, nil}
        {:error, error} -> {"failed", %{}, 1, aggregate_failure_class(error)}
      end

    Observability.emit_operation(
      :dream,
      %{
        calls: Map.get(counts, :model_calls, 0),
        input_tokens: Map.get(counts, :input_tokens, 0),
        output_tokens: Map.get(counts, :output_tokens, 0),
        items: Map.get(counts, :items, 0),
        accepted: Map.get(counts, :items, 0) + Map.get(counts, :relations, 0),
        rejected: Map.get(counts, :throttled, 0),
        failures: failures,
        elapsed_ms: elapsed_ms
      },
      %{
        account_id: account_id,
        version: "dream-operations-v1",
        status: status,
        failure_class: failure_class
      }
    )
  end

  defp aggregate_failure_class(%module{}), do: inspect(module)
  defp aggregate_failure_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp aggregate_failure_class(_reason), do: "dream_failed"

  defp public_result({:ok, counts}),
    do: {:ok, Map.take(counts, [:scopes, :throttled, :items, :relations])}

  defp public_result(error), do: error

  @doc false
  def run_scope(account_id, scope_id) do
    run_scope(account_id, scope_id, nil)
  end

  @doc """
  Runs one durable scoped wakeup only if its activity generation is still latest.

  ISO-8601 timestamps and UUID activity ids are validated before any governed
  read or provider call. Invalid or superseded schedules return a skipped result;
  an eligible latest generation follows the ordinary bounded dream-time path.
  """
  def run_scheduled_scope(account_id, scope_id, activity_at, activity_id)
      when is_binary(activity_at) and is_binary(activity_id) do
    with {:ok, activity_at, 0} <- DateTime.from_iso8601(activity_at),
         {:ok, activity_id} <- Ecto.UUID.cast(activity_id) do
      run_scope(account_id, scope_id, {activity_at, activity_id})
    else
      _error -> {:ok, %{status: :skipped, reason: :invalid_schedule}}
    end
  end

  def run_scheduled_scope(_account_id, _scope_id, _activity_at, _activity_id),
    do: {:ok, %{status: :skipped, reason: :invalid_schedule}}

  @doc """
  Returns the stable advisory-lock key shared by dream work for one scope.

  Scheduled, hourly, and manual runs use this key to serialize admission and
  watermark updates without placing source content in the lock identity.
  """
  def scope_lock_key(scope_id), do: "dream-time:#{scope_id}"

  defp run_scope(account_id, scope_id, expected_activity) do
    with {:ok, snapshot} <- snapshot(account_id, scope_id, expected_activity),
         {:ok, reasoning} <- reason(snapshot) do
      apply(account_id, scope_id, snapshot, reasoning)
    end
  end

  # The read phase deliberately ends before retrieval/model work. A provider
  # call may take minutes; holding the Account connection would make a later
  # durable write fail after the billable request had already happened.
  defp snapshot(account_id, scope_id, expected_activity) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      Lock.acquire!(account_id, scope_lock_key(scope_id))

      if current_activity?(account_id, scope_id, expected_activity, actor) do
        eligible_snapshot(account_id, scope_id, actor)
      else
        emit_gate(account_id, scope_id, :skip, :superseded_activity, 0, false)
        {:ok, %{status: :skipped, reason: :superseded_activity}}
      end
    end)
  end

  defp eligible_snapshot(account_id, scope_id, actor) do
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
        prepare_ready_snapshot(account_id, scope_id, actor, watermark, delta, limits)
    end
  end

  defp prepare_ready_snapshot(account_id, scope_id, actor, watermark, delta, limits) do
    # Consolidation is deterministic and commits before the provider call. A
    # provider failure can leave this useful, governed maintenance behind, but
    # cannot advance the reasoning watermark.
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
      # Deterministic consolidation consumed every eligible duplicate. Advance
      # to the original boundary so it is not rediscovered without model work.
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

  defp reason(%{status: :no_delta}), do: {:ok, %{status: :no_delta}}
  defp reason(%{status: :skipped, reason: reason}), do: {:ok, %{status: :skipped, reason: reason}}

  defp reason(snapshot) do
    if MemHouse.Operations.Budget.admit?(snapshot.account_id, snapshot.scope_id, :dream_time) do
      with {:ok, working_set} <- thorough_working_set(snapshot) do
        split_enabled? = Reasoner.split_enabled?()
        synthesis_enabled? = split_enabled? and :synthesis in Reasoner.enabled_operations()

        source_observations =
          if synthesis_enabled?,
            do: source_observations(snapshot, working_set),
            else: %{}

        context = reasoning_context(snapshot, working_set, source_observations)

        input = %{
          delta: serialise(snapshot.delta),
          working_set: serialise(working_set, source_observations)
        }

        result =
          if split_enabled? do
            Reasoner.reason_operations(input, context,
              total_timeout: snapshot.limits.max_elapsed_ms
            )
          else
            # Hourly and manual dream-time retain the established one-call
            # contract unless the split experiment is explicitly enabled.
            Reasoner.reason(input, context,
              total_timeout: snapshot.limits.max_elapsed_ms,
              return_usage: true
            )
          end

        case result do
          {:ok, result, provenance} ->
            {:ok,
             %{
               status: :ready,
               result: result,
               input_ids: Enum.map(working_set, & &1.id),
               operation_usage: operation_usage(provenance)
             }}

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

  defp apply(account_id, scope_id, snapshot, %{
         result: result,
         input_ids: input_ids,
         operation_usage: usage
       }) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      Lock.acquire!(account_id, scope_lock_key(scope_id))
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

      {:ok,
       %{
         status: :completed,
         items: length(items),
         relations: relations,
         model_calls: usage.calls,
         input_tokens: usage.input_tokens,
         output_tokens: usage.output_tokens
       }}
    end)
  end

  defp operation_usage(%{operations: operations}) do
    Enum.reduce(operations, %{calls: 0, input_tokens: 0, output_tokens: 0}, fn operation, acc ->
      usage = Map.get(operation, :usage, %{})

      %{
        calls: acc.calls + 1,
        input_tokens: acc.input_tokens + (Map.get(usage, :input_tokens, 0) || 0),
        output_tokens: acc.output_tokens + (Map.get(usage, :output_tokens, 0) || 0)
      }
    end)
  end

  defp operation_usage(provenance) when is_map(provenance) do
    usage = Map.get(provenance, :usage, %{})

    %{
      calls: 1,
      input_tokens: Map.get(usage, :input_tokens, 0) || 0,
      output_tokens: Map.get(usage, :output_tokens, 0) || 0
    }
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

  defp reasoning_context(snapshot, inputs, source_observations) do
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
            target_level: &1.target_level,
            source_observations: Map.get(source_observations, &1.id, [])
          }
        )
    }
  end

  defp source_observations(snapshot, inputs) do
    input_ids = Enum.map(inputs, & &1.id)

    Provenance
    |> Ash.Query.filter(knowledge_item_id in ^input_ids)
    |> Ash.Query.set_tenant(snapshot.account_id)
    |> Ash.read!(actor: snapshot.actor)
    |> Enum.reduce(%{}, fn provenance, observations ->
      case Provenance.source_observation(provenance) do
        nil ->
          observations

        {source_type, source_id} ->
          source = %{source_type: Atom.to_string(source_type), source_id: source_id}

          Map.update(observations, provenance.knowledge_item_id, [source], fn existing ->
            [source | existing]
          end)
      end
    end)
    |> Map.new(fn {knowledge_id, sources} ->
      {knowledge_id, sources |> Enum.uniq() |> Enum.sort_by(&{&1.source_type, &1.source_id})}
    end)
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
    query = direct_items_query(scope_id)

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

  defp current_activity?(_account_id, _scope_id, nil, _actor), do: true

  defp current_activity?(account_id, scope_id, expected, actor) do
    latest =
      scope_id
      |> direct_items_query()
      |> Ash.Query.sort(updated_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.Query.select([:id, :updated_at])
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    latest && {latest.updated_at, latest.id} == expected
  end

  defp direct_items_query(scope_id) do
    marker = Consolidator.marker()

    KnowledgeItem
    |> Ash.Query.filter(
      scope_id == ^scope_id and state == "active" and is_nil(deleted_at) and
        is_nil(deduction_key) and
        (is_nil(extracting_model) or extracting_model != ^marker)
    )
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

  defp serialise(items, source_observations) do
    Enum.map(items, fn item ->
      item
      |> Map.take([
        :id,
        :statement,
        :kind,
        :confidence,
        :sensitivity,
        :target_level,
        :updated_at
      ])
      |> Map.put(:source_observations, Map.get(source_observations, item.id, []))
    end)
  end

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
