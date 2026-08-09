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
  alias MemHouse.Governance.Engine
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Model.Reasoner
  alias MemHouse.Operations.DreamTimeWatermark
  alias MemHouse.Pipeline.{Consolidator, Idempotency, Lock, ReasoningEffects}
  alias MemHouse.Retrieval
  alias MemHouse.Retrieval.Query

  require Ash.Query

  @epoch ~U[1970-01-01 00:00:00.000000Z]
  @working_set_limit 50

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

      if delta == [] do
        {:ok, %{status: :no_delta}}
      else
        # Consolidation is deterministic and commits before the provider call.
        # A provider failure can leave this useful, governed maintenance behind,
        # but cannot advance the reasoning watermark.
        Consolidator.run_scope!(account_id, scope_id, actor)
        delta = changed_items(account_id, scope_id, watermark, actor)
        inputs = active_items(account_id, scope_id, actor)

        {:ok,
         %{
           status: :ready,
           account_id: account_id,
           scope_id: scope_id,
           actor: actor,
           watermark: watermark,
           input_watermark: Enum.max_by(delta, & &1.updated_at).updated_at,
           delta: Enum.take(delta, @working_set_limit),
           inputs: Enum.take(inputs, @working_set_limit)
         }}
      end
    end)
  end

  defp reason(%{status: :no_delta}), do: {:ok, %{status: :no_delta}}

  defp reason(snapshot) do
    if MemHouse.Operations.Budget.admit?(snapshot.account_id, snapshot.scope_id, :dream_time) do
      working_set = thorough_working_set(snapshot)
      context = reasoning_context(snapshot, working_set)

      case Reasoner.reason(
             %{delta: serialise(snapshot.delta), working_set: serialise(working_set)},
             context
           ) do
        {:ok, result, _provenance} ->
          {:ok, %{status: :ready, result: result, input_ids: Enum.map(working_set, & &1.id)}}

        {:error, error} ->
          {:error, error}
      end
    else
      {:ok, %{status: :throttled}}
    end
  end

  defp apply(_account_id, _scope_id, _snapshot, %{status: :no_delta}),
    do: {:ok, %{status: :no_delta, items: 0, relations: 0}}

  defp apply(_account_id, _scope_id, _snapshot, %{status: :throttled}),
    do: {:ok, %{status: :throttled, items: 0, relations: 0}}

  defp apply(account_id, scope_id, snapshot, %{result: result, input_ids: input_ids}) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      Lock.acquire!(account_id, lock_key(scope_id))
      # Applying a stale response is safe because the watermark advances only
      # to the snapshot boundary. New rows remain a delta for the next pass.
      items = Enum.map(result.items, &apply_item!(&1, account_id, scope_id, actor))

      relations =
        ReasoningEffects.complete!(
          account_id,
          scope_id,
          input_ids,
          result.relations,
          actor
        )

      advance!(account_id, scope_id, snapshot.input_watermark, actor)
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
      max_candidates: @working_set_limit
    }

    retrieved =
      Retrieval.retrieve(query, :thorough, deadline?: false, internal?: true, concurrent?: false)

    records = Enum.map(retrieved.candidates, & &1.record)
    Enum.uniq_by(snapshot.inputs ++ records, & &1.id) |> Enum.take(@working_set_limit)
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
          &%{id: &1.id, account_id: &1.account_id, scope_id: &1.scope_id, state: &1.state}
        )
    }
  end

  defp apply_item!(item, account_id, scope_id, actor) do
    subject = subject!(item, account_id, scope_id, actor)

    knowledge =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        scope_id: scope_id,
        subject_peer_id: subject.peer_id,
        subject_scope_id: subject.scope_id,
        statement: item.statement,
        kind: item.kind,
        confidence: item.confidence,
        # A deduction is never a direct observation, even when every input was
        # direct. This prevents Gate A from auto-placing a model conclusion.
        evidence_level: "indirect",
        sensitivity: item.sensitivity,
        state: "proposed",
        target_level: item.target_level,
        verification: "pending",
        source_message_ids: item.source_message_ids || [],
        expires_at: item.expires_at,
        revalidate_after: item.revalidate_after,
        relevant_from: item.relevant_from,
        relevant_until: item.relevant_until,
        extracting_provider: item.provider,
        extracting_model: item.model,
        extracting_model_version: item.model_version,
        prompt_version: item.prompt_version,
        pipeline_version: item.pipeline_version
      })
      |> Ash.create!(actor: actor)

    Engine.evaluate_proposal(knowledge, actor)
  end

  defp subject!(%{subject_type: "scope"}, _account_id, scope_id, _actor),
    do: %{peer_id: nil, scope_id: scope_id}

  defp subject!(item, account_id, _scope_id, actor) do
    peer =
      MemHouse.Accounts.Peer
      |> Ash.Query.filter(key == ^item.subject_ref)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    if is_nil(peer), do: raise(ArgumentError, "reasoner referenced an unknown peer")
    %{peer_id: peer.id, scope_id: nil}
  end

  defp watermark(account_id, scope_id, actor) do
    DreamTimeWatermark
    |> Ash.Query.filter(scope_id == ^scope_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> @epoch
      watermark -> watermark.input_watermark
    end
  end

  defp changed_items(account_id, scope_id, watermark, actor) do
    KnowledgeItem
    |> Ash.Query.filter(
      scope_id == ^scope_id and state == "active" and is_nil(deleted_at) and
        updated_at > ^watermark
    )
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

  defp advance!(account_id, scope_id, value, actor) do
    existing =
      DreamTimeWatermark
      |> Ash.Query.filter(scope_id == ^scope_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    if existing do
      existing
      |> Ash.Changeset.for_update(:advance, %{input_watermark: value})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    else
      DreamTimeWatermark
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.Changeset.for_create(:start, %{scope_id: scope_id, input_watermark: value})
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
end
