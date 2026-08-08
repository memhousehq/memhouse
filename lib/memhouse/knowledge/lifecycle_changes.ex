# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Knowledge.Changes.RecordTransition do
  @moduledoc """
  Ash change that records lifecycle and audit evidence for a state transition.

  The item update, lifecycle event, audit append, and derived refresh enqueue share the caller's
  transaction. Audit and job metadata stay content-safe.
  """

  use Ash.Resource.Change

  alias MemHouse.Clock
  alias MemHouse.Governance.Audit
  alias MemHouse.Knowledge.LifecycleEvent

  @doc """
  Registers the after-action hook that writes the lifecycle event and the audit entry.

  Returns the changeset. At run time the hook returns `{:ok, knowledge}` on success, or the
  first `{:error, reason}` from the lifecycle or audit write, which aborts the transaction.
  """
  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, knowledge ->
      actor = get_in(changeset.context, [:private, :actor])

      # The pre-update row, captured before Ash applied the new attributes.
      from_state = changeset.data.state
      reason = Ash.Changeset.get_argument(changeset, :reason)
      channel = Ash.Changeset.get_argument(changeset, :channel)

      lifecycle_result =
        LifecycleEvent
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(knowledge.account_id)
        |> Ash.Changeset.for_create(:record, %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          from_state: from_state,
          to_state: knowledge.state,
          reason: reason,
          occurred_at: Clock.utc_now()
        })
        |> Ash.create(actor: actor)

      # Any error here propagates out of the after-action hook and rolls back the state change
      # together with whichever of the two evidence writes already succeeded.
      with {:ok, _lifecycle} <- lifecycle_result,
           {:ok, _audit} <-
             Audit.append(actor, knowledge.account_id, %{
               scope_id: knowledge.scope_id,
               actor_peer_id: Map.get(actor, :peer_id),
               category: "lifecycle",
               action: "knowledge.transitioned",
               resource_type: "knowledge_item",
               resource_id: knowledge.id,
               # The hash stands in for the statement so the audit chain holds no content.
               content_hash: knowledge.statement_hash,
               metadata: %{
                 "from_state" => from_state,
                 "to_state" => knowledge.state,
                 "reason" => reason,
                 "channel" => channel
               }
             }) do
        {:ok, knowledge}
      end
    end)
  end
end
