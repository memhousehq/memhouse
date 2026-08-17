# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Measurement do
  @moduledoc """
  Captures content-free Account deltas around one evaluation variant.

  Snapshots contain only durable row identities and usage ledger structs. `delta/3` exports
  counts, durations, tokens, errors, and operator-priced cost; it never exports memory text,
  prompts, answers, or unexpected cross-scope ids.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Operations.UsageEvent

  @doc "Returns a content-free snapshot for the evaluation Account."
  def snapshot(account_key) when is_binary(account_key) do
    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account, actor ->
      %{
        knowledge_ids:
          KnowledgeItem
          |> read(account.id, actor)
          |> MapSet.new(& &1.id),
        usages: read(UsageEvent, account.id, actor)
      }
    end)
  end

  @doc "Builds the measured delta between two snapshots and records total wall time."
  def delta(before, after_snapshot, wall_time_ms)
      when is_map(before) and is_map(after_snapshot) and is_integer(wall_time_ms) and
             wall_time_ms >= 0 do
    prior_usage_ids = MapSet.new(before.usages, & &1.id)
    usages = Enum.reject(after_snapshot.usages, &MapSet.member?(prior_usage_ids, &1.id))
    by_role = usages |> Enum.group_by(& &1.model_role) |> Map.new(&role_usage/1)
    totals = usage_totals(usages)

    %{
      "stored_facts" =>
        MapSet.difference(after_snapshot.knowledge_ids, before.knowledge_ids) |> MapSet.size(),
      "wall_time_ms" => wall_time_ms,
      "usage" => %{
        "model_calls" => totals["calls"],
        "input_tokens" => totals["input_tokens"],
        "output_tokens" => totals["output_tokens"],
        "embedding_tokens" => totals["embedding_tokens"],
        "total_tokens" =>
          totals["input_tokens"] + totals["output_tokens"] + totals["embedding_tokens"],
        "duration_ms" => totals["duration_ms"],
        "errors" => totals["errors"],
        "estimated_usd" => estimated_cost(by_role),
        "by_role" => by_role
      }
    }
  end

  defp read(resource, account_id, actor) do
    resource
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  defp role_usage({role, usages}), do: {role, usage_totals(usages)}

  defp usage_totals(usages) do
    Enum.reduce(
      usages,
      %{
        "calls" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "embedding_tokens" => 0,
        "duration_ms" => 0,
        "errors" => 0
      },
      fn usage, totals ->
        %{
          totals
          | "calls" => totals["calls"] + 1,
            "input_tokens" => totals["input_tokens"] + usage.input_tokens,
            "output_tokens" => totals["output_tokens"] + usage.output_tokens,
            "embedding_tokens" => totals["embedding_tokens"] + usage.embedding_tokens,
            "duration_ms" => totals["duration_ms"] + usage.duration_ms,
            "errors" => totals["errors"] + if(usage.status == "error", do: 1, else: 0)
        }
      end
    )
  end

  defp estimated_cost(by_role) do
    rates = Application.get_env(:memhouse, :model_cost_per_million, %{})

    Enum.reduce(by_role, 0.0, fn {role, totals}, cost ->
      role_rates = Map.get(rates, role) || Map.get(rates, safe_existing_atom(role), %{}) || %{}

      cost +
        totals["input_tokens"] * rate(role_rates, :input) / 1_000_000 +
        totals["output_tokens"] * rate(role_rates, :output) / 1_000_000 +
        totals["embedding_tokens"] * rate(role_rates, :embedding) / 1_000_000
    end)
    |> Float.round(8)
  end

  defp rate(rates, key) do
    value = Map.get(rates, key) || Map.get(rates, Atom.to_string(key), 0.0)
    if is_number(value), do: value * 1.0, else: 0.0
  end

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :unknown
  end
end
