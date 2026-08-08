# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.GateRule do
  @moduledoc """
  One cell of the versioned matrix that decides what happens to a proposed piece of knowledge.

  For one target level and sensitivity, a row sets evidence, automation,
  corroboration, review age, and revalidation limits.

  ## How a row is selected

  Matching rows sort by priority then version, descending. Selection uses exact scope, then the
  Account-wide row, then a built-in rule requiring full confidence and human review at both
  gates. Parent rules do not govern child scopes.

  ## Field meanings

  * `gate_a_mode` — `"auto_keep"` accepts a proposal whose derived evidence reaches
    `minimum_evidence_level`; `"auto_reject"` discards every matching proposal outright; any other
    value, including the `"human"` default, routes it to the review queue.
  * `gate_b_mode` — `"auto_place"` places the item at the requested level once
    `minimum_corroboration` independent sources agree; anything else needs a human placement.
  * `requires_consent` — recorded on the rule, but consent is currently demanded for exactly one
    situation: personal knowledge aimed above the subject's own peer level. That condition
    already covers everything the flag could add, so setting it true changes nothing today and
    setting it false cannot waive a subject's consent.

  ## Versioning and safety

  Scope, target level, sensitivity, and version identify a row. Mutations append a digest to the
  audit chain.

  Only password-session admins or curators and the pipeline may read or write rules. Machine
  credentials cannot inspect or weaken them.
  """

  use MemHouse.Resource, domain: MemHouse.Governance, table: "governance_gate_rules"

  # Attribute multitenancy plus Postgres row-level security keep one Account's matrix invisible
  # to every other Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Creating a rule hashes the whole rule into one configuration audit event, so loosening the
    # gates always leaves evidence naming who did it and when.
    create :create do
      accept [
        :scope_id,
        :target_level,
        :sensitivity,
        :minimum_confidence,
        :minimum_evidence_level,
        :gate_a_mode,
        :gate_b_mode,
        :minimum_corroboration,
        :requires_consent,
        :pending_max_age_hours,
        :revalidate_after_days,
        :priority,
        :version,
        :active
      ]

      validate attribute_in(:minimum_evidence_level, ~w(direct indirect))

      change {MemHouse.Governance.Changes.AuditResource,
              category: "configuration",
              action: "gate_rule.created",
              resource_type: "gate_rule",
              content_fields: [
                :scope_id,
                :target_level,
                :sensitivity,
                :minimum_confidence,
                :minimum_evidence_level,
                :gate_a_mode,
                :gate_b_mode,
                :minimum_corroboration,
                :requires_consent,
                :pending_max_age_hours,
                :revalidate_after_days,
                :priority,
                :version,
                :active
              ]}
    end

    # `scope_id`, `target_level`, and `sensitivity` are not accepted: they are the identity of
    # the matrix cell. Retargeting a rule in place would silently reroute decisions that were
    # already justified against it, so a different cell means a different row.
    # Atomic updates are off because the audit append runs in Elixir after the write.
    update :update do
      accept [
        :minimum_confidence,
        :minimum_evidence_level,
        :gate_a_mode,
        :gate_b_mode,
        :minimum_corroboration,
        :requires_consent,
        :pending_max_age_hours,
        :revalidate_after_days,
        :priority,
        :version,
        :active
      ]

      validate attribute_in(:minimum_evidence_level, ~w(direct indirect))

      require_atomic? false

      change {MemHouse.Governance.Changes.AuditResource,
              category: "configuration",
              action: "gate_rule.updated",
              resource_type: "gate_rule",
              content_fields: [
                :minimum_confidence,
                :minimum_evidence_level,
                :gate_a_mode,
                :gate_b_mode,
                :minimum_corroboration,
                :requires_consent,
                :pending_max_age_hours,
                :revalidate_after_days,
                :priority,
                :version,
                :active
              ]}
    end
  end

  # `HumanRoleIn` matches only a password-session identity, so this is the block that keeps a
  # machine API key — even one carrying the curator role — from reading or rewriting the rules
  # that decide what gets accepted without review. The pipeline actor is allowed because the
  # engine has to look the matrix up on every proposal.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    # nil is the Account-wide fallback cell; a set scope wins for that scope only.
    attribute :scope_id, :uuid, public?: true
    # How far the item would travel (for example the subject's own peer level versus a shared
    # scope) and how delicate it is; together they name the matrix cell.
    attribute :target_level, :string, allow_nil?: false, public?: true
    attribute :sensitivity, :string, allow_nil?: false, public?: true
    # Kept as recorded model metadata for existing policies and operators. Gate A
    # never treats a model self-score as an automation input.
    attribute :minimum_confidence, :float, allow_nil?: false, default: 1.0, public?: true
    # `direct` is the only level eligible for automatic Gate A keep. It is
    # derived from the resolved speaker and subject, so re-running extraction
    # cannot cross this threshold.
    attribute :minimum_evidence_level, :string,
      allow_nil?: false,
      default: "direct",
      public?: true

    attribute :gate_a_mode, :string, allow_nil?: false, default: "human", public?: true
    attribute :gate_b_mode, :string, allow_nil?: false, default: "human", public?: true
    # Count of independent sources that must agree before automatic placement.
    attribute :minimum_corroboration, :integer, allow_nil?: false, default: 1, public?: true
    attribute :requires_consent, :boolean, allow_nil?: false, default: false, public?: true
    # Hours a review may sit before the aging sweep escalates it, extending the deadline by 24
    # hours; if it is still unanswered on the next pass the item is auto-rejected. Default 168
    # hours = 7 days.
    attribute :pending_max_age_hours, :integer, allow_nil?: false, default: 168, public?: true
    # Days an accepted item stays trusted before the revalidation sweep moves it to
    # `needs_revalidation` and queues a review. nil means it is never revalidated on a timer.
    attribute :revalidate_after_days, :integer, public?: true
    # Higher priority wins among rows matching at the same scope specificity; a row for the
    # item's own scope still beats an Account-wide row of any priority.
    attribute :priority, :integer, allow_nil?: false, default: 0, public?: true
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # Version is part of the key, so revising a cell adds a row instead of destroying the rule a
  # past decision was justified against.
  identities do
    identity :matrix_cell, [:scope_id, :target_level, :sensitivity, :version]
  end
end

defmodule MemHouse.Governance.ValidationItem do
  @moduledoc """
  One outstanding or settled request for judgment about one knowledge item.

  Curators and peers share this queue. A row exists when automation cannot decide:

  * `kind: "gate_a_b"` — a freshly proposed item the matrix would not accept on its own.
  * `kind: "gate_b"` — a request to place an existing item in a wider scope.
  * `kind: "revalidation"` — an accepted item whose trust window has elapsed.
  * `kind: "contest"` — a subject disputes a statement about themselves.

  State starts `"pending"`, may become `"escalated"`, `"awaiting_consent"`, or `"deferred"`, and
  settles as `"approved"`, `"rejected"`, or `"merged"`. Aging escalates once, then rejects;
  silence never accepts memory.

  ## Replay safety

  `:enqueue` upserts by knowledge id and kind, refreshing only mutable review fields.

  ## Content safety

  The row references content, it does not hold it. `statement_hash` is a digest and is not
  exposed publicly; `provenance_ids` and `conflict_knowledge_ids` are id lists so a reviewing UI
  can fetch the underlying records under its own authorization. The one place a statement's text
  is stored for review is `MemHouse.Governance.PeerQuery`, which must quote it back to its
  subject.
  """

  use MemHouse.Resource, domain: MemHouse.Governance, table: "validation_items"

  # Attribute multitenancy plus Postgres row-level security keep one Account's review queue
  # invisible to every other Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Upsert rather than create, keyed on knowledge id plus kind: a retried or replayed pipeline
    # run must reuse the open review instead of producing duplicates for a human to sift.
    create :enqueue do
      accept [
        :knowledge_id,
        :scope_id,
        :subject_peer_id,
        :target_scope_id,
        :target_level,
        :kind,
        :state,
        :statement_hash,
        :confidence,
        :sensitivity,
        :provenance_ids,
        :conflict_knowledge_ids,
        :assigned_peer_id,
        :due_at,
        :decision,
        :escalated_at,
        :attempt_count,
        :decided_at
      ]

      upsert? true
      upsert_identity :open_knowledge_gate

      # Only the mutable review fields are refreshed on conflict. knowledge_id, scope_id, kind,
      # subject_peer_id, and statement_hash are omitted on purpose: they identify what is under
      # review, and rewriting them would let a replay silently repoint an open decision.
      upsert_fields [
        :target_scope_id,
        :target_level,
        :state,
        :decision,
        :confidence,
        :sensitivity,
        :provenance_ids,
        :conflict_knowledge_ids,
        :assigned_peer_id,
        :due_at,
        :escalated_at,
        :attempt_count,
        :decided_at,
        :updated_at
      ]
    end

    # The queue row moves; what is under review does not. Nothing that identifies the knowledge
    # item is accepted here, so a decision cannot be redirected onto a different statement.
    update :decide do
      accept [
        :state,
        :decision,
        :assigned_peer_id,
        :due_at,
        :escalated_at,
        :attempt_count,
        :decided_at
      ]

      require_atomic? false
    end
  end

  # Writes need a password-session admin or curator, or the pipeline: a machine credential must
  # not be able to settle a review. Reads are wider but still narrow — a human admin or curator
  # at the item's own scope, the peer the statement is about, or the pipeline. Everyone else
  # sees nothing, because the first clause already pinned the query to the actor's Account.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type([:create, :update]) do
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.HumanScopeRole,
                    roles: [:account_admin, :curator], attribute: :scope_id}

      authorize_if expr(subject_peer_id == ^actor(:peer_id))
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_id, :uuid, allow_nil?: false, public?: true
    # Where the item lives now, versus where it is asking to go; `target_scope_id` is nil unless
    # the review is about widening its reach.
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :subject_peer_id, :uuid, public?: true
    attribute :target_scope_id, :uuid, public?: true
    attribute :target_level, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :state, :string, allow_nil?: false, default: "pending", public?: true
    attribute :decision, :string, public?: true
    # Digest, not text, and not public: the queue identifies the statement without storing it.
    attribute :statement_hash, :string, allow_nil?: false
    # Copied from the item at enqueue time so a reviewer sees the values the gate judged.
    attribute :confidence, :float, allow_nil?: false, public?: true
    attribute :sensitivity, :string, allow_nil?: false, public?: true
    # Id lists only. A reviewing surface resolves them under its own authorization, which keeps
    # supporting evidence out of this row and out of anything derived from it.
    attribute :provenance_ids, {:array, :uuid}, allow_nil?: false, default: [], public?: true

    attribute :conflict_knowledge_ids, {:array, :uuid},
      allow_nil?: false,
      default: [],
      public?: true

    attribute :assigned_peer_id, :uuid, public?: true
    # Deadline for a decision, set by whoever enqueued the row: the gate paths take it from the
    # matching rule, revalidation allows 14 days, a contest allows 24 hours. Past it, the aging
    # sweep escalates once and then auto-rejects; `attempt_count` counts the chases so far.
    attribute :due_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :escalated_at, :utc_datetime_usec, public?: true
    attribute :attempt_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :decided_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One open review per knowledge item per kind. This is what makes `:enqueue` idempotent, so a
  # replayed job cannot flood a curator with duplicates of the same question.
  identities do
    identity :open_knowledge_gate, [:knowledge_id, :kind]
  end
end

defmodule MemHouse.Governance.GateDecision do
  @moduledoc """
  One immutable history row for a single gate outcome, automatic or human.

  Every gate outcome is recorded with its lifecycle change and audit entry, preserving why the
  state changed, who decided, and whether subject agreement was verified.

  `gate` is `"gate_a"` (keep or discard), `"gate_b"` (how widely to place), or `"gate_a_b"` for
  a human decision that settles both at once. `decision` is the outcome verb — for example
  `"keep"`, `"reject"`, `"defer"`, `"place"`, `"hold"`, `"await_consent"`, `"approve"`,
  `"edit"`, or `"merge"`. `channel` says where it came from: `"pipeline"`, `"human_ui"`, or
  `"mcp"` for a peer answering through the tool surface. `verified` is true when the decision
  was actually settled — an automatic rule outcome, a curator decision, or a transcript-verified
  peer answer — and false on the rows written when a proposal is only queued for review.

  Rows are append-only. `statement_hash` is private and metadata is content-safe.
  """

  use MemHouse.Resource, domain: MemHouse.Governance, table: "gate_decisions"

  # Attribute multitenancy plus Postgres row-level security keep decision history inside one
  # Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Append-only history: deliberately no update or destroy counterpart.
    create :record do
      accept [
        :validation_item_id,
        :knowledge_id,
        :scope_id,
        :gate,
        :decision,
        :actor_peer_id,
        :channel,
        :verified,
        :from_state,
        :to_state,
        :from_level,
        :to_level,
        :statement_hash,
        :metadata,
        :decided_at
      ]
    end
  end

  # Decision history is governance evidence, so both writing and reading it are limited to a
  # password-session governance role or the pipeline. A machine credential cannot mine the trail
  # of what was decided about whom.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:record) do
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    # nil when the gate decided automatically and no review row was ever needed.
    attribute :validation_item_id, :uuid, public?: true
    attribute :knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :gate, :string, allow_nil?: false, public?: true
    attribute :decision, :string, allow_nil?: false, public?: true
    # Who decided, and over what path. nil when no peer stood behind the decision.
    attribute :actor_peer_id, :uuid, public?: true
    attribute :channel, :string, allow_nil?: false, public?: true
    # False on the rows written when a proposal is merely deferred to a human; true once the
    # outcome is settled by a rule, a curator, or a transcript-verified peer answer.
    attribute :verified, :boolean, allow_nil?: false, default: false, public?: true
    # The lifecycle and placement move this decision caused, kept so the trail can be replayed.
    attribute :from_state, :string, public?: true
    attribute :to_state, :string, public?: true
    attribute :from_level, :string, public?: true
    attribute :to_level, :string, public?: true
    # Digest, not text, and not public.
    attribute :statement_hash, :string, allow_nil?: false
    # Content-safe only: ids, counts, class strings. No statements, prompts, or answers.
    attribute :metadata, :map, allow_nil?: false, default: %{}
    attribute :decided_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule MemHouse.Governance.Consent do
  @moduledoc """
  One subject's answer to one request to share one personal statement with one wider scope.

  Personal knowledge stays held while consent is `"pending"`. `"granted"` removes the consent
  blocker but does not replace curator approval; `"denied"` prevents placement.

  Three properties make this meaningful and must be preserved:

  * **Target-specific.** The unique key is knowledge item, subject, and target scope. Consent to
    share something with one team says nothing about another; a second target opens a second
    row.
  * **Subject-owned.** Only the subject may grant. A curator approving the underlying review
    does not substitute for consent — the operation layer parks such an approval in an
    "awaiting consent" state rather than placing the item.
  * **Verified channels only.** A grant arriving over a channel that could not be proven — for
    example a tool answer with no matching session transcript — is refused. A denial is always
    accepted, because refusing to share is never the risky direction.

  The row records decider, channel, and verification.
  """

  use MemHouse.Resource, domain: MemHouse.Governance, table: "knowledge_consents"

  # Attribute multitenancy plus Postgres row-level security keep consent records inside one
  # Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Opening a request is idempotent on knowledge item, subject, and target scope, so a
    # replayed pipeline run reuses the pending row instead of asking the subject twice. Only the
    # status is refreshed on conflict; an already-decided row therefore is not silently reset by
    # a replay that would have written "pending" again.
    create :request do
      accept [:knowledge_id, :scope_id, :subject_peer_id, :target_scope_id, :status]
      upsert? true
      upsert_identity :knowledge_target
      upsert_fields [:status, :updated_at]
    end

    # The answer, plus the evidence for it. Nothing identifying is accepted here, so a decision
    # cannot be moved onto a different statement, subject, or target scope after the fact. The
    # verified-channel rule is enforced by the caller, not by this action.
    update :decide do
      accept [:status, :channel, :verified, :decided_by_peer_id, :decided_at]
      require_atomic? false
    end
  end

  # Requests are opened by the pipeline only. Deciding is limited to the password-session human
  # who is the subject, or the pipeline acting on an answer it has already verified against a
  # session transcript — note that a curator role grants no power here at all. Reads are open to
  # the subject, human governance roles, and the pipeline.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:request) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:decide) do
      authorize_if {MemHouse.Policy.HumanOwns, attribute: :subject_peer_id}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if expr(subject_peer_id == ^actor(:peer_id))
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_id, :uuid, allow_nil?: false, public?: true
    # Where the statement currently lives, versus the wider scope being asked for.
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :subject_peer_id, :uuid, allow_nil?: false, public?: true
    attribute :target_scope_id, :uuid, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "pending", public?: true
    # How the answer arrived, and whether that path could be proven. An unverified grant is
    # rejected upstream, so a granted row with `verified` false should not exist.
    attribute :channel, :string, public?: true
    attribute :verified, :boolean, allow_nil?: false, default: false, public?: true
    attribute :decided_by_peer_id, :uuid, public?: true
    attribute :decided_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # Consent is per statement, per subject, and per destination. Widening this key would let one
  # grant leak into scopes the subject never agreed to.
  identities do
    identity :knowledge_target, [:knowledge_id, :subject_peer_id, :target_scope_id]
  end
end

defmodule MemHouse.Governance.PeerQuery do
  @moduledoc """
  One question waiting to be put to one peer, with the exact wording frozen at creation time.

  Reads can carry one of three questions: `"confirm"`, `"revalidate"`, or `"consent_upward"`.

  ## Why the text is stored here

  This is the only governance row holding statement text, frozen for exact display and transcript
  verification.

  That makes `statement_text` erasable subject content. It must never be copied into audit
  metadata, telemetry, logs, or background-job arguments — only `statement_hash` may travel.
  `:erase` exists so subject erasure can remove it, and is restricted to the pipeline.

  ## Lifecycle

  `state` runs `"pending"` to `"delivered"` when the text goes out, then `"answered"` or
  `"expired"`. `attempts` counts brush-offs; once it reaches the configured attempt limit (two
  by default) the question is retired and the underlying review is escalated to a curator
  instead. `deadline_at` is the answering window — callers set it, and the enqueueing code
  currently allows 14 days.
  """

  use MemHouse.Resource, domain: MemHouse.Governance, table: "peer_queries"

  # Attribute multitenancy plus Postgres row-level security keep questions, including the frozen
  # statement text, inside one Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Upsert on knowledge item plus kind: a peer must never be asked the same question twice
    # because a job was retried. On conflict only the delivery-tracking fields are refreshed,
    # so the frozen statement text stays exactly as first written.
    create :enqueue do
      accept [
        :validation_item_id,
        :knowledge_id,
        :scope_id,
        :peer_id,
        :kind,
        :statement_text,
        :statement_hash,
        :state,
        :deadline_at,
        :attempts,
        :last_delivered_at,
        :answered_at
      ]

      upsert? true
      upsert_identity :knowledge_kind

      upsert_fields [
        :state,
        :deadline_at,
        :attempts,
        :last_delivered_at,
        :answered_at,
        :updated_at
      ]
    end

    # Tracks only where the question is in its own lifecycle. The statement, the peer, and the
    # review it belongs to are not accepted, so a question in flight cannot be swapped for a
    # different one after a peer has seen it.
    update :update_delivery_state do
      accept [:state, :attempts, :last_delivered_at, :answered_at]
      require_atomic? false
    end

    # Exists because the frozen statement text is subject content and must be removable when a
    # subject is erased. Restricted to the pipeline below.
    destroy :erase do
      require_atomic? false
    end
  end

  # Questions are created and erased only by the pipeline. The peer being asked may advance the
  # delivery state of their own question and read it; human governance roles may read the queue
  # to see what is outstanding. Everything is Account-scoped by the first clause.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:enqueue) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:update_delivery_state) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    # The review this question serves; answering it settles that queue row.
    attribute :validation_item_id, :uuid, allow_nil?: false, public?: true
    attribute :knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false
    attribute :kind, :string, allow_nil?: false, public?: true
    # Frozen copy of the claim, shown verbatim to the peer and compared against the transcript
    # to prove the answer was informed. Erasable content: never copy it into audit, telemetry,
    # logs, or job arguments.
    attribute :statement_text, :string, allow_nil?: false, public?: true
    attribute :statement_hash, :string, allow_nil?: false
    attribute :state, :string, allow_nil?: false, default: "pending", public?: true
    # Answering window. The queue offers questions in deadline order.
    attribute :deadline_at, :utc_datetime_usec, allow_nil?: false, public?: true
    # Brush-offs so far; reaching the configured limit (two by default) retires the question to
    # a curator.
    attribute :attempts, :integer, allow_nil?: false, default: 0, public?: true
    # Used for the cooldown between delivery attempts, so a peer is not badgered.
    attribute :last_delivered_at, :utc_datetime_usec, public?: true
    attribute :answered_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One live question per knowledge item per kind, which is what makes enqueueing replay-safe.
  identities do
    identity :knowledge_kind, [:knowledge_id, :kind]
  end
end

defmodule MemHouse.Governance.PeerQueryDelivery do
  @moduledoc """
  Evidence that one question was actually put to one peer in one session, and what came back.

  Records when and where a question was delivered, whether shown text matched, and whether the
  transcript verified the answer.

  `verification` starts `"pending"` and settles as `"verified"` or `"unverified_channel"`. Only
  a verified answer may confirm, retract, or consent; an unverified one merely pushes the
  revalidation timer out. `conflict` is set when the text the agent says it showed differs from
  the frozen statement after normalization — the answer is still recorded, but the discrepancy
  is preserved rather than smoothed over.

  Only a hash of the shown text is stored. The text itself is never persisted here, and `:erase`
  exists so subject erasure can remove the delivery trail along with the question.
  """

  use MemHouse.Resource, domain: MemHouse.Governance, table: "peer_query_deliveries"

  # Attribute multitenancy plus Postgres row-level security keep delivery evidence inside one
  # Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Upsert on question plus session, refreshing only `tool_name`. `delivered_at` is
    # deliberately left at its first value: transcript verification looks at messages from that
    # instant onward, so refreshing it on a repeat delivery would discard the very turns that
    # prove the peer was shown the statement.
    create :deliver do
      accept [
        :peer_query_id,
        :scope_id,
        :peer_id,
        :session_id,
        :tool_name,
        :delivered_at,
        :verification
      ]

      upsert? true
      upsert_identity :query_session
      upsert_fields [:tool_name]
    end

    # Records the outcome. The question, session, and peer are fixed at delivery and are not
    # accepted here, so an answer cannot be reattributed to a different exchange.
    update :answer do
      accept [:shown_text_hash, :verification, :answered_at, :verdict, :conflict]
      require_atomic? false
    end

    # Subject erasure removes the delivery trail together with the question it belongs to.
    destroy :erase do
      require_atomic? false
    end
  end

  # Only the peer the question is addressed to, or the pipeline, may record delivery and answer;
  # erasure is pipeline-only. Human governance roles may read the evidence to audit how an
  # answer was obtained.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action([:deliver, :answer]) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_query_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false
    attribute :session_id, :uuid, allow_nil?: false
    # Which read carried the question out, kept so an unexpected delivery path is visible.
    attribute :tool_name, :string, allow_nil?: false, public?: true
    # Start of the transcript window searched for proof the statement was shown and answered.
    attribute :delivered_at, :utc_datetime_usec, allow_nil?: false, public?: true
    # Digest of what the agent claims it displayed. The text itself is never stored.
    attribute :shown_text_hash, :string
    # "pending", then "verified" or "unverified_channel". Only "verified" may move knowledge.
    attribute :verification, :string, allow_nil?: false, default: "pending", public?: true
    attribute :answered_at, :utc_datetime_usec, public?: true
    attribute :verdict, :string, public?: true
    # True when the shown text did not match the frozen statement after normalization; kept as a
    # discrepancy rather than suppressed.
    attribute :conflict, :boolean, allow_nil?: false, default: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One delivery record per question per session, so repeat deliveries inside a conversation
  # update the existing evidence rather than multiplying it.
  identities do
    identity :query_session, [:peer_query_id, :session_id]
  end
end

defmodule MemHouse.Governance.PeerAskPreference do
  @moduledoc """
  How willing one peer is to be interrupted by inline validation questions.

  One row caps questions per session and rolling day and pauses them until `paused_until`.
  Defaults are 3 per session and 10 per day. Reaching a limit leaves the read unchanged.

  Two update paths exist and they are not interchangeable:

  * `:restrict` takes arguments rather than attributes and runs them through
    `MemHouse.Governance.Changes.ClampAskPreference`, which allows only tightening. This is the
    path a peer's own agent uses, so a peer can always turn the volume down on themselves.
  * `:configure` writes the values directly and is the only way limits go back up. It is
    restricted to a password-session administrator or curator.

  `:ensure` is a get-or-create used by the delivery path before it checks limits.
  """

  use MemHouse.Resource, domain: MemHouse.Governance, table: "peer_ask_preferences"

  # Attribute multitenancy plus Postgres row-level security keep preferences inside one Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Get-or-create. On conflict it writes only `peer_id`, which is a deliberate no-op update:
    # adding the limit fields here would reset a peer's chosen settings to the caller's defaults
    # every single time the delivery path looked the row up.
    create :ensure do
      accept [:peer_id, :max_per_session, :max_per_day, :paused_until]
      upsert? true
      upsert_identity :peer
      upsert_fields [:peer_id]
    end

    # Tighten-only, and reachable by the peer themselves. Arguments rather than accepted
    # attributes, because the clamping change has to compare each request against the stored
    # value before deciding whether to write it at all.
    update :restrict do
      argument :max_per_session, :integer
      argument :max_per_day, :integer
      argument :paused_until, :utc_datetime_usec
      require_atomic? false
      change MemHouse.Governance.Changes.ClampAskPreference
    end

    # Unclamped administrative write: the only path that can raise a limit or lift a pause.
    update :configure do
      accept [:max_per_session, :max_per_day, :paused_until]
      require_atomic? false
    end
  end

  # A peer may create and tighten their own row; the pipeline may do so on their behalf while
  # delivering. Raising limits needs a password-session admin or curator — note that
  # `:configure` grants nothing to the pipeline, so no automated path can quietly re-enable
  # interruptions a peer switched off.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action([:ensure, :restrict]) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:configure) do
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
    end

    policy action_type(:read) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    # Counts of inline questions. 3 per conversation and 10 per rolling day are judgement calls
    # about tolerable interruption, not technical limits; zero means "never ask me".
    attribute :max_per_session, :integer, allow_nil?: false, default: 3, public?: true
    attribute :max_per_day, :integer, allow_nil?: false, default: 10, public?: true
    # Absolute resume time rather than a duration, so a pause survives restarts. nil = not
    # paused.
    attribute :paused_until, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # Exactly one preference row per peer; the delivery path relies on that to avoid racing two
  # rows into existence.
  identities do
    identity :peer, [:peer_id]
  end
end

defmodule MemHouse.Governance.ErasureRequest do
  @moduledoc """
  The durable record that a person's data was erased, and what that erasure actually touched.

  Created before erasure and completed with counts afterward, this content-safe receipt survives
  the subject data. `affected_counts` stores numbers and mode only.

  Two modes differ in how far the removal reaches:

  * `"proportionate"` — removes the subject's own messages and the knowledge about them, and
    scrubs their contribution from provenance shared with other sources. Knowledge that still
    has independent sourcing survives with that source removed.
  * `"strict"` — additionally removes knowledge that was sourced only through this person, even
    when it is not about them.

  Requesting is deliberately narrow: the subject themselves, or a password-session account
  administrator acting for them. Completion is written only by the pipeline that performed the
  work, so a `"completed"` state with counts cannot be fabricated by a caller.
  """

  use MemHouse.Resource, domain: MemHouse.Governance, table: "erasure_requests"

  # Attribute multitenancy plus Postgres row-level security keep erasure records inside one
  # Account.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Opens the request in "pending". The erasure work then runs and reports back through
    # `:complete`, which is why the two are separate actions rather than one write.
    create :request do
      accept [:peer_id, :scope_id, :mode, :requested_by_peer_id, :state, :requested_at]
    end

    # Records the outcome. Subject, mode, and requester are not accepted, so the finished record
    # cannot be re-attributed to a different erasure.
    update :complete do
      accept [:state, :affected_counts, :completed_at]
      require_atomic? false
    end
  end

  # Only the subject or a password-session account administrator may ask for an erasure; a
  # curator role is not enough, and neither is a machine credential unless it belongs to the
  # subject. Marking one complete is pipeline-only.
  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:request) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin]}
    end

    policy action(:complete) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action_type(:read) do
      authorize_if expr(peer_id == ^actor(:peer_id))
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    # The person being erased, which is not necessarily the person who asked.
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid
    attribute :mode, :string, allow_nil?: false, default: "proportionate", public?: true
    attribute :requested_by_peer_id, :uuid, public?: true
    # "pending" until the erasure finishes, then "completed".
    attribute :state, :string, allow_nil?: false, default: "pending", public?: true
    # Counts and the mode only: how many messages went, how much knowledge was deleted, and how
    # much merely had this source scrubbed. Never content, and never a list of what was removed.
    attribute :affected_counts, :map, allow_nil?: false, default: %{}, public?: true
    attribute :requested_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule MemHouse.Governance.McpTools do
  @moduledoc """
  The complete tool surface an external agent can reach, declared as generic Ash actions.

  This non-persisted resource publishes tools that delegate to ordinary memory and governance.

  ## What the surface deliberately allows

  It permits raw ingest, governed reads, readiness, the caller's frozen question, and lower
  interruption limits.

  ## What it deliberately does not

  It has no curator, promotion, or gate-rule tool. Those require a password-session human.

  Each action's `description` is what the calling model reads when it decides whether to invoke
  a tool, so a description that overstates what a tool does is a real defect, not a typo.

  Authorization is not decided here. The policy below only requires that some actor is present;
  the Account, the visible scopes, and every durable write are authorized downstream by the
  resources actually touched, using the actor derived from the caller's credential. Arguments
  never select an Account.
  """

  use Ash.Resource,
    otp_app: :memhouse,
    domain: MemHouse.Governance,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    # `scope_path` names where the observation belongs; the Account is taken from the caller's
    # credential and can never be chosen by an argument. The tool call returns
    # after the message and extraction job commit; the pipeline later creates
    # proposals and the gates place them.
    action :ingest, :map do
      description "Submit a raw observation. This never writes knowledge directly."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :role, :string, default: "user", public?: true
      argument :content, :string, allow_nil?: false, public?: true
      run MemHouse.Governance.Actions.McpIngest
    end

    # Reads precomputed projections and calls no model to assemble them. When no usable
    # projection exists it falls back to the cheapest retrieval profile and says so in the
    # result rather than generating an answer.
    action :get_context, :map do
      description "Read reasoning-free context and optionally one self-validation question."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :query, :string, public?: true
      argument :limit, :integer, public?: true
      run {MemHouse.Governance.Actions.McpRead, operation: :get_context}
    end

    # `profile` trades breadth against latency. Search defaults to the balanced profile and ask
    # to the thorough one, because an answer is worth more retrieval work than a list of hits.
    action :search, :map do
      description "Search governed memory and optionally receive one self-validation question."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :query, :string, allow_nil?: false, public?: true
      argument :profile, :string, default: "balanced", public?: true
      argument :limit, :integer, public?: true
      run {MemHouse.Governance.Actions.McpRead, operation: :search}
    end

    action :ask, :map do
      description "Answer from governed memory and optionally receive one self-validation question."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :question, :string, allow_nil?: false, public?: true
      argument :profile, :string, default: "thorough", public?: true
      run {MemHouse.Governance.Actions.McpRead, operation: :ask}
    end

    # Structured listing rather than retrieval. `state` filters on lifecycle state; items the
    # caller is not authorized to see are filtered out before they leave the read path.
    action :query_knowledge, :map do
      description "Read structured governed knowledge visible to the calling peer."
      argument :session_id, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :state, :string, public?: true
      argument :limit, :integer, public?: true
      run {MemHouse.Governance.Actions.McpRead, operation: :query_knowledge}
    end

    action :check_readiness, :map do
      description "Check inherited procedural-memory requirements before running a skill."
      argument :session_id, :string, public?: true
      argument :skill, :string, allow_nil?: false, public?: true
      argument :scope_path, :string, allow_nil?: false, public?: true
      argument :peer_id, :uuid, public?: true
      run {MemHouse.Governance.Actions.McpRead, operation: :check_readiness}
    end

    # The answer is treated as a claim, not proof. `shown_text` is what the agent says it
    # displayed and is checked against the frozen wording; `correction_text` is never stored and
    # cannot mint knowledge — a correction has to come back as an ordinary observation.
    action :resolve_validation, :map do
      description "Answer only a pending validation addressed to the calling peer."
      argument :id, :uuid, allow_nil?: false, public?: true
      argument :verdict, :string, allow_nil?: false, public?: true
      argument :shown_text, :string, public?: true
      argument :correction_text, :string, public?: true
      run MemHouse.Governance.Actions.ResolveValidation
    end

    # Tighten-only, and always about the calling peer: there is no argument naming a peer, and
    # the underlying action clamps every value against what is already stored. `pause_for_hours`
    # is a duration in hours, converted to an absolute resume time before it is written.
    action :set_ask_preference, :map do
      description "Lower or pause the calling peer's inline validation limits."
      argument :max_per_session, :integer, public?: true
      argument :max_per_day, :integer, public?: true
      argument :pause_for_hours, :integer, public?: true
      run MemHouse.Governance.Actions.SetAskPreference
    end
  end

  # Nothing is stored on this resource, so the only thing to check here is that a caller was
  # authenticated at all. Real authorization happens on the resources each action reaches, under
  # the actor derived from the caller's credential; do not add permissive checks here in the
  # belief that they grant anything, and do not weaken this to allow anonymous tool calls.
  policies do
    policy always() do
      authorize_if actor_present()
    end
  end
end
