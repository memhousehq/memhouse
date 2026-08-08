# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.Engine do
  @moduledoc """
  The Gate A/B decision engine: the only place knowledge changes governance state.

  Gate A decides whether to keep a proposal from derived source evidence. Gate B decides
  its visibility from target level, sensitivity, and corroboration. Rules resolve
  from scope to Account to a conservative human-review fallback.

  Accepted proposals become `active`; rejected rows remain as evidence; deferred
  peer items become subject-only `provisional`, while wider items remain `held`
  and absent from retrieval. Wider personal knowledge also requires verified,
  target-specific subject consent. A curator cannot replace that consent.

  Only authenticated human curators may approve, edit, reject, merge, or defer.
  Curator edits create a replacement through the pipeline and pass the gates
  again. Advisory locks serialize competing decisions.

  The caller owns the Account-scoped transaction. State, lifecycle, audit, and
  derived-work enqueue must commit together. Internal functions that accept a
  pipeline actor do not authorize the caller; public entry points must do so
  before elevation. Audit metadata and job arguments contain hashes and
  identifiers, never statement text.
  """

  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Audit
  alias MemHouse.Governance.Consent
  alias MemHouse.Governance.GateDecision
  alias MemHouse.Governance.GateRule
  alias MemHouse.Governance.PeerQueue
  alias MemHouse.Governance.ValidationItem
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.KnowledgeRelation
  alias MemHouse.Knowledge.Provenance
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.Idempotency
  alias MemHouse.Pipeline.Lock
  alias MemHouse.Topology.Scope

  require Ash.Query

  # The complete set of curator verbs. `decide/4` guards on this list, so an unknown verb
  # raises FunctionClauseError rather than silently doing nothing to a queued item.
  @human_actions ~w(approve edit reject merge defer)

  @doc """
  Runs Gate A and Gate B over a freshly proposed knowledge item and applies the outcome.

  `knowledge` is a just-created `MemHouse.Knowledge.KnowledgeItem` in state `"proposed"`.
  `actor` is the pipeline actor of the ingest run. Options:

    * `:target_level` — how far the item is being proposed (`"peer"`, `"scope"`, or
      `"account"`). Defaults to the item's own target level, then to `"peer"`.
    * `:target_scope_id` — the scope the item wants to live in when the target level is above
      peer. Held items record it so a curator can see where the request points, and it is the
      scope a consent grant is bound to.

  Returns the updated knowledge item in every branch — activated, rejected, or parked in a
  pending state with a validation queue entry (and, for a peer subject, a peer question)
  created alongside it.

  Raises if the knowledge write, the queue write, the audit append, or a job enqueue fails;
  because the caller supplies the transaction, that failure rolls the whole proposal back.
  """
  def evaluate_proposal(knowledge, actor, opts \\ []) do
    target_level = Keyword.get(opts, :target_level, knowledge.target_level || "peer")

    # A direct scope-level proposal already names its destination by where the
    # knowledge row lives. Keep that id on the validation item too, so a later
    # curator approval can find the matching consent and place the item. A peer
    # proposal has no target scope, and account-level placement remains a
    # separate target.
    target_scope_id =
      Keyword.get(opts, :target_scope_id) ||
        if(target_level == "scope", do: knowledge.scope_id)

    rule = matching_rule(knowledge, target_level, actor)

    # Deadline for a human to act, in hours from now, taken from the matrix cell (the built-in
    # fallback allows 168 h = 7 days). Only the deferred branch uses it.
    due_at = DateTime.add(Clock.utc_now(), rule.pending_max_age_hours, :hour)

    case proposal_outcome(knowledge, rule, target_level, target_scope_id, actor) do
      {:reject, _consent} ->
        knowledge
        |> transition!(actor, %{state: "rejected", verification: "auto_rejected"},
          reason: "f4_gate_a_auto_reject",
          channel: "pipeline"
        )
        |> tap(fn updated ->
          record_decision!(
            actor,
            updated,
            nil,
            "gate_a",
            "reject",
            from_state: knowledge.state,
            to_state: updated.state,
            to_level: target_level,
            channel: "pipeline",
            verified: true,
            metadata: %{"rule_id" => rule_id(rule)}
          )
        end)

      {:accept, _consent} ->
        knowledge
        |> transition!(
          actor,
          %{
            state: "active",
            target_level: target_level,
            verification: "auto_verified",
            held_scope_id: nil,
            revalidate_after: revalidate_at(rule)
          },
          reason: "f4_gate_a_b_auto_accept",
          channel: "pipeline"
        )
        |> tap(fn updated ->
          record_decision!(
            actor,
            updated,
            nil,
            "gate_a",
            "keep",
            from_state: knowledge.state,
            to_state: updated.state,
            to_level: target_level,
            channel: "pipeline",
            verified: true,
            metadata: %{"rule_id" => rule_id(rule)}
          )

          record_decision!(
            actor,
            updated,
            nil,
            "gate_b",
            "place",
            from_state: knowledge.state,
            to_state: updated.state,
            to_level: target_level,
            channel: "pipeline",
            verified: true,
            metadata: %{"rule_id" => rule_id(rule)}
          )
        end)

      {:defer, _consent} ->
        # A peer-level item may be shown back to its own subject while it waits, so it becomes
        # provisional. Anything aimed above peer level is held at its source scope and stays
        # invisible to retrieval until a human decides; that is what stops an unreviewed claim
        # from reaching a wider audience just by being proposed.
        pending_state = if target_level == "peer", do: "provisional", else: "held"

        updated =
          transition!(
            knowledge,
            actor,
            %{
              state: pending_state,
              target_level: target_level,
              verification: "pending_human",
              held_scope_id: target_scope_id
            },
            reason: "f4_gate_a_b_deferred",
            channel: "pipeline"
          )

        validation =
          enqueue_validation!(
            updated,
            actor,
            target_level,
            target_scope_id,
            due_at,
            "gate_a_b"
          )

        # A statement about a person is best checked by that person, so a peer-level item with
        # a known subject also gets a confirmation question routed to them.
        if target_level == "peer" && is_binary(updated.subject_peer_id) do
          PeerQueue.enqueue!(updated, validation, "confirm", actor)
        end

        # Consent, if this item owes any, was already resolved by proposal_outcome/5 above —
        # either a real subject's request is now pending, or (for a declared-auto Account or an
        # unattended deployment) a real granted row was already written on the subject's
        # behalf. Resolving it there rather than here means it happens exactly once per
        # proposal regardless of which branch of this case is taken.

        record_decision!(
          actor,
          updated,
          validation.id,
          "gate_a",
          "defer",
          from_state: knowledge.state,
          to_state: updated.state,
          to_level: target_level,
          channel: "pipeline",
          verified: false,
          metadata: %{"rule_id" => rule_id(rule)}
        )

        record_decision!(
          actor,
          updated,
          validation.id,
          "gate_b",
          if(target_level == "peer", do: "provisional", else: "hold"),
          from_state: knowledge.state,
          to_state: updated.state,
          to_level: target_level,
          channel: "pipeline",
          verified: false,
          metadata: %{"rule_id" => rule_id(rule)}
        )

        updated
    end
  end

  @doc """
  Applies one curator decision to one queued validation item.

  `action` is `"approve"`, `"edit"`, `"reject"`, `"merge"`, or `"defer"`; any other value
  raises `FunctionClauseError`. `opts` may use atom or string keys and is read per action:

    * `"statement"` (required for `"edit"`) — the corrected text; blank text is rejected.
    * `"sensitivity"` (optional for `"edit"`) — overrides the replacement's sensitivity.
    * `"merge_into_id"` (required for `"merge"`) — the surviving knowledge item.
    * `"defer_hours"` (optional for `"defer"`) — hours to push the deadline out; a
      non-positive or unparseable value falls back to 24 hours.

  Returns a map keyed by action: approve gives
  `%{knowledge:, validation:, consent_required:}` where a `true` flag means nothing moved
  because subject consent is still missing; edit gives `%{knowledge:, replacement:,
  validation:}`; merge gives `%{knowledge:, merge_target:, validation:}`; reject and defer
  give `%{knowledge:, validation:}`.

  Raises `Ash.Error.Forbidden` unless the caller is a password-session account admin or
  curator — machine credentials must never reach a curator verb. Raises
  `Ash.Error.Query.NotFound` for an unknown validation item or knowledge item, `KeyError`
  when a required option is absent, and `ArgumentError` for a blank edited statement.
  """
  def decide(actor, validation_id, action, opts \\ %{})
      when is_binary(validation_id) and action in @human_actions do
    require_human_curator!(actor)
    opts = stringify_keys(opts)

    DataLayer.with_actor(actor, fn account, current_actor ->
      # Transaction-scoped advisory lock: two curators clicking the same queue row serialize
      # here instead of both writing a decision. Released automatically at commit or rollback.
      Lock.acquire!(account.id, "validation:#{validation_id}")
      validation = validation!(account.id, current_actor, validation_id)
      knowledge = knowledge!(account.id, current_actor, validation.knowledge_id)

      case action do
        "approve" -> approve!(knowledge, validation, current_actor, opts)
        "edit" -> edit!(knowledge, validation, current_actor, opts)
        "reject" -> reject!(knowledge, validation, current_actor)
        "merge" -> merge!(knowledge, validation, current_actor, opts)
        "defer" -> defer!(knowledge, validation, current_actor, opts)
      end
    end)
  end

  @doc """
  Applies the same curator decision to several queued items, one at a time.

  Returns `[{validation_id, result_of_decide}]` in the order given. Called outside an enclosing
  transaction, each item is decided in its own, so a raise on the fifth leaves the first four
  committed and aborts the rest; callers wanting all-or-nothing must not use this function.
  """
  def bulk_decide(actor, validation_ids, action, opts \\ %{})
      when is_list(validation_ids) and action in @human_actions do
    Enum.map(validation_ids, fn validation_id ->
      {validation_id, decide(actor, validation_id, action, opts)}
    end)
  end

  @doc """
  Asks to move an existing knowledge item up to a wider ancestor scope.

  This does not promote anything by itself. The item is parked in `"held"` at the target
  scope with a Gate B queue entry, so a second human decision through `decide/4` is still
  required. Personal knowledge with a known subject additionally opens a consent request and
  routes a consent question to that subject.

  Returns `%{knowledge:, validation:, consent:}` where `consent` is `nil` when no subject
  consent applies. The queue entry is due in 168 hours (7 days), the same window the built-in
  conservative matrix cell uses.

  Raises `Ash.Error.Forbidden` unless the caller is a password-session account admin or
  curator *and* holds an admin or curator role on the target scope itself — authority over
  the narrow scope an item lives in does not confer authority to widen it. Raises
  `ArgumentError` when the target is not a strict ancestor of the item's current scope, and
  `Ash.Error.Query.NotFound` for unknown ids.
  """
  def request_promotion(actor, knowledge_id, target_scope_id) do
    require_human_curator!(actor)

    DataLayer.with_actor(actor, fn account, current_actor ->
      knowledge = knowledge!(account.id, current_actor, knowledge_id)
      source_scope = scope!(account.id, current_actor, knowledge.scope_id)
      target_scope = scope!(account.id, current_actor, target_scope_id)

      require_scope_curator!(current_actor, target_scope_id)

      # Promotion may only widen exposure along the containment tree. Sideways or downward
      # moves are rejected because they would relocate knowledge into a scope whose members
      # were never part of the original audience decision.
      unless wider_scope?(source_scope.path, target_scope.path),
        do: raise(ArgumentError, "Gate B promotion target must be a strict ancestor scope")

      held =
        transition!(
          knowledge,
          current_actor,
          %{state: "held", target_level: "scope", held_scope_id: target_scope_id},
          reason: "f4_gate_b_promotion_requested",
          channel: "human_ui"
        )

      # 168 hours = 7 days for a second human to act on the promotion request.
      due_at = DateTime.add(Clock.utc_now(), 168, :hour)

      validation =
        enqueue_validation!(held, current_actor, "scope", target_scope_id, due_at, "gate_b")

      result =
        if held.sensitivity == "personal" && is_binary(held.subject_peer_id) do
          # request_promotion/3 always widens by definition, so matching_rule/3 here only
          # satisfies resolve_consent/5's signature — consent_required?/3 never actually
          # consults rule.requires_consent (see its own comment), so which rule is passed has
          # no bearing on the outcome.
          consent =
            case resolve_consent(
                   held,
                   matching_rule(held, "scope", current_actor),
                   "scope",
                   target_scope_id,
                   current_actor
                 ) do
              {:granted, consent} -> consent
              {:pending, consent} -> consent
              :not_required -> nil
            end

          PeerQueue.enqueue!(held, validation, "consent_upward", pipeline_actor(current_actor))
          %{knowledge: held, validation: validation, consent: consent}
        else
          %{knowledge: held, validation: validation, consent: nil}
        end

      record_decision!(
        current_actor,
        held,
        validation.id,
        "gate_b",
        "hold",
        from_state: knowledge.state,
        to_state: held.state,
        to_level: "scope",
        channel: "human_ui",
        verified: true,
        metadata: %{
          "from_level" => knowledge.target_level,
          "target_scope_id" => target_scope_id,
          "consent_required" => !is_nil(result.consent)
        }
      )

      result
    end)
  end

  @doc """
  Records the subject's own answer to a pending consent request.

  `verdict` is `"grant"` or `"deny"`; anything else raises `FunctionClauseError`. `verified`
  says whether the answer arrived over a channel whose speaker was actually authenticated,
  and `channel` names that channel for the audit trail.

  The consent row is looked up by knowledge item, target scope, and the *calling* peer as
  subject, so one person can never answer on behalf of another. Returns `{:ok, consent}`, or
  `{:error, :verified_channel_required}` when a grant arrives unverified — an unverified
  denial is still recorded, because it must never be harder to refuse exposure than to allow
  it. Raises `Ash.Error.Query.NotFound` when no matching request exists.
  """
  def subject_consent(actor, knowledge_id, target_scope_id, verdict, verified, channel)
      when verdict in ["grant", "deny"] do
    DataLayer.with_actor(actor, fn account, current_actor ->
      consent =
        Consent
        |> Ash.Query.filter(
          knowledge_id == ^knowledge_id and target_scope_id == ^target_scope_id and
            subject_peer_id == ^current_actor.peer_id
        )
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: current_actor)

      if is_nil(consent), do: raise(Ash.Error.Query.NotFound, resource: Consent)

      if verdict == "grant" && !verified do
        {:error, :verified_channel_required}
      else
        updated =
          consent
          |> Ash.Changeset.for_update(:decide, %{
            status: if(verdict == "grant", do: "granted", else: "denied"),
            channel: channel,
            verified: verified,
            decided_by_peer_id: current_actor.peer_id,
            decided_at: Clock.utc_now()
          })
          |> Ash.Changeset.set_tenant(account.id)
          |> Ash.update!(actor: consent_actor(current_actor))

        Audit.append!(current_actor, account.id, %{
          scope_id: updated.scope_id,
          actor_peer_id: current_actor.peer_id,
          category: "gate",
          action: "consent.#{updated.status}",
          resource_type: "knowledge_consent",
          resource_id: updated.id,
          metadata: %{
            "knowledge_id" => knowledge_id,
            "target_scope_id" => target_scope_id,
            "channel" => channel,
            "verified" => verified
          }
        })

        {:ok, updated}
      end
    end)
  end

  @doc """
  Returns the full governance story of one knowledge item.

  The result is `%{knowledge:, gate_decisions:, lifecycle:}` with both lists sorted oldest
  first, so a reader can replay how the item reached its current state.

  Access is controlled by the knowledge read itself: the item is fetched as the calling
  actor, so a caller who cannot see the statement gets `Ash.Error.Query.NotFound` and never
  reaches the history. Once that read succeeds the two history lists are fetched with
  sufficient privilege, because decision and lifecycle rows carry no statement text — only
  states, levels, channels, and hashes.
  """
  def history(actor, knowledge_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      knowledge = knowledge!(account.id, current_actor, knowledge_id)

      decisions =
        GateDecision
        |> Ash.Query.filter(knowledge_id == ^knowledge.id)
        |> Ash.Query.sort(decided_at: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: history_actor(current_actor))

      lifecycle =
        MemHouse.Knowledge.LifecycleEvent
        |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
        |> Ash.Query.sort(occurred_at: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: pipeline_actor(current_actor))

      %{knowledge: knowledge, gate_decisions: decisions, lifecycle: lifecycle}
    end)
  end

  @doc """
  Lists every non-erased knowledge item whose subject is the calling peer, newest first.

  This is the "what does the system say about me?" view, so it deliberately ignores scope
  membership: a person may read statements about themselves even when they hold no role on
  the scope those statements live in. It still shows only their own subject rows, and
  soft-deleted rows stay hidden.

  Requires an actor with a peer id; a system or unauthenticated actor raises
  `FunctionClauseError`.
  """
  def self_view(actor) when is_binary(actor.peer_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      KnowledgeItem
      |> Ash.Query.filter(subject_peer_id == ^current_actor.peer_id and is_nil(deleted_at))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: current_actor)
    end)
  end

  @doc """
  Applies a subject's own verdict to a statement about themselves.

  `action` is one of:

    * `"confirm"` — the statement is right. It becomes `"active"` with confidence 1.0,
      because first-hand confirmation by the subject is the strongest evidence available.
    * `"contest"` — the statement is wrong or disputed. It becomes `"contested"` and a
      validation entry is queued for a human curator, due in 24 hours.
    * `"redact"` — the subject does not want it retained. It becomes `"redacted"`.

  Returns the updated knowledge item. Raises `Ash.Error.Query.NotFound` when the item does
  not exist or the caller is not its subject — the mismatch is reported as "not found" rather
  than "forbidden" so probing for another person's ids reveals nothing.

  The writes run as an internal pipeline actor because subjects are not curators. The
  subject-identity check in the function body is the only thing authorizing them, so it must
  stay ahead of every branch.
  """
  def contest(actor, knowledge_id, action) when action in ["confirm", "contest", "redact"] do
    DataLayer.with_actor(actor, fn account, current_actor ->
      knowledge = knowledge!(account.id, current_actor, knowledge_id)

      if knowledge.subject_peer_id != current_actor.peer_id do
        raise Ash.Error.Query.NotFound, resource: KnowledgeItem
      end

      case action do
        "confirm" ->
          updated =
            transition!(
              knowledge,
              pipeline_actor(current_actor),
              %{state: "active", verification: "subject_confirmed", confidence: 1.0},
              reason: "f4_subject_confirmed",
              channel: "self_view"
            )

          audit_subject_action!(current_actor, updated, action)
          updated

        "contest" ->
          updated =
            transition!(
              knowledge,
              pipeline_actor(current_actor),
              %{state: "contested", verification: "subject_disputed"},
              reason: "f4_subject_contested",
              channel: "self_view"
            )

          # A disputed statement about a person is urgent: 24 hours, far shorter than an
          # ordinary gate review, before the overdue-validation sweep escalates it.
          enqueue_validation!(
            updated,
            pipeline_actor(current_actor),
            updated.target_level,
            updated.held_scope_id,
            DateTime.add(Clock.utc_now(), 24, :hour),
            "contest"
          )

          audit_subject_action!(current_actor, updated, action)
          updated

        "redact" ->
          updated =
            transition!(
              knowledge,
              pipeline_actor(current_actor),
              %{state: "redacted", verification: "subject_redacted"},
              reason: "f4_subject_redacted",
              channel: "self_view"
            )

          audit_subject_action!(current_actor, updated, action)
          updated
      end
    end)
  end

  @doc """
  Applies one lifecycle change to a knowledge item and keeps everything downstream in step.

  This is the single funnel for changing a knowledge item's state, level, scope, confidence,
  sensitivity, or expiry. Aging sweeps, peer answers, document supersession, erasure, and the
  gate paths in this module all go through here, so nothing can move a knowledge item without
  leaving a lifecycle event and an audit entry behind.

  `attrs` are the attributes to change. `opts` must carry `:reason` — a short stable code
  persisted on the lifecycle event and the audit entry, so it is stored data, not a log line
  — and may carry `:channel` (default `"governance"`) naming where the change came from.

  Returns the updated item. After the update it enqueues a projection refresh and an entity
  re-resolution for the item's scope and marks cached context for that scope dirty, because
  those caches are derived from governed knowledge and are now stale. Raises on a failed
  update, a missing `:reason`, or a failed enqueue; run it inside the caller's transaction so
  a later failure cannot leave the state changed but the refreshes unqueued.
  """
  def transition!(knowledge, actor, attrs, opts) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:reason, Keyword.fetch!(opts, :reason))
      |> Map.put(:channel, Keyword.get(opts, :channel, "governance"))

    updated =
      knowledge
      |> Ash.Changeset.for_update(:transition, attrs)
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.update!(actor: actor)

    enqueue_derived_refreshes!(updated, actor)
    updated
  end

  # Projections, entity mentions, and cached context are rebuildable derivations of governed
  # knowledge, so a state change must schedule their rebuild rather than edit them in place.
  #
  # The item's post-update timestamp is the idempotency watermark: replaying the same
  # transition, or two transitions landing on the same scope at the same instant, collapses
  # onto one job instead of queueing duplicate rebuild work.
  defp enqueue_derived_refreshes!(knowledge, actor) do
    watermark = DateTime.to_iso8601(knowledge.updated_at)

    {:ok, _projection_run} =
      Pipeline.enqueue(
        "projection_refresh",
        knowledge.account_id,
        %{
          scope_id: knowledge.scope_id,
          target_type: "scope",
          target_id: knowledge.scope_id,
          idempotency_key: Idempotency.projection_refresh(knowledge.scope_id, watermark),
          payload: %{"knowledge_id" => knowledge.id}
        },
        actor
      )

    {:ok, _entity_run} =
      Pipeline.enqueue(
        "entity_resolution",
        knowledge.account_id,
        %{
          scope_id: knowledge.scope_id,
          target_type: "scope",
          target_id: knowledge.scope_id,
          idempotency_key: Idempotency.entity_resolution(knowledge.scope_id, watermark),
          payload: %{"knowledge_id" => knowledge.id}
        },
        actor
      )

    # Marking the cache dirty is a pipeline-owned write even when a curator triggered it, so
    # the caller's actor is elevated for this call only.
    MemHouse.Context.Builder.mark_dirty(
      knowledge.account_id,
      %{actor | role: :system, pipeline?: true},
      knowledge.scope_id
    )
  end

  @doc """
  Writes one immutable gate-decision row and its audit entry.

  `gate` is `"gate_a"`, `"gate_b"`, or `"gate_a_b"` when a single human action settled both.
  `decision` is the verb that was applied (for example a keep, place, hold, defer, approve,
  reject, merge, or edit). `attrs` is a keyword list that must contain `:from_state`,
  `:to_state`, `:to_level`, `:channel`, and `:verified`, and may contain `:metadata`. A
  `"from_level"` key inside that metadata overrides the recorded previous level, which the
  promotion path uses because the item's level has already been rewritten by then.

  Decision rows are never updated or deleted: the history of how an item was governed must
  stay reconstructible even after the item itself is superseded or erased. Metadata is
  content-safe — ids, states, levels, flags — while the statement itself is represented only
  by its hash.

  Validation routing is decided in the caller's transaction. A deferred proposal has already
  created its `ValidationItem` and, when it has a peer subject, its `PeerQuery`; a decision
  needs no separate continuation to discover either fact. Returns the created decision row and
  raises if either durable write fails, which — inside the caller's transaction — discards the
  state change too.
  """
  def record_decision!(
        actor,
        knowledge,
        validation_item_id,
        gate,
        decision,
        attrs
      ) do
    from_state = Keyword.fetch!(attrs, :from_state)
    to_state = Keyword.fetch!(attrs, :to_state)
    to_level = Keyword.fetch!(attrs, :to_level)
    channel = Keyword.fetch!(attrs, :channel)
    verified = Keyword.fetch!(attrs, :verified)
    metadata = Keyword.get(attrs, :metadata, %{})

    decision_row =
      GateDecision
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.Changeset.for_create(:record, %{
        validation_item_id: validation_item_id,
        knowledge_id: knowledge.id,
        scope_id: knowledge.scope_id,
        gate: gate,
        decision: decision,
        actor_peer_id: Map.get(actor, :peer_id),
        channel: channel,
        verified: verified,
        from_state: from_state,
        to_state: to_state,
        from_level: Map.get(metadata, "from_level", knowledge.target_level),
        to_level: to_level,
        statement_hash: knowledge.statement_hash,
        metadata: metadata,
        decided_at: Clock.utc_now()
      })
      |> Ash.create!(actor: actor)

    Audit.append!(actor, knowledge.account_id, %{
      scope_id: knowledge.scope_id,
      actor_peer_id: Map.get(actor, :peer_id),
      category: "gate",
      action: "#{gate}.#{decision}",
      resource_type: "gate_decision",
      resource_id: decision_row.id,
      content_hash: knowledge.statement_hash,
      metadata: %{
        "knowledge_id" => knowledge.id,
        "validation_item_id" => validation_item_id,
        "from_state" => from_state,
        "to_state" => to_state,
        "to_level" => to_level,
        "channel" => channel,
        "verified" => verified
      }
    })

    decision_row
  end

  # Curator approval. A curator can vouch for accuracy, but cannot consent on a person's
  # behalf: personal knowledge heading to a scope stays exactly where it is until the subject
  # has granted consent over a verified channel. The queue entry records the attempt as
  # `awaiting_consent`; nothing here completes it automatically once consent lands, so the
  # curator has to approve again, and the aging sweep will auto-reject the row if nobody does.
  defp approve!(knowledge, validation, actor, _opts) do
    consent = consent_for(knowledge, validation, actor)

    if knowledge.sensitivity == "personal" && validation.target_level == "scope" &&
         (!consent || consent.status != "granted" || !consent.verified) do
      validation =
        update_validation!(validation, actor, %{
          state: "awaiting_consent",
          decision: "approve",
          decided_at: Clock.utc_now()
        })

      record_decision!(
        actor,
        knowledge,
        validation.id,
        "gate_b",
        "await_consent",
        from_state: knowledge.state,
        to_state: "held",
        to_level: validation.target_level,
        channel: "human_ui",
        verified: true
      )

      %{knowledge: knowledge, validation: validation, consent_required: true}
    else
      # Approving a scope request is also the move: the item is relocated into the requested
      # scope and the hold is cleared, which is what makes it visible to that scope's members.
      # A peer-level approval only activates the item where it already lives.
      attrs =
        if validation.target_level == "scope" do
          %{
            scope_id: validation.target_scope_id,
            state: "active",
            target_level: "scope",
            held_scope_id: nil,
            verification: "curator_approved"
          }
        else
          %{state: "active", verification: "curator_approved"}
        end

      updated =
        transition!(knowledge, actor, attrs,
          reason: "f4_curator_approved",
          channel: "human_ui"
        )

      validation =
        update_validation!(validation, actor, %{
          state: "approved",
          decision: "approve",
          decided_at: Clock.utc_now()
        })

      record_decision!(
        actor,
        updated,
        validation.id,
        "gate_a_b",
        "approve",
        from_state: knowledge.state,
        to_state: updated.state,
        to_level: validation.target_level,
        channel: "human_ui",
        verified: true
      )

      %{knowledge: updated, validation: validation, consent_required: false}
    end
  end

  # Curator rejection. The row is kept and marked rejected rather than deleted, so the audit
  # trail can still show that the claim was seen and turned down.
  defp reject!(knowledge, validation, actor) do
    updated =
      transition!(
        knowledge,
        actor,
        %{state: "rejected", verification: "curator_rejected"},
        reason: "f4_curator_rejected",
        channel: "human_ui"
      )

    validation =
      update_validation!(validation, actor, %{
        state: "rejected",
        decision: "reject",
        decided_at: Clock.utc_now()
      })

    record_decision!(
      actor,
      updated,
      validation.id,
      "gate_a_b",
      "reject",
      from_state: knowledge.state,
      to_state: updated.state,
      to_level: validation.target_level,
      channel: "human_ui",
      verified: true
    )

    %{knowledge: updated, validation: validation}
  end

  # "Not now." Only the queue entry's deadline moves; the knowledge item keeps its current
  # state, which for anything above peer level means it stays held and unretrievable.
  defp defer!(knowledge, validation, actor, opts) do
    # Hours to postpone, defaulting to 24 h and clamping anything unusable back to 24 h,
    # because a zero or negative deadline would make the item instantly overdue.
    hours = opts |> Map.get("defer_hours", 24) |> normalize_positive_integer(24)

    validation =
      update_validation!(validation, actor, %{
        state: "deferred",
        decision: "defer",
        due_at: DateTime.add(Clock.utc_now(), hours, :hour)
      })

    record_decision!(
      actor,
      knowledge,
      validation.id,
      "gate_a_b",
      "defer",
      from_state: knowledge.state,
      to_state: knowledge.state,
      to_level: validation.target_level,
      channel: "human_ui",
      verified: true,
      metadata: %{"defer_hours" => hours}
    )

    %{knowledge: knowledge, validation: validation}
  end

  # Curator correction. A curator never rewrites a stored statement in place: the original is
  # superseded and a brand-new row carries the corrected text, so the original wording, its
  # provenance, and the fact that a human changed it all remain readable afterwards.
  #
  # The replacement is created through the pipeline-only create action and then re-enters
  # `evaluate_proposal/3`, which keeps the rule that knowledge is written by the pipeline and
  # gated on the way in — a curator's wording gets no shortcut past the gates.
  defp edit!(knowledge, validation, actor, opts) do
    statement = opts |> Map.fetch!("statement") |> String.trim()

    if statement == "", do: raise(ArgumentError, "edited statement cannot be blank")

    pipeline = pipeline_actor(actor)

    replacement =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        scope_id: knowledge.scope_id,
        subject_peer_id: knowledge.subject_peer_id,
        subject_scope_id: knowledge.subject_scope_id,
        statement: statement,
        kind: knowledge.kind,
        confidence: knowledge.confidence,
        evidence_level: knowledge.evidence_level,
        sensitivity: Map.get(opts, "sensitivity", knowledge.sensitivity),
        state: "proposed",
        target_level: knowledge.target_level,
        held_scope_id: knowledge.held_scope_id,
        # Points back at the row this text replaces, and keeps the original's source messages
        # so the corrected statement retains its provenance.
        supersedes_id: knowledge.id,
        source_message_ids: knowledge.source_message_ids,
        # An edit corrects wording, never when the claim was true. Dropping the window
        # would silently undate an event that arrived with one, and the replacement is
        # the row retrieval serves from here on.
        relevant_from: knowledge.relevant_from,
        relevant_until: knowledge.relevant_until,
        # No model produced this text; the marker distinguishes curator-authored rows from
        # extracted ones. "f4-1" is the version identity of the governed lifecycle contract
        # (proposals enter as proposed or provisional and are gated). Changing that string is
        # a deliberate contract transition that needs a changelog entry and updated evidence,
        # not a cleanup.
        extracting_model: "human:curator-edit",
        pipeline_version: "f4-1"
      })
      |> Ash.create!(actor: pipeline)

    superseded =
      transition!(
        knowledge,
        pipeline,
        %{state: "superseded", verification: "curator_edited"},
        reason: "f4_curator_edit_superseded",
        channel: "human_ui"
      )

    validation =
      update_validation!(validation, actor, %{
        state: "approved",
        decision: "edit",
        decided_at: Clock.utc_now()
      })

    evaluated = evaluate_proposal(replacement, pipeline, target_level: knowledge.target_level)

    record_decision!(
      actor,
      superseded,
      validation.id,
      "gate_a_b",
      "edit",
      from_state: knowledge.state,
      to_state: superseded.state,
      to_level: knowledge.target_level,
      channel: "human_ui",
      verified: true,
      metadata: %{"replacement_id" => evaluated.id}
    )

    %{knowledge: superseded, replacement: evaluated, validation: validation}
  end

  # Duplicate resolution. The surviving row absorbs the evidence rather than the wording: it
  # takes the higher confidence of the two, the sum of their corroboration counts, and the
  # union of their source messages, so nothing that supported the duplicate is lost. The
  # duplicate becomes superseded and points at the survivor.
  defp merge!(knowledge, validation, actor, opts) do
    target_id = Map.fetch!(opts, "merge_into_id")
    target = knowledge!(knowledge.account_id, actor, target_id)
    pipeline = pipeline_actor(actor)

    target =
      target
      |> Ash.Changeset.for_update(:merge_from_pipeline, %{
        confidence: max(target.confidence, knowledge.confidence),
        corroboration_count: target.corroboration_count + knowledge.corroboration_count,
        source_message_ids: Enum.uniq(target.source_message_ids ++ knowledge.source_message_ids)
      })
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.update!(actor: pipeline)

    merged =
      transition!(
        knowledge,
        pipeline,
        %{state: "superseded", supersedes_id: target.id, verification: "curator_merged"},
        reason: "f4_curator_merged",
        channel: "human_ui"
      )

    validation =
      update_validation!(validation, actor, %{
        state: "merged",
        decision: "merge",
        decided_at: Clock.utc_now()
      })

    record_decision!(
      actor,
      merged,
      validation.id,
      "gate_a_b",
      "merge",
      from_state: knowledge.state,
      to_state: merged.state,
      to_level: knowledge.target_level,
      channel: "human_ui",
      verified: true,
      metadata: %{"merge_into_id" => target.id}
    )

    %{knowledge: merged, merge_target: target, validation: validation}
  end

  # Selects the matrix cell for this item. Candidates are the active rules for the requested
  # target level and the item's sensitivity, highest priority and newest version first.
  #
  # Precedence, most specific to least: a rule attached to the item's own scope, then the
  # account-wide rule (no scope), then the built-in cell. Note this matches the item's own
  # scope exactly and does not walk up ancestors — a rule on a parent scope does not govern a
  # child scope's items.
  defp matching_rule(knowledge, target_level, actor) do
    rules =
      GateRule
      |> Ash.Query.filter(
        target_level == ^target_level and sensitivity == ^knowledge.sensitivity and active == true
      )
      |> Ash.Query.sort(priority: :desc, version: :desc)
      |> Ash.Query.set_tenant(knowledge.account_id)
      |> Ash.read!(actor: actor)

    Enum.find(rules, &(&1.scope_id == knowledge.scope_id)) ||
      Enum.find(rules, &is_nil(&1.scope_id)) ||
      default_rule(target_level, knowledge.sensitivity)
  end

  # The cell used when an Account has configured no matching rule, so an unconfigured or
  # misconfigured Account queues everything for a human instead of auto-activating anything.
  #
  # * confidence 1.0 and human modes: no automatic keep or place is reachable at all.
  # * corroboration: 1 independent source for the subject's own peer level, 2 for anything
  #   wider, because a claim shown to more people should rest on more than one observation.
  # * 168 hours (7 days) for a human to respond; 90 days before an active item is re-checked.
  defp default_rule(target_level, sensitivity) do
    %{
      id: nil,
      target_level: target_level,
      sensitivity: sensitivity,
      minimum_confidence: 1.0,
      minimum_evidence_level: "direct",
      gate_a_mode: "human",
      gate_b_mode: "human",
      minimum_corroboration: if(target_level == "peer", do: 1, else: 2),
      requires_consent: sensitivity == "personal" && target_level != "peer",
      pending_max_age_hours: 168,
      revalidate_after_days: 90
    }
  end

  # Gate A keeps automatically only when the cell says so and the item's
  # deterministic source-to-subject evidence reaches its floor. Model confidence
  # is intentionally not an automation input: repeated model runs need not agree.
  defp auto_gate_a?(knowledge, rule),
    do:
      rule.gate_a_mode == "auto_keep" &&
        evidence_rank(knowledge.evidence_level) >= evidence_rank(rule.minimum_evidence_level)

  defp evidence_rank("direct"), do: 1
  defp evidence_rank("indirect"), do: 0

  # Gate B places automatically only when the cell says so, the sensitivity is
  # not personal or restricted, and enough independent sources corroborate the
  # item. Sensitive knowledge always needs a human placement decision.
  defp auto_gate_b?(knowledge, rule, _target_level),
    do:
      rule.gate_b_mode == "auto_place" &&
        knowledge.sensitivity in ["public", "internal"] &&
        knowledge.corroboration_count >= rule.minimum_corroboration

  # Returns {outcome, consent}, where consent is the resolve_consent/5 result — reused by
  # evaluate_proposal/3's :defer branch so the same proposal never resolves (and, for the auto
  # path, writes) consent twice. consent is nil on the auto-reject fast path, which short-
  # circuits before ever needing it: an item Gate A is about to discard has nothing to consent
  # to.
  defp proposal_outcome(
         _knowledge,
         %{gate_a_mode: "auto_reject"},
         _target_level,
         _target_scope_id,
         _actor
       ),
       do: {:reject, nil}

  # Automatic acceptance needs all three: both gates satisfied and consent settled in the
  # auto-accept item's favor. :not_required and :granted both count — :granted means an
  # Account/deployment declaration already auto-wrote a real consent row for this item.
  # :pending always defers, same as today: a curator or the subject still has to act.
  defp proposal_outcome(knowledge, rule, target_level, target_scope_id, actor) do
    consent = resolve_consent(knowledge, rule, target_level, target_scope_id, actor)

    consent_ok? =
      case consent do
        :not_required -> true
        {:granted, _consent} -> true
        {:pending, _consent} -> false
      end

    outcome =
      if auto_gate_a?(knowledge, rule) && auto_gate_b?(knowledge, rule, target_level) &&
           consent_ok?,
         do: :accept,
         else: :defer

    {outcome, consent}
  end

  # Consent is owed whenever personal knowledge about someone is aimed above their own peer
  # level. The rule's `requires_consent` flag is consulted, but the trailing sensitivity check
  # makes the condition true for every personal item regardless: a matrix cell can never
  # switch off a subject's say over their own personal information. Removing that seemingly
  # redundant clause would hand that power to whoever edits the matrix.
  #
  # "About someone" presupposes a peer: FR-GOV-12 requires "the peer's consent", and Consent
  # itself has no representation for a subject that is not a peer (subject_peer_id is
  # non-nullable). A subject_type: "scope" item has no peer subject at all — subject_peer_id is
  # nil — regardless of what sensitivity the extractor proposed for it, so there is no peer
  # whose consent could ever be requested. Such an item still passes through the ordinary
  # confidence/sensitivity matrix; it just cannot owe a peer-consent decision that has no peer
  # to make it.
  defp consent_required?(knowledge, rule, target_level),
    do:
      not is_nil(knowledge.subject_peer_id) && target_level != "peer" &&
        knowledge.sensitivity == "personal" &&
        (rule.requires_consent || knowledge.sensitivity == "personal")

  # Central point where every consent decision in this module gets made. Returns :not_required
  # when the item is not personal/above-peer; {:granted, consent} when the Account or deployment
  # has declared no real subject exists, in which case a real granted Consent row was just
  # written on the subject's behalf; or {:pending, consent} for the ordinary path, where the row
  # is opened and a real subject still has to answer it.
  #
  # `target_scope_id` falls back to the item's own scope when the caller has none more specific
  # (the direct-proposal path never has one): widening a personal item that is not going
  # through an explicit promotion means becoming visible to everyone who already has access to
  # the scope it lives in, which is exactly what consenting to that scope means.
  defp resolve_consent(knowledge, rule, target_level, target_scope_id, actor) do
    effective_target_scope_id = target_scope_id || knowledge.scope_id

    cond do
      not consent_required?(knowledge, rule, target_level) ->
        :not_required

      auto_consent?(knowledge.account_id, actor) ->
        {:granted, auto_grant_consent!(knowledge, effective_target_scope_id, actor)}

      true ->
        # Elevated the same way the pre-existing request_promotion/3 call site already did:
        # Consent's :request action is pipeline-only, and unlike evaluate_proposal's defer
        # branch (whose actor is already the pipeline actor of the ingest run),
        # request_promotion/3 calls this with a human curator actor.
        {:pending, request_consent!(knowledge, effective_target_scope_id, pipeline_actor(actor))}
    end
  end

  # True when this Account or this deployment process has declared it has no real human
  # subject. Checked fresh every call rather than cached: Account rows change rarely enough that
  # a point read is cheap, and caching a governance-weakening flag risks serving a stale "false"
  # or "true" across a config change.
  defp auto_consent?(account_id, actor) do
    MemHouse.Governance.UnattendedMode.enabled?() ||
      account!(account_id, actor).consent_mode == "auto"
  end

  # Writes exactly the shape a real subject's grant would: status "granted", verified true,
  # decided_by_peer_id nil because no peer decided anything. `channel` is the only field that
  # tells the two apart, which is what makes this auditable instead of a silent bypass — every
  # existing reader of Consent (approve!/4, the console, history) needs no special case for it.
  defp auto_grant_consent!(knowledge, target_scope_id, actor) do
    pipeline = pipeline_actor(actor)

    knowledge
    |> request_consent!(target_scope_id, pipeline)
    |> Ash.Changeset.for_update(:decide, %{
      status: "granted",
      channel: auto_consent_channel(knowledge.account_id, actor),
      verified: true,
      decided_by_peer_id: nil,
      decided_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(knowledge.account_id)
    |> Ash.update!(actor: pipeline)
  end

  defp auto_consent_channel(_account_id, _actor) do
    if MemHouse.Governance.UnattendedMode.enabled?(),
      do: "auto:unattended_deployment",
      else: "auto:account_mode"
  end

  # Point read of the Account row, elevated to the pipeline actor the same way scope!/3 and
  # knowledge!/3 already do: the engine has to be able to look this up regardless of what the
  # calling actor can itself read. No set_tenant call: Account is not multitenant — it IS the
  # tenant — the same reason MemHouse.DataLayer.with_actor/2 reads it without one.
  defp account!(account_id, actor) do
    MemHouse.Accounts.Account
    |> Ash.Query.filter(id == ^account_id)
    |> Ash.read_one!(actor: pipeline_actor(actor))
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: MemHouse.Accounts.Account
      account -> account
    end
  end

  # Puts an item on the human review queue. The entry is an upsert keyed by knowledge item and
  # kind, so re-evaluating the same item does not stack up duplicate queue rows; the existing
  # row's deadline, confidence, provenance, and conflict list are refreshed instead.
  #
  # The row copies the statement's hash rather than its text, and carries the provenance and
  # conflicting-item ids a reviewer needs to judge it.
  defp enqueue_validation!(knowledge, actor, target_level, target_scope_id, due_at, kind) do
    ValidationItem
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(knowledge.account_id)
    |> Ash.Changeset.for_create(:enqueue, %{
      knowledge_id: knowledge.id,
      scope_id: knowledge.scope_id,
      subject_peer_id: knowledge.subject_peer_id,
      target_scope_id: target_scope_id,
      target_level: target_level,
      kind: kind,
      state: "pending",
      decision: nil,
      statement_hash: knowledge.statement_hash,
      confidence: knowledge.confidence,
      sensitivity: knowledge.sensitivity,
      provenance_ids: provenance_ids(knowledge, actor),
      conflict_knowledge_ids: conflict_ids(knowledge, actor),
      escalated_at: nil,
      attempt_count: 0,
      decided_at: nil,
      due_at: due_at
    })
    |> Ash.create!(actor: actor)
  end

  # Provenance rows are read with elevated privilege so the queue entry can list where the
  # claim came from even when the enqueuing actor holds no direct read on those rows. Only
  # their ids are copied onto the entry; no source content travels with it.
  defp provenance_ids(knowledge, actor) do
    Provenance
    |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
    |> Ash.Query.set_tenant(knowledge.account_id)
    |> Ash.read!(actor: pipeline_actor(actor))
    |> Enum.map(& &1.id)
  end

  # Ids of items already recorded as conflicting with this one, in either direction of the
  # relation, so the reviewer sees the disagreement bundled with the proposal instead of
  # approving one half of a contradiction.
  defp conflict_ids(knowledge, actor) do
    KnowledgeRelation
    |> Ash.Query.filter(
      kind == "conflict" and
        (source_knowledge_id == ^knowledge.id or target_knowledge_id == ^knowledge.id)
    )
    |> Ash.Query.set_tenant(knowledge.account_id)
    |> Ash.read!(actor: pipeline_actor(actor))
    |> Enum.map(fn relation ->
      if relation.source_knowledge_id == knowledge.id,
        do: relation.target_knowledge_id,
        else: relation.source_knowledge_id
    end)
    |> Enum.uniq()
  end

  # Opens a pending consent request for one knowledge item at one target scope. Upserted on
  # that pair plus the subject, so asking again reuses the existing request instead of
  # resetting an answer the subject already gave.
  defp request_consent!(knowledge, target_scope_id, actor) do
    Consent
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(knowledge.account_id)
    |> Ash.Changeset.for_create(:request, %{
      knowledge_id: knowledge.id,
      scope_id: knowledge.scope_id,
      subject_peer_id: knowledge.subject_peer_id,
      target_scope_id: target_scope_id,
      status: "pending"
    })
    |> Ash.create!(actor: actor)
  end

  # Peer-level items stay with their own subject, so no consent to widen exposure exists or is
  # needed; the clause below only runs for requests aimed at a wider scope.
  defp consent_for(_knowledge, %{target_level: "peer"}, _actor), do: nil

  defp consent_for(knowledge, validation, actor) do
    Consent
    |> Ash.Query.filter(
      knowledge_id == ^knowledge.id and target_scope_id == ^validation.target_scope_id
    )
    |> Ash.Query.set_tenant(knowledge.account_id)
    |> Ash.read_one!(actor: history_actor(actor))
  end

  defp update_validation!(validation, actor, attrs) do
    validation
    |> Ash.Changeset.for_update(:decide, attrs)
    |> Ash.Changeset.set_tenant(validation.account_id)
    |> Ash.update!(actor: actor)
  end

  # Tenant-scoped fetches. The tenant is always set explicitly and the read runs as the given
  # actor, so an id belonging to another Account, or to a scope this actor cannot see, comes
  # back as nil and is reported as not found rather than leaking its existence.
  defp validation!(account_id, actor, id) do
    ValidationItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: ValidationItem
      item -> item
    end
  end

  defp knowledge!(account_id, actor, id) do
    KnowledgeItem
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: KnowledgeItem
      item -> item
    end
  end

  # Scope rows are read with elevated privilege because promotion has to compare the source
  # and target paths even when the curator cannot read one of those scopes' contents. Only the
  # path is used here; the separate role check decides whether the promotion may proceed.
  defp scope!(account_id, actor, id) do
    Scope
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: pipeline_actor(actor))
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: Scope
      scope -> scope
    end
  end

  # Audit entry for a subject acting on a statement about themselves. The statement travels as
  # a hash only; the metadata holds the resulting state and nothing readable.
  defp audit_subject_action!(actor, knowledge, action) do
    Audit.append!(actor, knowledge.account_id, %{
      scope_id: knowledge.scope_id,
      actor_peer_id: actor.peer_id,
      category: "governance",
      action: "subject.#{action}",
      resource_type: "knowledge_item",
      resource_id: knowledge.id,
      content_hash: knowledge.statement_hash,
      metadata: %{"state" => knowledge.state}
    })
  end

  # Curator verbs are human-only. The identity kind matters as much as the role: an API key
  # carrying a curator role is still a machine and must not approve, edit, reject, merge,
  # defer, or promote. Machines submit observations and read governed memory; humans judge.
  defp require_human_curator!(%{identity_kind: :password, role: role})
       when role in [:account_admin, :curator],
       do: :ok

  defp require_human_curator!(_actor), do: raise(Ash.Error.Forbidden, errors: [])

  # Widening exposure additionally requires authority over the destination scope. The actor's
  # scope role map is already resolved with inheritance and deny-wins applied, so an exact
  # lookup of the target scope is the complete check.
  defp require_scope_curator!(%{scope_roles: roles}, scope_id) when is_map(roles) do
    if Map.get(roles, scope_id) in [:account_admin, :curator],
      do: :ok,
      else: raise(Ash.Error.Forbidden, errors: [])
  end

  defp require_scope_curator!(_actor, _scope_id),
    do: raise(Ash.Error.Forbidden, errors: [])

  # Decision and consent rows hold ids, states, and hashes rather than statement text, so a
  # caller who has already passed the knowledge-level check may read them. Human curators read
  # as themselves; anyone else is elevated for that read only.
  defp history_actor(%{identity_kind: :password, role: role} = actor)
       when role in [:account_admin, :curator],
       do: actor

  defp history_actor(actor), do: pipeline_actor(actor)

  # A signed-in person answers their own consent request as themselves, which keeps the
  # "subject owns this row" policy in force. Other callers (a peer answering through an
  # automated delivery path) are elevated, having already been matched to the subject.
  defp consent_actor(%{identity_kind: :password} = actor), do: actor
  defp consent_actor(actor), do: pipeline_actor(actor)

  # Elevation for writes the pipeline alone may perform, such as minting a replacement item or
  # transitioning knowledge on behalf of a subject who holds no curator role. Every public
  # entry point authorizes the real caller before this is reached; never widen that path.
  defp pipeline_actor(%MemHouse.Actor{} = actor),
    do: %{actor | role: :system, scope_ids: :all, pipeline?: true}

  defp pipeline_actor(actor),
    do: actor |> Map.put(:role, :system) |> Map.put(:pipeline?, true)

  # When the cell sets no revalidation interval the item never becomes due for re-checking.
  defp revalidate_at(%{revalidate_after_days: nil}), do: nil

  # Interval is in days, counted from the moment of activation.
  defp revalidate_at(rule),
    do: DateTime.add(Clock.utc_now(), rule.revalidate_after_days, :day)

  # The built-in fallback cell has no database row, so decisions made under it record this
  # marker instead of a rule id. It is stored in decision metadata and tells a later reader
  # that the Account had no configured cell for that combination.
  defp rule_id(%{id: nil}), do: "default-human"
  defp rule_id(rule), do: rule.id

  # True when the target scope strictly contains the source scope. Paths are slash-delimited
  # containment paths; the root contains everything, and the trailing slash in the prefix test
  # keeps "/team-a" from being treated as an ancestor of "/team-alpha".
  defp wider_scope?(source_path, target_path) do
    source_path != target_path &&
      (target_path == "/" || String.starts_with?(source_path, target_path <> "/"))
  end

  # Options may arrive from a form, so a count can be an integer or a string. Anything that is
  # not a positive whole number falls back to the caller's default instead of raising.
  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  # Callers pass atom keys from Elixir code and string keys from form params; normalizing once
  # at the entry point lets every decision handler read one shape.
  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
