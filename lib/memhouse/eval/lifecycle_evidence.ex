# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.LifecycleEvidence do
  @moduledoc """
  Builds content-safe lifecycle evidence for one evaluation run.

  The snapshot reads every benchmark case scope with an internal Account actor.
  It therefore includes states hidden from a console operator. It reports all
  public states, including zeroes, and counts exact event edges and reasons.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Governance.AuditEvent
  alias MemHouse.Knowledge.{KnowledgeItem, Lifecycle, LifecycleEvent}
  alias MemHouse.Topology.Scope

  require Ash.Query

  @doc "Returns final-state, transition, and lifecycle-audit distributions for case scopes."
  @spec snapshot(String.t(), [String.t()]) :: map()
  def snapshot(account_key, scope_paths) when is_binary(account_key) and is_list(scope_paths) do
    scope_paths = Enum.reject(scope_paths, &is_nil/1)

    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account, actor ->
      scope_ids =
        Scope
        |> Ash.Query.filter(path in ^scope_paths)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.id)

      knowledge =
        KnowledgeItem
        |> Ash.Query.filter(scope_id in ^scope_ids)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor)

      knowledge_ids = Enum.map(knowledge, & &1.id)

      events =
        LifecycleEvent
        |> Ash.Query.filter(knowledge_item_id in ^knowledge_ids)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor)

      audits =
        AuditEvent
        |> Ash.Query.filter(
          resource_type == "knowledge_item" and resource_id in ^knowledge_ids and
            category == "lifecycle" and
            action in ["knowledge.created", "knowledge.transitioned"]
        )
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor)

      final_counts = Enum.frequencies_by(knowledge, & &1.state)

      exercised_states =
        events
        |> Enum.flat_map(&[&1.from_state, &1.to_state])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      absent_final = Enum.filter(Lifecycle.states(), &(Map.get(final_counts, &1, 0) == 0))
      unexercised = Lifecycle.states() -- exercised_states

      %{
        "visibility" => "internal_account_scope_all_states",
        "final_states" => Map.new(Lifecycle.states(), &{&1, Map.get(final_counts, &1, 0)}),
        "absent_final_states" => absent_final,
        "exercised_states" => Enum.filter(Lifecycle.states(), &(&1 in exercised_states)),
        "unexercised_states" => unexercised,
        "unexercised_reasons" => Map.new(unexercised, &{&1, Lifecycle.absence_reason(&1)}),
        "transitions" => transition_counts(events),
        "audit_transitions" => audit_transition_counts(audits, events),
        "lifecycle_events" => length(events),
        "lifecycle_audit_events" => length(audits)
      }
    end)
  end

  defp transition_counts(events) do
    events
    |> Enum.frequencies_by(&{&1.from_state, &1.to_state, &1.reason})
    |> Enum.map(fn {{from_state, to_state, reason}, count} ->
      %{
        "from_state" => from_state,
        "to_state" => to_state,
        "reason" => reason,
        "count" => count
      }
    end)
    |> Enum.sort_by(&{&1["from_state"] || "", &1["to_state"], &1["reason"]})
  end

  defp audit_transition_counts(audits, events) do
    creation_reasons =
      events
      |> Enum.filter(&is_nil(&1.from_state))
      |> Map.new(&{&1.knowledge_item_id, &1.reason})

    audits
    |> Enum.map(fn audit ->
      metadata = audit.metadata

      if audit.action == "knowledge.created" do
        {nil, metadata["to_state"], Map.get(creation_reasons, audit.resource_id)}
      else
        {metadata["from_state"], metadata["to_state"], metadata["reason"]}
      end
    end)
    |> Enum.frequencies()
    |> Enum.map(fn {{from_state, to_state, reason}, count} ->
      %{
        "from_state" => from_state,
        "to_state" => to_state,
        "reason" => reason,
        "count" => count
      }
    end)
    |> Enum.sort_by(&{&1["from_state"] || "", &1["to_state"], &1["reason"]})
  end
end
