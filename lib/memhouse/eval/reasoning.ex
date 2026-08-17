# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Reasoning do
  @moduledoc """
  Measures one replay-safe dream-time pass for an evaluation Account.

  The helper reads durable counts and the model usage ledger. It never copies
  benchmark text, prompts, answers, or statement content into an eval report.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Governance.ValidationItem
  alias MemHouse.Knowledge.{KnowledgeItem, KnowledgeRelation}
  alias MemHouse.Operations.UsageEvent
  alias MemHouse.Pipeline.DreamTime

  @doc """
  Runs dream-time once, then replays it and returns content-safe accounting.

  A successful replay must have no new durable effect. Provider failures are
  returned to the caller as a terminal failed pass and leave pipeline recovery
  to the normal dream-time workflow.
  """
  def run(account_key) when is_binary(account_key) do
    account_id =
      DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                   _actor ->
        account.id
      end)

    before = snapshot(account_id)

    {measurement, operations} =
      measure_operations(account_id, fn -> run_pass(account_id, before) end)

    Map.put(measurement, "operations", operations)
  end

  defp run_pass(account_id, before) do
    case DreamTime.run(account_id) do
      {:ok, first} ->
        after_first = snapshot(account_id)

        case DreamTime.run(account_id) do
          {:ok, replay} ->
            after_replay = snapshot(account_id)

            %{
              "enabled" => true,
              "attempted" => first.scopes + first.throttled,
              "completed" => first.scopes,
              "throttled" => first.throttled,
              "failed" => 0,
              "replayed" => replay.scopes + replay.throttled,
              "replay_durable_effects" => durable_effects(after_first, after_replay),
              "knowledge_before" => before.knowledge,
              "knowledge_after" => after_first.knowledge,
              "superseded" => after_first.superseded - before.superseded,
              "relations" => relation_counts(after_first.relations, before.relations),
              "deductions" => subtract_counts(after_first.deductions, before.deductions),
              "conflict_validation_items" => after_first.conflicts - before.conflicts,
              "corroboration" => after_first.corroboration,
              "reasoner" => usage_counts(after_first.usages, before.usages)
            }

          {:error, error} ->
            failed(before, error)
        end

      {:error, error} ->
        failed(before, error)
    end
  end

  @doc """
  Combines per-case reasoning measurements without retaining content.
  """
  def merge(measurements) when is_list(measurements) do
    Enum.reduce(measurements, empty(), fn measurement, total ->
      %{
        total
        | "enabled" => total["enabled"] or measurement["enabled"],
          "attempted" => total["attempted"] + measurement["attempted"],
          "completed" => total["completed"] + measurement["completed"],
          "throttled" => total["throttled"] + measurement["throttled"],
          "failed" => total["failed"] + measurement["failed"],
          "replayed" => total["replayed"] + measurement["replayed"],
          "replay_durable_effects" =>
            total["replay_durable_effects"] + measurement["replay_durable_effects"],
          "knowledge_before" => total["knowledge_before"] + measurement["knowledge_before"],
          "knowledge_after" => total["knowledge_after"] + measurement["knowledge_after"],
          "superseded" => total["superseded"] + measurement["superseded"],
          "conflict_validation_items" =>
            total["conflict_validation_items"] + measurement["conflict_validation_items"],
          "relations" => merge_counts(total["relations"], measurement["relations"]),
          "deductions" => merge_counts(total["deductions"], measurement["deductions"]),
          "corroboration" => merge_counts(total["corroboration"], measurement["corroboration"]),
          "operations" => merge_operation_counts(total["operations"], measurement["operations"]),
          "reasoner" => merge_reasoner(total["reasoner"], measurement["reasoner"])
      }
    end)
    |> Map.put("enabled", true)
  end

  defp failed(before, error) do
    %{
      empty()
      | "enabled" => true,
        "attempted" => 1,
        "failed" => 1,
        "knowledge_before" => before.knowledge,
        "knowledge_after" => before.knowledge,
        "reasoner" => Map.put(empty_reasoner(), "error_classes", %{classify(error) => 1})
    }
  end

  defp snapshot(account_id) do
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account, actor ->
      knowledge = read(KnowledgeItem, account_id, actor)
      relations = read(KnowledgeRelation, account_id, actor)
      validations = read(ValidationItem, account_id, actor)
      usages = read(UsageEvent, account_id, actor)

      %{
        knowledge: length(knowledge),
        superseded: Enum.count(knowledge, &(&1.state == "superseded")),
        deductions:
          knowledge
          |> Enum.filter(&is_binary(&1.deduction_key))
          |> histogram(& &1.state),
        corroboration: histogram(knowledge, & &1.corroboration_count),
        relations: histogram(relations, & &1.kind),
        conflicts: Enum.count(validations, &(&1.kind == "conflict")),
        usages: usages
      }
    end)
  end

  defp read(resource, account_id, actor) do
    resource
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp durable_effects(first, replay) do
    abs(replay.knowledge - first.knowledge) +
      abs(replay.superseded - first.superseded) +
      count_distance(first.relations, replay.relations) +
      count_distance(first.deductions, replay.deductions) +
      abs(replay.conflicts - first.conflicts)
  end

  defp relation_counts(after_counts, before_counts),
    do: subtract_counts(after_counts, before_counts)

  defp usage_counts(after_usages, before_usages) do
    before_ids = MapSet.new(before_usages, & &1.id)

    after_usages
    |> Enum.reject(&MapSet.member?(before_ids, &1.id))
    |> Enum.filter(&(&1.model_role == "dream_reasoner"))
    |> Enum.reduce(empty_reasoner(), fn usage, counts ->
      %{
        counts
        | "calls" => counts["calls"] + 1,
          "input_tokens" => counts["input_tokens"] + usage.input_tokens,
          "output_tokens" => counts["output_tokens"] + usage.output_tokens,
          "latency_ms" => counts["latency_ms"] + usage.duration_ms,
          "error_classes" =>
            if(usage.status == "error",
              do:
                Map.update(
                  counts["error_classes"],
                  usage.metadata["error_class"] || "unknown",
                  1,
                  &(&1 + 1)
                ),
              else: counts["error_classes"]
            )
      }
    end)
  end

  defp histogram(rows, fun), do: Enum.frequencies_by(rows, fun) |> stringify_keys()
  defp stringify_keys(counts), do: Map.new(counts, fn {key, value} -> {to_string(key), value} end)
  defp classify(error) when is_atom(error), do: Atom.to_string(error)

  defp classify(error) when is_binary(error),
    do: error |> String.split([" ", ":"], parts: 2) |> hd()

  defp classify(error), do: error |> inspect() |> String.split([" ", ":"], parts: 2) |> hd()

  defp subtract_counts(after_counts, before_counts) do
    Map.new(after_counts, fn {key, value} ->
      {key, max(value - Map.get(before_counts, key, 0), 0)}
    end)
    |> Enum.reject(fn {_key, value} -> value == 0 end)
    |> Map.new()
  end

  defp count_distance(left, right) do
    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.map(&abs(Map.get(left, &1, 0) - Map.get(right, &1, 0)))
    |> Enum.sum()
  end

  defp merge_counts(left, right), do: Map.merge(left, right, fn _key, a, b -> a + b end)

  defp merge_reasoner(left, right) do
    Map.merge(left, right, fn
      "error_classes", a, b -> merge_counts(a, b)
      _key, a, b -> a + b
    end)
  end

  defp merge_operation_counts(left, right) do
    Map.merge(left, right, fn _operation, a, b ->
      Map.merge(a, b, fn _metric, x, y -> x + y end)
    end)
  end

  defp measure_operations(account_id, fun) do
    owner = self()
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, _measurements, metadata, _config ->
          if metadata[:account_id] == account_id and
               metadata[:operation] in ["reasoning_update", "reasoning_synthesis"] do
            send(owner, {ref, metadata[:operation], metadata[:status]})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, collect_operations(ref, %{})}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect_operations(ref, counts) do
    receive do
      {^ref, operation, status} ->
        metrics = %{
          "calls" => 1,
          "completed" => if(status == "ok", do: 1, else: 0),
          "failed" => if(status == "ok", do: 0, else: 1)
        }

        counts =
          Map.update(counts, operation, metrics, fn existing ->
            Map.merge(existing, metrics, fn _metric, a, b -> a + b end)
          end)

        collect_operations(ref, counts)
    after
      0 -> counts
    end
  end

  defp empty do
    %{
      "enabled" => false,
      "attempted" => 0,
      "completed" => 0,
      "throttled" => 0,
      "failed" => 0,
      "replayed" => 0,
      "replay_durable_effects" => 0,
      "knowledge_before" => 0,
      "knowledge_after" => 0,
      "superseded" => 0,
      "relations" => %{},
      "deductions" => %{},
      "conflict_validation_items" => 0,
      "corroboration" => %{},
      "operations" => %{},
      "reasoner" => empty_reasoner()
    }
  end

  defp empty_reasoner,
    do: %{
      "calls" => 0,
      "input_tokens" => 0,
      "output_tokens" => 0,
      "latency_ms" => 0,
      "error_classes" => %{}
    }
end
