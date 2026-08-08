# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.PeerQueue do
  @moduledoc """
  Asks a person about memory that concerns them, inline, and turns their answer
  into a governed lifecycle change.

  Adds one subject question to an existing tool response and accepts its answer through a tool.

  ## Delivery is best effort and must never degrade a read

  `attach/4` runs after the read under a hard millisecond deadline. Filtering, failure, or timeout
  returns `nil`; question delivery must never delay or fail the read.

  Attachment is filtered before it happens. A question is only offered when the
  peer is not paused, is under both their per-session and rolling 24-hour
  limits, has no unanswered delivery for that question already outstanding, has
  not been asked it again within its cooldown, and the statement shares a word
  with whatever the caller was reading about. Peers may tighten those limits
  themselves; they can never be widened from this module.

  ## An answer through a tool is a claim, not proof

  An answer changes knowledge only when the transcript shows the frozen statement followed by a
  human turn. Unverified answers only defer the timer; they cannot activate, retract, or consent.

  Question text is frozen at creation and compared with what was shown.

  ## Content safety

  Corrections record only a boolean and must return through ingest. Shown text becomes a hash and
  conflict flag. Audit keeps ids, verification class, and flags, never answer content.

  ## Authorization

  `resolve/5` first limits lookup to the caller's peer id. Question and delivery writes use the
  peer; protected knowledge, validation, and transcript work uses a pipeline actor scoped to that
  question.
  """

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Audit
  alias MemHouse.Governance.Engine
  alias MemHouse.Governance.PeerAskPreference
  alias MemHouse.Governance.PeerQuery
  alias MemHouse.Governance.PeerQueryDelivery
  alias MemHouse.Governance.ValidationItem
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Observations.Message
  alias MemHouse.Observations.Session
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.Idempotency

  require Ash.Query

  # Answer deadline in days: allows extended absence without leaving memory unquestioned.
  @default_deadline_days 14

  # Revalidation interval in days: about one quarter, never permanent trust.
  @revalidation_days 90

  @doc """
  Creates the frozen inline question for one knowledge item.

  `knowledge` supplies the subject peer, scope, statement, and statement hash;
  `validation` is the queue row the question belongs to; `kind` is
  `"confirm"`, `"revalidate"`, or `"consent_upward"`, which selects the wording
  the peer sees and the effect a confirmation has. `actor` must be a pipeline
  actor — creating questions is not a peer-facing operation.

  The statement text is copied into the question so the peer is later asked
  exactly what was current at this moment, even if the knowledge changes. The
  row is upserted on knowledge-plus-kind, so re-enqueueing the same question
  re-opens and re-schedules the existing one instead of asking twice.

  Returns the question record and raises on failure, including when the
  knowledge has no subject peer — there is nobody to ask, and the caller is
  expected to have checked.
  """
  def enqueue!(knowledge, validation, kind, actor) do
    PeerQuery
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(knowledge.account_id)
    |> Ash.Changeset.for_create(:enqueue, %{
      validation_item_id: validation.id,
      knowledge_id: knowledge.id,
      scope_id: knowledge.scope_id,
      peer_id: knowledge.subject_peer_id,
      kind: kind,
      statement_text: knowledge.statement,
      statement_hash: knowledge.statement_hash,
      state: "pending",
      attempts: 0,
      last_delivered_at: nil,
      answered_at: nil,
      deadline_at: DateTime.add(Clock.utc_now(), @default_deadline_days, :day)
    })
    |> Ash.create!(actor: actor)
  end

  @doc """
  Offers at most one pending question to the calling peer, or returns `nil`.

  `session_external_id` identifies the caller's session as the client knows it,
  `tool_name` is the read that triggered the attempt (recorded as delivery
  evidence), and `topic` is the caller's query text used to keep the question
  topically close to what they were doing. A `nil` or empty topic makes every
  eligible question relevant.

  Returns a map with `"id"`, `"kind"`, `"statement"`, `"asked_because"`, and an
  `"instruction"` telling the assistant to quote the statement exactly and only
  report back if the human actually answers. Returns `nil` when anything gets in
  the way: unknown session, paused peer, rate limit reached, no relevant
  question, a delivery already outstanding, or the attach deadline expiring.

  It is invoked on the response path of ordinary read tools, so none of those
  conditions raises — they all come back as `nil`. The task deadline in
  milliseconds comes from application config so tests can raise it and stop
  scheduler jitter from making assertions flaky.

  Calling it has side effects when it succeeds: a delivery row is written and
  the question is marked delivered, which is what later transcript
  verification and the rate limits are measured against.
  """
  def attach(actor, session_external_id, tool_name, topic \\ nil) do
    # The lookup runs in a task so it can be abandoned at the deadline:
    # `Task.yield` returns `nil` once the budget is spent. The `rescue`/`catch`
    # clauses below turn a failure raised in this process into `nil` too.
    task =
      Task.async(fn ->
        DataLayer.with_actor(actor, fn account, current_actor ->
          do_attach(account.id, current_actor, session_external_id, tool_name, topic)
        end)
      end)

    case Task.yield(task, attach_deadline_ms()) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        nil

      # Over the deadline: kill the work rather than let a slow queue lookup
      # keep holding up a read that has already produced its answer.
      nil ->
        Task.shutdown(task, :brutal_kill)
        nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  @doc """
  Records a peer's answer to their own inline question and applies its effect.

  `id` must be a question addressed to the calling peer; the lookup filters on
  the caller's peer id, so another peer's question is simply
  `{:error, :not_found}`. `verdict` is one of:

  * `"confirm"` — the statement is still true. On a verified channel this
    activates the knowledge, nudges confidence up, and resets the revalidation
    clock; for a consent question it grants the subject's consent to share
    upward into the requested scope.
  * `"reject"` — the statement is wrong. On a verified channel the knowledge is
    retracted.
  * `"unsure"` — closes the question and changes nothing.
  * `"skip"` — not now. The question returns to the queue; once the attempt
    limit is reached it expires and the item escalates to a curator instead of
    being asked again forever.

  Any other verdict returns `{:error, :invalid_verdict}` without touching
  anything.

  `shown_text` is what the assistant claims it displayed. It is never stored:
  only its hash is kept, plus a flag when it differs from the frozen statement.
  `correction_text` is likewise not stored and cannot create knowledge — only
  the fact that a correction was offered is recorded. A correction has to come
  back as an ordinary observation and pass governance like anything else.

  Confirm and reject take effect only when the session transcript proves the
  human was actually shown the statement and replied. Without that proof the
  answer merely defers the question and pushes the revalidation timer out.

  Returns `{:ok, %{id:, verdict:, verification:, effect:}}`, where
  `verification` is `"verified"` or `"unverified_channel"` and `effect` names
  what actually happened. Raises if the question has no outstanding delivery to
  answer, or if any governed write fails; the whole resolution runs in one
  transaction, so a raise leaves the question unanswered rather than half
  applied.
  """
  def resolve(actor, id, verdict, shown_text \\ nil, correction_text \\ nil)

  def resolve(actor, id, verdict, shown_text, correction_text)
      when verdict in ["confirm", "reject", "unsure", "skip"] do
    DataLayer.with_actor(actor, fn account, current_actor ->
      query =
        PeerQuery
        |> Ash.Query.filter(id == ^id and peer_id == ^current_actor.peer_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: current_actor)

      if is_nil(query),
        do: {:error, :not_found},
        else: resolve_query(query, current_actor, verdict, shown_text, correction_text)
    end)
  end

  def resolve(_actor, _id, _verdict, _shown_text, _correction_text),
    do: {:error, :invalid_verdict}

  @doc """
  Lets a peer make themselves harder to interrupt.

  `attrs` may carry `:max_per_session`, `:max_per_day`, and `:paused_until`.
  The update is one-directional by design: new maxima are clamped to the
  current values, so this call can only lower them, and a pause is accepted
  only when it reaches further into the future than the existing one. A peer
  therefore cannot be talked into raising their own interruption budget, and
  nothing on this path can widen it on their behalf.

  Creates the peer's preference row with the configured defaults if they have
  none yet. Returns the updated preference and raises on failure.
  """
  def restrict_preferences(actor, attrs) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      preference = preference!(account.id, current_actor)

      preference
      |> Ash.Changeset.for_update(:restrict, attrs)
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.update!(actor: current_actor)
    end)
  end

  # Every gate below is a reason not to interrupt someone. The `with` is
  # tagged so each failure is distinguishable while debugging, but they all
  # collapse to the same outcome: no question is attached and the read is
  # returned untouched.
  defp do_attach(account_id, actor, session_external_id, tool_name, topic) do
    with {:session, %Session{} = session} <-
           {:session, session_for_peer(account_id, actor, session_external_id)},
         {:preference, preference} <- {:preference, preference!(account_id, actor)},
         {:paused, false} <- {:paused, paused?(preference)},
         {:rate, true} <-
           {:rate, inside_rate_limits?(account_id, actor, session.id, preference)},
         {:query, %PeerQuery{} = query} <- {:query, next_query(account_id, actor, topic)},
         {:delivery, false} <- {:delivery, live_delivery?(account_id, actor, query.id)} do
      delivered_at = Clock.utc_now()

      # The delivery row is the anchor for everything that follows: transcript
      # verification only considers messages at or after this timestamp, and
      # the rate limits count these rows.
      _delivery =
        PeerQueryDelivery
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.Changeset.for_create(:deliver, %{
          peer_query_id: query.id,
          scope_id: query.scope_id,
          peer_id: actor.peer_id,
          session_id: session.id,
          tool_name: tool_name,
          delivered_at: delivered_at,
          verification: "pending"
        })
        |> Ash.create!(actor: actor)

      query
      |> Ash.Changeset.for_update(:update_delivery_state, %{
        state: "delivered",
        last_delivered_at: delivered_at
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)

      %{
        "id" => query.id,
        "kind" => query.kind,
        "statement" => query.statement_text,
        "asked_because" => asked_because(query.kind),
        "instruction" =>
          "Quote the statement exactly, ask whether it is still true, and call resolve_validation only if the user answers."
      }
    else
      _other -> nil
    end
  end

  # Verification is decided first and drives everything after it. `conflict`
  # flags that the assistant displayed something other than the frozen
  # statement — the answer is still recorded, but a curator can see that the
  # question the human heard was not the question that was asked.
  defp resolve_query(query, actor, verdict, shown_text, correction_text) do
    delivery = latest_delivery!(query, actor)
    verified = transcript_verified?(query, delivery, actor)
    verification = if verified, do: "verified", else: "unverified_channel"

    conflict =
      is_binary(shown_text) && normalize(shown_text) != normalize(query.statement_text)

    delivery =
      delivery
      |> Ash.Changeset.for_update(:answer, %{
        shown_text_hash: if(is_binary(shown_text), do: Audit.content_hash(shown_text)),
        verification: verification,
        answered_at: Clock.utc_now(),
        verdict: verdict,
        conflict: conflict
      })
      |> Ash.Changeset.set_tenant(query.account_id)
      |> Ash.update!(actor: actor)

    # The catch-all is the load-bearing clause: an unverified confirm or reject
    # falls through to a deferral. Only a transcript-backed answer may change
    # what the system believes.
    outcome =
      case verdict do
        "skip" -> skip!(query, actor)
        "unsure" -> close_without_change!(query, actor, "unsure")
        "confirm" when verified -> confirm!(query, actor)
        "reject" when verified -> reject!(query, actor)
        _unverified -> defer_unverified!(query, actor)
      end

    # Ids, the verification class, and a boolean for whether a correction was
    # offered. The statement is represented by its hash and the correction text
    # never appears at all.
    Audit.append!(actor, query.account_id, %{
      scope_id: query.scope_id,
      actor_peer_id: actor.peer_id,
      category: "gate",
      action: "peer_validation.#{verdict}",
      resource_type: "peer_query",
      resource_id: query.id,
      content_hash: query.statement_hash,
      metadata: %{
        "delivery_id" => delivery.id,
        "verification" => verification,
        "correction_supplied" => is_binary(correction_text) && correction_text != "",
        "statement_evidence" => "peer_query_frozen_text"
      }
    })

    # Follow-up analysis of the answer happens in the background. The key is
    # derived from the question and session, so a retried or replayed
    # resolution reuses the same run instead of queueing duplicate work.
    {:ok, _run} =
      Pipeline.enqueue(
        "answer_correlation",
        query.account_id,
        %{
          scope_id: query.scope_id,
          target_type: "peer_query_delivery",
          target_id: delivery.id,
          idempotency_key: Idempotency.answer_correlation(query.id, delivery.session_id),
          payload: %{
            "peer_query_id" => query.id,
            "delivery_id" => delivery.id,
            "verification" => verification
          }
        },
        actor
      )

    {:ok,
     %{
       id: query.id,
       verdict: verdict,
       verification: verification,
       effect: outcome
     }}
  end

  # Consent is not the same act as confirmation: the peer is not saying the
  # statement is true, they are permitting it to travel to a wider scope. It is
  # recorded against that specific target scope and marked verified, since this
  # clause is only reached on a transcript-backed answer. If consent cannot be
  # recorded the answer degrades to a deferral rather than silently sharing.
  defp confirm!(%{kind: "consent_upward"} = query, actor) do
    validation = validation!(query, actor)

    case Engine.subject_consent(
           actor,
           query.knowledge_id,
           validation.target_scope_id,
           "grant",
           true,
           "mcp"
         ) do
      {:ok, _consent} ->
        close_query!(query, actor, "answered")
        "consent_granted"

      {:error, _reason} ->
        defer_unverified!(query, actor)
    end
  end

  # A verified confirmation is the strongest evidence available: the subject
  # themself said so. Confidence rises by 0.1 on the 0.0-1.0 scale, capped at
  # 1.0, and the item is trusted again for the standard revalidation period.
  # The decision row and its audit event are what make this reviewable later —
  # the knowledge alone would not show who confirmed it or through which
  # channel.
  defp confirm!(query, actor) do
    knowledge = knowledge!(query, actor)

    updated =
      Engine.transition!(
        knowledge,
        pipeline_actor(actor),
        %{
          state: "active",
          verification: "subject_confirmed",
          confidence: min(1.0, knowledge.confidence + 0.1),
          revalidate_after: DateTime.add(Clock.utc_now(), @revalidation_days, :day)
        },
        reason: "f4_peer_verified_confirm",
        channel: "mcp"
      )

    close_query!(query, actor, "answered")
    resolve_validation!(query, actor, "approved", "peer_confirm")

    Engine.record_decision!(
      pipeline_actor(actor),
      updated,
      query.validation_item_id,
      "gate_a",
      "keep",
      from_state: knowledge.state,
      to_state: updated.state,
      to_level: updated.target_level,
      channel: "mcp",
      verified: true,
      metadata: %{"peer_id" => actor.peer_id}
    )

    "knowledge_confirmed"
  end

  # Retracted, not deleted. The subject's denial is itself a governed decision
  # with an audit trail, and the row has to survive for that trail to mean
  # anything; actually removing content is a separate erasure operation.
  defp reject!(query, actor) do
    knowledge = knowledge!(query, actor)

    updated =
      Engine.transition!(
        knowledge,
        pipeline_actor(actor),
        %{state: "retracted", verification: "subject_rejected"},
        reason: "f4_peer_verified_reject",
        channel: "mcp"
      )

    close_query!(query, actor, "answered")
    resolve_validation!(query, actor, "rejected", "peer_reject")

    Engine.record_decision!(
      pipeline_actor(actor),
      updated,
      query.validation_item_id,
      "gate_a",
      "reject",
      from_state: knowledge.state,
      to_state: updated.state,
      to_level: updated.target_level,
      channel: "mcp",
      verified: true,
      metadata: %{"peer_id" => actor.peer_id}
    )

    "knowledge_retracted"
  end

  # The channel could not be trusted, so nothing about the knowledge changes
  # except its timer: 7 days of quiet before it is raised again, and the
  # question goes back to pending with its attempt counted. This is the only
  # effect an unverified confirm or reject can ever have.
  defp defer_unverified!(query, actor) do
    knowledge = knowledge!(query, actor)

    Engine.transition!(
      knowledge,
      pipeline_actor(actor),
      %{revalidate_after: DateTime.add(Clock.utc_now(), 7, :day)},
      reason: "f4_unverified_channel_defer",
      channel: "mcp"
    )

    query
    |> Ash.Changeset.for_update(:update_delivery_state, %{
      state: "pending",
      attempts: query.attempts + 1
    })
    |> Ash.Changeset.set_tenant(query.account_id)
    |> Ash.update!(actor: actor)

    "timer_deferred_only"
  end

  defp close_without_change!(query, actor, verdict) do
    close_query!(query, actor, "answered")
    "#{verdict}_closed"
  end

  # "Not now" is respected, but only so many times. Once the attempt limit is
  # reached the question stops being asked and the item moves to a curator, so
  # a peer who never wants to answer is not nagged and the item is not left
  # unresolved forever.
  defp skip!(query, actor) do
    attempts = query.attempts + 1

    if attempts >= max_attempts() do
      query
      |> Ash.Changeset.for_update(:update_delivery_state, %{
        state: "expired",
        attempts: attempts
      })
      |> Ash.Changeset.set_tenant(query.account_id)
      |> Ash.update!(actor: actor)

      validation = validation!(query, pipeline_actor(actor))

      validation
      |> Ash.Changeset.for_update(:decide, %{
        state: "escalated",
        escalated_at: Clock.utc_now(),
        attempt_count: validation.attempt_count + 1
      })
      |> Ash.Changeset.set_tenant(query.account_id)
      |> Ash.update!(actor: pipeline_actor(actor))

      "escalated_to_curator"
    else
      query
      |> Ash.Changeset.for_update(:update_delivery_state, %{
        state: "pending",
        attempts: attempts
      })
      |> Ash.Changeset.set_tenant(query.account_id)
      |> Ash.update!(actor: actor)

      "pending_after_skip"
    end
  end

  defp close_query!(query, actor, state) do
    query
    |> Ash.Changeset.for_update(:update_delivery_state, %{
      state: state,
      answered_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(query.account_id)
    |> Ash.update!(actor: actor)
  end

  # Closes the shared curator/peer queue row that the question belonged to, so
  # a peer's answer also removes the item from the human review queue. Runs as
  # a pipeline actor because the queue row is not peer-writable.
  defp resolve_validation!(query, actor, state, decision) do
    validation!(query, pipeline_actor(actor))
    |> Ash.Changeset.for_update(:decide, %{
      state: state,
      decision: decision,
      decided_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(query.account_id)
    |> Ash.update!(actor: pipeline_actor(actor))
  end

  # A client-supplied session id is only ever resolved together with the
  # caller's own peer id, so one peer cannot name another peer's session and
  # have a question delivered into it.
  defp session_for_peer(account_id, actor, external_id) do
    Session
    |> Ash.Query.filter(external_id == ^external_id and peer_id == ^actor.peer_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: pipeline_actor(actor))
  end

  # Peers start with the configured defaults (3 questions per session, 10 per
  # rolling day) the first time they are considered for a question. The row is
  # created eagerly so that a later restriction has something to clamp against.
  defp preference!(account_id, actor) do
    existing =
      PeerAskPreference
      |> Ash.Query.filter(peer_id == ^actor.peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    existing ||
      PeerAskPreference
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.Changeset.for_create(:ensure, %{
        peer_id: actor.peer_id,
        max_per_session: governance_config(:max_per_session, 3),
        max_per_day: governance_config(:max_per_day, 10)
      })
      |> Ash.create!(actor: actor)
  end

  # Two independent budgets: questions already delivered in this session, and
  # questions delivered in the last 24 hours. The daily window rolls from the
  # current moment rather than resetting at midnight, so a burst cannot be
  # doubled by asking again just after a date boundary.
  defp inside_rate_limits?(account_id, actor, session_id, preference) do
    deliveries =
      PeerQueryDelivery
      |> Ash.Query.filter(peer_id == ^actor.peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    day_start = Clock.utc_now() |> DateTime.add(-1, :day)
    session_count = Enum.count(deliveries, &(&1.session_id == session_id))
    day_count = Enum.count(deliveries, &(DateTime.compare(&1.delivered_at, day_start) != :lt))

    session_count < preference.max_per_session && day_count < preference.max_per_day
  end

  defp paused?(%{paused_until: nil}), do: false
  defp paused?(preference), do: DateTime.compare(preference.paused_until, Clock.utc_now()) == :gt

  # Most urgent first: earliest deadline, then oldest. The cooldown and
  # relevance filters are applied while walking that order, so the chosen
  # question is the most pressing one that is also worth mentioning right now.
  defp next_query(account_id, actor, topic) do
    PeerQuery
    |> Ash.Query.filter(peer_id == ^actor.peer_id and state in ["pending", "delivered"])
    |> Ash.Query.sort(deadline_at: :asc, inserted_at: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.find(&(cooldown_elapsed?(&1) && relevant?(&1.statement_text, topic)))
  end

  # One question is only ever in flight once. Re-delivering it while an earlier
  # delivery is still unanswered would make it ambiguous which delivery a later
  # answer refers to, and transcript verification is anchored to a delivery.
  defp live_delivery?(account_id, actor, query_id) do
    PeerQueryDelivery
    |> Ash.Query.filter(peer_query_id == ^query_id and is_nil(answered_at))
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.any?()
  end

  # An answer must belong to a delivery: raising here rejects a resolve call
  # for a question that was never actually put to the peer, which is exactly
  # the case an agent inventing answers would produce.
  defp latest_delivery!(query, actor) do
    PeerQueryDelivery
    |> Ash.Query.filter(peer_query_id == ^query.id and is_nil(answered_at))
    |> Ash.Query.sort(delivered_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(query.account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: PeerQueryDelivery
      delivery -> delivery
    end
  end

  # The proof that a human, not the agent, answered the question.
  #
  # Reads the session transcript from the delivery moment onward and looks for
  # an assistant turn that actually contains the frozen statement, followed
  # within a small number of turns by a user turn. Both halves matter: the
  # first shows the person was told what was being asked, the second shows they
  # said something afterwards. Matching is done on normalised text so casing,
  # unicode form, whitespace, and surrounding quotes cannot defeat it, and
  # containment rather than equality is used because assistants wrap the
  # statement in their own phrasing.
  #
  # This is intentionally cheap and approximate; it cannot prove the user's
  # reply was about the question. It exists to make silent self-confirmation by
  # an agent impossible, not to adjudicate meaning. The transcript is read with
  # an elevated actor because the answering peer has no direct read access to
  # stored messages.
  defp transcript_verified?(query, delivery, actor) do
    messages =
      Message
      |> Ash.Query.filter(
        session_id == ^delivery.session_id and occurred_at >= ^delivery.delivered_at
      )
      |> Ash.Query.sort(occurred_at: :asc, id: :asc)
      |> Ash.Query.set_tenant(query.account_id)
      |> Ash.read!(actor: pipeline_actor(actor))

    messages
    |> Enum.with_index()
    |> Enum.any?(fn
      {%{role: "assistant"} = message, index} ->
        shown? =
          String.contains?(normalize(message.content), normalize(query.statement_text))

        answer? =
          messages
          |> Enum.drop(index + 1)
          |> Enum.take(answer_window_turns())
          |> Enum.any?(&(&1.role == "user"))

        shown? && answer?

      _other ->
        false
    end)
  end

  defp knowledge!(query, actor) do
    KnowledgeItem
    |> Ash.Query.filter(id == ^query.knowledge_id)
    |> Ash.Query.set_tenant(query.account_id)
    |> Ash.read_one!(actor: pipeline_actor(actor))
  end

  defp validation!(query, actor) do
    ValidationItem
    |> Ash.Query.filter(id == ^query.validation_item_id)
    |> Ash.Query.set_tenant(query.account_id)
    |> Ash.read_one!(actor: actor)
  end

  # A crude but deliberate topicality test: one shared word is enough. The
  # point is to avoid an obviously unrelated interruption, not to rank
  # questions — being too strict here would leave the queue undelivered.
  defp relevant?(_statement, topic) when topic in [nil, ""], do: true

  defp relevant?(statement, topic) do
    statement_tokens = tokens(statement)
    topic_tokens = tokens(topic)
    MapSet.size(MapSet.intersection(statement_tokens, topic_tokens)) > 0
  end

  # Words of one or two characters are dropped: articles and pronouns overlap
  # between almost any two sentences and would make everything look relevant.
  defp tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  # Shared normalisation for both the transcript check and the shown-text
  # conflict check, so the two always agree on what "the same statement" means.
  # NFKC folds compatibility characters, casing and runs of whitespace are
  # flattened, and the assorted straight and curly quote characters are trimmed
  # from the ends because assistants habitually add them when quoting.
  defp normalize(text) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim(~s("“”'‘’ ))
  end

  # The one-line reason shown alongside the question. There is no fallback
  # clause: an unknown kind raises rather than producing a question the peer
  # cannot make sense of.
  defp asked_because("confirm"), do: "This proposed memory needs your confirmation."
  defp asked_because("revalidate"), do: "This memory is due for revalidation."
  defp asked_because("consent_upward"), do: "Sharing this personal memory requires your consent."

  # Milliseconds allowed for the whole attach attempt. 15 ms is a budget, not a
  # measurement: it is small enough to be invisible next to a read that already
  # did database and model work, and it makes an overloaded queue silently
  # yield instead of adding latency. Tests raise it so scheduler jitter cannot
  # turn a deterministic assertion into a flake.
  defp attach_deadline_ms do
    governance_config(:attach_deadline_ms, 15)
  end

  # Times a peer may skip one question before it goes to a curator instead.
  defp max_attempts, do: governance_config(:max_attempts, 2)

  # How many transcript turns after the statement was shown may still contain
  # the human's reply. Six covers an assistant that keeps talking for a few
  # turns without stretching so far that an unrelated later reply counts.
  defp answer_window_turns, do: governance_config(:answer_window_turns, 6)

  # Per-question cooldown: 48 hours by default between delivery attempts, so a
  # peer who let one go by yesterday does not meet it again today. A question
  # that has never been delivered is always eligible.
  defp cooldown_elapsed?(%{last_delivered_at: nil}), do: true

  defp cooldown_elapsed?(query) do
    cutoff =
      DateTime.add(
        Clock.utc_now(),
        -governance_config(:attempt_cooldown_hours, 48),
        :hour
      )

    DateTime.compare(query.last_delivered_at, cutoff) != :gt
  end

  # All interruption tuning lives under one application config key so an
  # operator can adjust it in one place; the defaults passed in at each call
  # site keep the module working with no configuration at all.
  defp governance_config(key, default) do
    :memhouse
    |> Application.get_env(:governance, [])
    |> Keyword.get(key, default)
  end

  # The answering peer normally cannot read the knowledge item, its validation
  # row, or the stored transcript, yet resolving their own question requires
  # all three. The elevated copy is used only after the caller's identity has
  # already been matched against the question's peer id.
  defp pipeline_actor(%MemHouse.Actor{} = actor),
    do: %{actor | role: :system, scope_ids: :all, pipeline?: true}

  defp pipeline_actor(actor),
    do: actor |> Map.put(:role, :system) |> Map.put(:pipeline?, true)
end
