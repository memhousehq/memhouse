# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.Sweeper do
  @moduledoc """
  Background lifecycle sweeps for one Account: revalidation, expiry, queue
  aging, and confidence decay.

  Sweeps turn due dates and unanswered review into explicit lifecycle states instead of leaving
  stale memory active.

  ## The four sweeps

  * **Revalidation** — active knowledge whose revalidation date has arrived
    moves to `needs_revalidation`, gets a queue row, and — when the item is
    about a specific peer — an inline question addressed to that peer.
  * **Expiry** — knowledge past its expiry date moves to `expired`, unless it
    already sits in a terminal state.
  * **Queue aging** — an overdue validation row is escalated once and given a
    short extension; if it is still unanswered after that, the knowledge is
    auto-rejected. Silence is never read as approval.
  * **Decay** — an unanswered peer question past its deadline marks the
    knowledge `stale` and lowers its confidence rather than deleting it. An
    unanswered question is weak evidence, not proof of falsehood.

  ## Guarantees and constraints

  Each sweep is one Account transaction under a system-pipeline actor. Helpers raise, so failure
  rolls back the sweep and the next run retries the same durable state.

  Due timestamp and state make sweeps repeatable; queue and peer questions upsert by
  knowledge-plus-kind.

  Transitions and queues store only reason codes, channel, hashes, and ids. Statement text appears
  only in the peer question that quotes it to its subject.

  Each transition additionally enqueues derived-cache refresh work (projection
  rebuild, entity re-resolution) through the governance engine, so a large
  sweep produces background follow-up jobs as well as state changes.
  """

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Governance.PeerQuery
  alias MemHouse.Governance.PeerQueue
  alias MemHouse.Governance.ValidationItem
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Pipeline.Consolidator

  require Ash.Query

  @doc """
  Runs one sweep for an Account and reports how many records it touched.

  `kind` selects the work: `"revalidation"` and `"expiry"` each run a single
  sweep, while `"dream_time"` runs all four. Any other value raises
  `FunctionClauseError` — the caller is a scheduled job, so an unknown lane is
  a wiring bug that should fail loudly rather than silently do nothing.

  Returns `{:ok, counts}`. The keys of `counts` depend on `kind`
  (`:revalidation`, `:expiry`, `:aged`, `:decayed`, `:merged`, `:aggregates`), so callers must not assume
  all keys are present. Raises when the underlying transaction fails, which
  rolls back every change the sweep had made so far.
  """
  def run(account_id, kind) when kind in ["revalidation", "expiry", "dream_time"] do
    # One transaction per sweep, with the Account pinned for row-level security
    # and a system pipeline actor: lifecycle transitions and validation-queue
    # writes are pipeline-only and have no human requester behind them.
    DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn account, actor ->
      counts =
        case kind do
          "revalidation" -> %{revalidation: revalidate!(account.id, actor)}
          "expiry" -> %{expiry: expire!(account.id, actor)}
          "dream_time" -> full_sweep(account.id, actor)
        end

      {:ok, counts}
    end)
  end

  # Queue rows created by the revalidation pass are due 14 days out, and the
  # aging pass only looks at rows already past their due date, so no question is
  # escalated before anybody has had a chance to answer it.
  defp full_sweep(account_id, actor) do
    %{
      revalidation: revalidate!(account_id, actor),
      expiry: expire!(account_id, actor),
      aged: age_queue!(account_id, actor),
      decayed: decay_queries!(account_id, actor)
    }
    |> Map.merge(Consolidator.run_account!(account_id, actor))
  end

  # Active knowledge whose revalidation date has passed stops counting as
  # confirmed and acquires a review row. The transition, the queue row, and the
  # peer question commit together with the rest of the sweep or not at all.
  #
  # The queue row's 14-day due date is the answering window; once it passes,
  # `age_queue!` escalates and eventually auto-rejects. A peer question is only
  # created when the item is about an identified peer — there is nobody to ask
  # otherwise, and the item then waits for a curator instead.
  defp revalidate!(account_id, actor) do
    due_knowledge(account_id, actor, :revalidate_after)
    |> Enum.map(fn knowledge ->
      updated =
        Engine.transition!(
          knowledge,
          actor,
          %{state: "needs_revalidation", verification: "stale"},
          reason: "f4_revalidation_due",
          channel: "dream_time"
        )

      validation =
        ValidationItem
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.Changeset.for_create(:enqueue, %{
          knowledge_id: updated.id,
          scope_id: updated.scope_id,
          subject_peer_id: updated.subject_peer_id,
          target_level: updated.target_level,
          kind: "revalidation",
          state: "pending",
          statement_hash: updated.statement_hash,
          confidence: updated.confidence,
          sensitivity: updated.sensitivity,
          due_at: DateTime.add(Clock.utc_now(), 14, :day)
        })
        |> Ash.create!(actor: actor)

      if is_binary(updated.subject_peer_id) do
        PeerQueue.enqueue!(updated, validation, "revalidate", actor)
      end

      updated
    end)
    |> length()
  end

  # Expiry is unconditional and needs no review: the item carried its own end
  # date from the moment it was written.
  defp expire!(account_id, actor) do
    due_knowledge(account_id, actor, :expires_at)
    |> Enum.map(
      &Engine.transition!(
        &1,
        actor,
        %{state: "expired", verification: "expired"},
        reason: "f4_expiry_due",
        channel: "dream_time"
      )
    )
    |> length()
  end

  # Two-stage aging for anything still open past its due date. A row that has
  # never been chased gets one escalation plus 24 more hours; a row that has
  # already been escalated or already had an attempt is auto-rejected together
  # with its knowledge. The bias is deliberate: an unanswered proposal must not
  # ripen into accepted memory just because nobody looked at it.
  defp age_queue!(account_id, actor) do
    now = Clock.utc_now()

    ValidationItem
    |> Ash.Query.filter(
      due_at <= ^now and state in ["pending", "deferred", "awaiting_consent", "escalated"]
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn validation ->
      if validation.state == "escalated" || validation.attempt_count > 0 do
        knowledge = knowledge!(account_id, actor, validation.knowledge_id)

        Engine.transition!(
          knowledge,
          actor,
          %{state: "rejected", verification: "auto_rejected_stale"},
          reason: "f4_pending_auto_reject",
          channel: "dream_time"
        )

        validation
        |> Ash.Changeset.for_update(:decide, %{
          state: "rejected",
          decision: "auto_reject",
          attempt_count: validation.attempt_count + 1,
          decided_at: now
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: actor)
      else
        validation
        |> Ash.Changeset.for_update(:decide, %{
          state: "escalated",
          attempt_count: 1,
          escalated_at: now,
          due_at: DateTime.add(now, 24, :hour)
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: actor)
      end
    end)
    |> length()
  end

  # A peer question that ran out its deadline without an answer degrades the
  # knowledge instead of removing it: state becomes `stale` and confidence
  # drops by 0.15 on the 0.0-1.0 scale, floored at 0.0. Silence means "no
  # longer corroborated", not "false", so repeated misses erode the item over
  # several sweeps rather than retracting it in one step.
  defp decay_queries!(account_id, actor) do
    now = Clock.utc_now()

    PeerQuery
    |> Ash.Query.filter(deadline_at <= ^now and state in ["pending", "delivered"])
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(fn query ->
      knowledge = knowledge!(account_id, actor, query.knowledge_id)

      Engine.transition!(
        knowledge,
        actor,
        %{
          state: "stale",
          verification: "revalidation_missed",
          confidence: max(0.0, knowledge.confidence - 0.15)
        },
        reason: "f4_revalidation_confidence_decay",
        channel: "dream_time"
      )

      query
      |> Ash.Changeset.for_update(:update_delivery_state, %{
        state: "expired",
        attempts: query.attempts + 1
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    end)
    |> length()
  end

  # Selection for both date-driven sweeps. Revalidation only touches `active`
  # items, so an item already awaiting review is not re-queued. Expiry skips
  # the terminal states so an already-closed item is not transitioned again;
  # together these filters are what make repeated sweeps idempotent.
  #
  # The whole due set for the Account is read at once, which keeps the sweep a
  # single pass but also means memory grows with the size of that set.
  defp due_knowledge(account_id, actor, attribute) do
    now = Clock.utc_now()

    query =
      case attribute do
        :revalidate_after ->
          Ash.Query.filter(
            KnowledgeItem,
            revalidate_after <= ^now and state == "active"
          )

        :expires_at ->
          Ash.Query.filter(
            KnowledgeItem,
            expires_at <= ^now and state not in ["expired", "rejected", "retracted", "redacted"]
          )
      end

    query
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  # Queue and question rows only hold the knowledge id, so the referenced item
  # is re-read under the Account tenant before it can be transitioned.
  defp knowledge!(account_id, actor, id) do
    KnowledgeItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end
end
