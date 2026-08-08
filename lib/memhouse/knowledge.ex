# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Knowledge do
  @moduledoc """
  Ash domain for governed statements, provenance, lifecycle evidence, and derived views.

  Only the internal pipeline creates knowledge. New statements enter governance before retrieval;
  subject and source remain distinct. Projections and entity rows are rebuildable caches, not
  durable knowledge or public API data.
  """

  use Ash.Domain

  resources do
    resource MemHouse.Knowledge.KnowledgeItem
    resource MemHouse.Knowledge.Attribution
    resource MemHouse.Knowledge.Provenance
    resource MemHouse.Knowledge.KnowledgeRelation
    resource MemHouse.Knowledge.LifecycleEvent
    resource MemHouse.Knowledge.Projection
    resource MemHouse.Knowledge.Entity
    resource MemHouse.Knowledge.EntityMention
  end
end

defmodule MemHouse.Knowledge.KnowledgeItem do
  @moduledoc """
  One governed statement, the durable atom of MemHouse memory.

  Pipeline-only creation records belief time, valid time, salience, confidence, sensitivity,
  subject, and source independently. Lifecycle actions preserve history; callers must not bypass
  governance or expose held and unauthorized provisional rows.
  """

  use MemHouse.Resource, domain: MemHouse.Knowledge, table: "knowledge_items"

  postgres do
    migration_types diskann_labels: {:array, :smallint}
  end

  # Every query and write is confined to one Account by the Ash tenant, which this resource
  # requires. PostgreSQL row-level security repeats the same check underneath, against a
  # transaction-local Account setting: with no Account set, the policy matches no rows.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    # Pipeline-only. The extractor is the sole writer of knowledge; the `state` validation below
    # pins new rows to `proposed` so the governance gate, not the extractor, decides visibility.
    create :create_from_pipeline do
      accept [
        :scope_id,
        :subject_peer_id,
        :subject_scope_id,
        :statement,
        :kind,
        :confidence,
        :evidence_level,
        :sensitivity,
        :state,
        :target_level,
        :verification,
        :held_scope_id,
        :corroboration_count,
        :supersedes_id,
        :source_message_ids,
        :expires_at,
        :revalidate_after,
        :relevant_from,
        :relevant_until,
        :source_message_ids,
        :extracting_provider,
        :extracting_model,
        :extracting_model_version,
        :prompt_version,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :pipeline_version
      ]

      # When the observation was made. Not an attribute: it belongs to the source, not to the
      # claim, and it is only ever used to date an event the caller left undated.
      argument :observed_at, :utc_datetime_usec

      # Canonicalises the statement text first, so the hash below and the readability validation
      # both see the same form the row will store.
      change MemHouse.Knowledge.Changes.NormalizeStatement

      # Derives `statement_hash` from the statement text. The hash is never accepted from the
      # caller, because deduplication, corroboration merging, and the content-safe audit chain
      # all key off it.
      change MemHouse.Knowledge.Changes.HashStatement

      # Runs before the validation below, which is what lets a caller supply either an explicit
      # `relevant_from` or the observation time to derive one from.
      change MemHouse.Knowledge.Changes.AnchorEventValidity

      # A statement a reader cannot read is not knowledge, whatever else is valid about the row.
      # Enforced here rather than at the extractor so no write path can bypass it.
      validate MemHouse.Knowledge.Validations.ReadableStatement

      validate attribute_in(:kind, ~w(fact preference event relation skill))
      validate attribute_in(:evidence_level, ~w(direct indirect))
      validate attribute_in(:sensitivity, ~w(public internal personal restricted))
      validate attribute_in(:state, ~w(proposed))
      validate attribute_in(:target_level, ~w(peer scope account))

      # An event asserts that something happened at a time, so a row claiming one has to say
      # when. Enforced on the row rather than at each writer: a caller that knows neither the
      # date nor the observation time does not know enough to record an event at all.
      validate present(:relevant_from), where: [attribute_equals(:kind, "event")]
    end

    # Re-observing the same statement corroborates the existing row instead of creating a
    # duplicate. Only the corroboration fields are accepted: the statement, its subject, and its
    # lifecycle state cannot change here. Non-atomic because callers compute the merged values
    # from the loaded row (union of source ids, max confidence, incremented count).
    update :merge_from_pipeline do
      accept [:confidence, :source_message_ids, :corroboration_count]
      require_atomic? false
    end

    # Attaches or replaces the semantic vector. The four identity fields travel with the vector
    # so a later reader can tell whether it was produced by the currently configured embedder.
    update :index_from_pipeline do
      accept [
        :embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :diskann_labels
      ]

      require_atomic? false
    end

    # The only legal way to change lifecycle state. `reason` is mandatory because the lifecycle
    # event and the audit entry both record it; `channel` records which surface drove the
    # decision (governance UI, sweeper, peer answer). Statement text is deliberately absent from
    # the accepted list — a state change can never rewrite the claim.
    update :transition do
      argument :reason, :string, allow_nil?: false
      argument :channel, :string, default: "governance"

      accept [
        :scope_id,
        :state,
        :target_level,
        :verification,
        :held_scope_id,
        :confidence,
        :sensitivity,
        :corroboration_count,
        :supersedes_id,
        :expires_at,
        :revalidate_after,
        :relevant_from,
        :relevant_until,
        :deleted_at
      ]

      # Non-atomic on purpose: the change below needs the pre-update row to know which state the
      # item is leaving, which an atomic SQL update would not provide.
      require_atomic? false

      # Writes the append-only lifecycle event and the hash-chained audit entry inside this same
      # transaction, so a state change can never commit without its evidence.
      change MemHouse.Knowledge.Changes.RecordTransition

      validate attribute_in(
                 :state,
                 ~w(proposed active provisional held needs_revalidation superseded expired rejected contested redacted stale retracted)
               )

      validate attribute_in(:sensitivity, ~w(public internal personal restricted))
      validate attribute_in(:target_level, ~w(peer scope account))
    end

    # Hard delete, reached only through the subject-erasure flow. Ordinary retirement of a
    # statement is a `transition` to a terminal state, which keeps the row and its history.
    destroy :erase do
      require_atomic? false
    end
  end

  # All applicable policies must pass, and within one policy any `authorize_if` may satisfy it.
  policies do
    # Account isolation applies to every action, including the pipeline's own writes.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # A reader sees statements in the scopes their resolved roles allow, plus every statement
    # about themselves regardless of scope — that self-view is what makes contesting and erasure
    # requests possible. Neither branch filters lifecycle state; the caller must do that.
    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
      authorize_if expr(subject_peer_id == ^actor(:peer_id))
    end

    # Minting, corroborating, and embedding are pipeline-internal. No human role can reach them,
    # which is what keeps "agents submit observations, the pipeline writes knowledge" true.
    policy action([:create_from_pipeline, :merge_from_pipeline, :index_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Curator decisions are human-only: `HumanRoleIn` matches only password-authenticated
    # identities, so a machine API key with an admin role still cannot approve, reject, or erase.
    # The pipeline branch covers automatic gate results, the aging sweeper, and erasure jobs.
    policy action([:transition, :erase]) do
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin, :curator]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false

    # Where the statement lives, and therefore who inherits access to it.
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    # Internal filtered-DiskANN metadata. It is derived from the scope and is
    # deliberately absent from public responses, export, audit, and jobs.
    attribute :diskann_labels, {:array, :integer}, allow_nil?: false, default: [], public?: false

    # Exactly one of these two identifies the subject: the peer the claim is about, or the scope
    # the claim characterises. Neither is the source of the claim.
    attribute :subject_peer_id, :uuid, public?: true
    attribute :subject_scope_id, :uuid, public?: true

    attribute :statement, :string,
      allow_nil?: false,
      constraints: [min_length: 1],
      public?: true

    # Derived from the statement, never accepted from a caller. Deduplication keys off it, and
    # audit events carry this hash instead of the text so the audit log stays content-free.
    attribute :statement_hash, :string, allow_nil?: false

    attribute :kind, :string,
      allow_nil?: false,
      default: "fact",
      public?: true

    attribute :confidence, :float,
      allow_nil?: false,
      default: 0.5,
      constraints: [min: 0.0, max: 1.0],
      public?: true

    # Derived from the schema context. Gate A can automate only direct
    # self-observations, never a model's self-reported confidence.
    attribute :evidence_level, :string,
      allow_nil?: false,
      default: "indirect",
      public?: true

    attribute :sensitivity, :string,
      allow_nil?: false,
      default: "internal",
      public?: true

    attribute :state, :string,
      allow_nil?: false,
      default: "proposed",
      public?: true

    attribute :target_level, :string,
      allow_nil?: false,
      default: "peer",
      public?: true

    # Why the row is in its current state: "pending", an automatic keep or rejection, a curator
    # decision, a subject confirmation or dispute, an expiry, and so on.
    attribute :verification, :string, allow_nil?: false, default: "pending", public?: true

    # Where a scope- or account-level proposal is parked while it waits for approval. A held
    # item stays at its source scope and must not appear in retrieval at the requested level.
    attribute :held_scope_id, :uuid, public?: true

    # How many independent observations produced the same statement. Starts at 1 and is raised
    # by the corroboration merge, never by re-extraction of the same message.
    attribute :corroboration_count, :integer, allow_nil?: false, default: 1, public?: true

    # Links a statement to its replacement counterpart. A curator edit sets it on the new row,
    # pointing back at the text being replaced; a merge sets it on the row being absorbed,
    # pointing at the surviving statement. In both directions the retired row keeps its own
    # text, provenance, and lifecycle trail.
    attribute :supersedes_id, :uuid, public?: true

    # Belief time: when the system should stop trusting or should re-ask about this claim.
    attribute :expires_at, :utc_datetime_usec, public?: true
    attribute :revalidate_after, :utc_datetime_usec, public?: true

    # Valid time: the window in which the claim is true in the world, independent of belief.
    attribute :relevant_from, :utc_datetime_usec, public?: true
    attribute :relevant_until, :utc_datetime_usec, public?: true

    # Raw messages that contributed this statement. Erasure prunes ids from this list rather
    # than deleting a statement that other sources still support.
    attribute :source_message_ids, {:array, :uuid}, allow_nil?: false, default: [], public?: true

    # Which model, at which version, under which prompt produced the statement. Kept so an
    # extractor regression can be traced to the exact rows it created.
    attribute :extracting_provider, :string, public?: true
    attribute :extracting_model, :string, public?: true
    attribute :extracting_model_version, :string, public?: true
    attribute :prompt_version, :string, public?: true

    # Embedding identity. Vectors are only comparable inside one provider/model/version/
    # dimensions tuple; a mismatch means re-embed, never reuse.
    attribute :embedding_provider, :string, public?: true
    attribute :embedding_model, :string, public?: true
    attribute :embedding_version, :string, public?: true

    # Excluded from default selects because vectors are large and almost never wanted alongside
    # ordinary reads; retrieval selects the column explicitly.
    attribute :embedding, :vector, select_by_default?: false
    attribute :embedding_dimensions, :integer, public?: true

    # Version identity of the extraction pipeline that produced the row. The value "f5-1" is the
    # current extractor/pipeline contract, also reported by the health endpoint. Bumping it is a
    # deliberate contract transition: it needs a changelog entry, refreshed contract evidence,
    # and a note in the closest architecture document. Rows written by earlier pipelines keep
    # the value they were created with.
    attribute :pipeline_version, :string, allow_nil?: false, default: "f5-1", public?: true

    # Set by erasure and redaction flows. Not public, so it never leaks into API payloads.
    attribute :deleted_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule MemHouse.Knowledge.Validations.ReadableStatement do
  @moduledoc """
  Keeps unreadable text out of the statement column.

  A statement is the knowledge atom and the only durable record of a claim, so a row whose text
  a reader cannot understand is worse than no row: it is retrievable, citable, and permanent.
  The failure this stops is a model generation that collapses into repeated ellipsis or
  invisible padding. Such text satisfies `min_length: 1`, satisfies the extraction schema, and
  reaches the console looking like knowledge.

  `MemHouse.Knowledge.Statement` holds the rule itself and states what it does not catch.
  """

  use Ash.Resource.Validation

  alias MemHouse.Knowledge.Statement

  @doc """
  Rejects statement text that carries too few real characters to read.

  Returns `:ok`, including when the changeset has no statement — a missing one is the
  attribute's own `allow_nil?` failure, and reporting it twice tells a caller nothing extra.
  """
  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :statement) do
      statement when is_binary(statement) ->
        if Statement.prose?(statement) do
          :ok
        else
          {:error, field: :statement, message: "must be readable text, not filler characters"}
        end

      _other ->
        :ok
    end
  end
end

defmodule MemHouse.Knowledge.Attribution do
  @moduledoc """
  Records what a statement is about and how directly it was learned.

  Subject and source are independent. Hearsay and direct attribution remain explicit so
  governance can discount or require consent correctly.
  """

  use MemHouse.Resource, domain: MemHouse.Knowledge, table: "attributions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Create-only, pipeline-only. There is no update action: an attribution is either right or
    # replaced by erasure plus re-extraction.
    create :create_from_pipeline do
      accept [
        :knowledge_item_id,
        :scope_id,
        :target_type,
        :target_peer_id,
        :target_scope_id,
        :level
      ]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Attributions inherit the visibility of the scope the statement lives in.
    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:create_from_pipeline) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false

    # "peer" or "scope"; the matching id below is set and the other stays nil.
    attribute :target_type, :string, allow_nil?: false, public?: true
    attribute :target_peer_id, :uuid, public?: true
    attribute :target_scope_id, :uuid, public?: true

    # "self", "hearsay", or "scope" — derived source-to-subject relationship.
    attribute :level, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  # One attribution per statement/target/level combination, per Account. Because one of the two
  # target columns is always NULL, and PostgreSQL treats NULLs as distinct in a unique index,
  # this identity does not by itself stop a duplicate: the pipeline looks for an existing row
  # before creating one, and that read is what makes a re-extraction idempotent.
  identities do
    identity :knowledge_target,
             [:knowledge_item_id, :target_type, :target_peer_id, :target_scope_id, :level]
  end
end

defmodule MemHouse.Knowledge.Provenance do
  @moduledoc """
  Append-only evidence linking a statement to one source.

  Independent provenance keeps knowledge alive when one source is superseded or erased. Content
  is referenced by ids and hashes rather than copied into audit-facing metadata.
  """

  use MemHouse.Resource, domain: MemHouse.Knowledge, table: "provenances"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Append-only: pipeline creates, erasure destroys, nothing updates.
    create :create_from_pipeline do
      accept [
        :knowledge_item_id,
        :scope_id,
        :source_type,
        :message_id,
        :document_version_id,
        :extracting_provider,
        :extracting_model,
        :extracting_model_version,
        :prompt_version,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :pipeline_version,
        :occurred_at
      ]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:create_from_pipeline) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false

    # "message" or "document"; exactly one of the two source ids below is populated to match.
    attribute :source_type, :string, allow_nil?: false, public?: true
    attribute :message_id, :uuid, public?: true
    attribute :document_version_id, :uuid, public?: true

    # Model and prompt identity captured at extraction time, so a later model change cannot
    # retroactively rewrite the story of how this statement was produced.
    attribute :extracting_provider, :string, public?: true
    attribute :extracting_model, :string, public?: true
    attribute :extracting_model_version, :string, public?: true
    attribute :prompt_version, :string, public?: true
    attribute :embedding_provider, :string, public?: true
    attribute :embedding_model, :string, public?: true
    attribute :embedding_version, :string, public?: true

    # No default here, unlike the statement itself: the caller must state which pipeline
    # contract version produced this evidence row.
    attribute :pipeline_version, :string, allow_nil?: false, public?: true

    # When the source event happened, which can be far earlier than when it was ingested.
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule MemHouse.Knowledge.KnowledgeRelation do
  @moduledoc """
  A typed directed edge between governed statements.

  Relations are Account-scoped and readable only when both statement scopes are authorized. An
  edge may aid retrieval but never grants access.
  """

  use MemHouse.Resource,
    domain: MemHouse.Knowledge,
    table: "knowledge_relations"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_from_pipeline do
      accept [:scope_id, :source_knowledge_id, :target_knowledge_id, :kind, :confidence]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:create_from_pipeline) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false
    # Direction matters: for a supersession edge the source is the replacement and the target is
    # the statement being retired.
    attribute :source_knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :target_knowledge_id, :uuid, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, public?: true

    # Strength of the edge, reused as the expansion score when retrieval walks it.
    attribute :confidence, :float, allow_nil?: false, default: 1.0, public?: true
    create_timestamp :inserted_at
  end

  # One edge per ordered pair and kind, per Account, so replaying the same supersession is a
  # no-op rather than a duplicate.
  identities do
    identity :unique_relation, [:source_knowledge_id, :target_knowledge_id, :kind]
  end
end

defmodule MemHouse.Knowledge.LifecycleEvent do
  @moduledoc """
  Append-only evidence of one knowledge lifecycle transition.

  Events are written in the same transaction as the state change and retain content-safe actor,
  reason, channel, and timing data.
  """

  use MemHouse.Resource,
    domain: MemHouse.Knowledge,
    table: "knowledge_lifecycle_events"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Append-only. Called from the knowledge transition change and from the extraction pipeline
    # when a statement is first proposed, never directly by a surface.
    create :record do
      accept [:knowledge_item_id, :scope_id, :from_state, :to_state, :reason, :occurred_at]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    # Curators, admins, internal system actors, and the pipeline may append history. Unlike the
    # curator decision itself, this check is not human-only, because automatic gate results and
    # the aging sweeper must also be able to record what they did.
    policy action(:record) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false

    # The state being left. Nil on the pipeline's initial "proposed" event; the transition change
    # fills it from the pre-update row.
    attribute :from_state, :string, public?: true
    attribute :to_state, :string, allow_nil?: false, public?: true

    # A short machine-readable reason code, not free-form content. Keep statement text out of
    # it: this row is part of the content-safe evidence trail.
    attribute :reason, :string, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end
end

defmodule MemHouse.Knowledge.Projection do
  @moduledoc """
  A rebuildable scope, peer, session, or entity context cache.

  Knowledge remains authoritative. Projections carry source ids, dirty state, and bounded deltas
  so invalidation or loss can be repaired without reasoning during ordinary context reads.
  """

  use MemHouse.Resource, domain: MemHouse.Knowledge, table: "projections"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Upsert on the Account-local cache key so a refresh either creates the projection or
    # replaces its contents; the identifying columns (scope, peer, session, kind) are set once
    # at creation and are deliberately absent from the upsert field list below.
    create :upsert_from_pipeline do
      accept [
        :cache_key,
        :scope_id,
        :peer_id,
        :session_id,
        :entity_id,
        :kind,
        :sensitivity,
        :version,
        :content,
        :source_ids,
        :dirty,
        :watermark,
        :delta_count
      ]

      upsert? true
      upsert_identity :cache_key

      upsert_fields [
        :version,
        :sensitivity,
        :content,
        :source_ids,
        :dirty,
        :watermark,
        :delta_count,
        :updated_at
      ]
    end

    # The "mark dirty" path. It accepts the content fields as well, but every caller in this
    # codebase only flips the flag; full rewrites go through the upsert above.
    update :refresh_from_pipeline do
      accept [:sensitivity, :version, :content, :source_ids, :dirty, :watermark, :delta_count]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # A projection is readable by anyone who may read its scope. Shared scope/session content is
    # active-only; provisional content is stored only in a subject-keyed peer-profile projection.
    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    # Only the refresh pipeline may write a cache. No human surface can hand-edit a projection,
    # because the next rebuild would silently discard the edit anyway.
    policy action([:upsert_from_pipeline, :refresh_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false

    # Identity of this projection inside the Account, e.g. a scope card key, a scope-plus-peer
    # profile key, or a scope-plus-session summary key.
    attribute :cache_key, :string, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false

    # Set only for the projection kinds that need them: peer profiles, session summaries, and
    # entity cards. Entity ids remain private cache coordinates and never enter context payloads.
    attribute :peer_id, :uuid, public?: true
    attribute :session_id, :uuid, public?: true
    attribute :entity_id, :uuid
    attribute :kind, :string, allow_nil?: false, public?: true

    # The strictest sensitivity among an entity card's sources. Core read authorization is still
    # scope-based; retaining this classification prevents a synthesized card from losing the
    # source set's blast-radius metadata and leaves a safe filter point for future field policy.
    attribute :sensitivity, :string

    # Monotonic per projection; raised on every rebuild so a stale reader can detect drift.
    attribute :version, :integer, allow_nil?: false, default: 1, public?: true

    # The assembled payload. Not public: it is served through the context assembly layer, which
    # applies the caller's budget and ordering, rather than exposed as a raw resource field.
    attribute :content, :map, allow_nil?: false, default: %{}

    # Statement ids the content was built from. Incremental merges keep only entries whose
    # source id is still present, so retracted statements drop out of the cache.
    attribute :source_ids, {:array, :uuid}, allow_nil?: false, default: []

    # True once an underlying statement changed and before the rebuild ran. Readers must not
    # serve a dirty projection.
    attribute :dirty, :boolean, allow_nil?: false, default: false, public?: true

    # When the content was last rebuilt.
    attribute :watermark, :utc_datetime_usec

    # Incremental merges since the last full rebuild. The refresh job compacts fully once this
    # crosses the configured cadence, bounding how far a merged cache can drift from a clean
    # rebuild.
    attribute :delta_count, :integer, allow_nil?: false, default: 0
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # Unique per Account: the tenant attribute is part of the generated index, so the same cache
  # key in another Account is a different row.
  identities do
    identity :cache_key, [:cache_key]
  end
end

defmodule MemHouse.Knowledge.Entity do
  @moduledoc """
  Pipeline-internal rebuildable cache for one resolved entity.

  Entity rows support retrieval only. Names, aliases, and ids must never appear in external,
  console, SDK, projection, or retrieval payloads.
  """

  use MemHouse.Resource, domain: MemHouse.Knowledge, table: "entities"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Upsert on canonical name plus kind so a concurrent resolution pass converges on one row
    # instead of creating a near-duplicate entity.
    create :create_from_pipeline do
      accept [
        :canonical_name,
        :kind,
        :aliases,
        :alias_embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :derived_from
      ]

      upsert? true
      upsert_identity :canonical_name_kind

      upsert_fields [
        :aliases,
        :alias_embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :derived_from,
        :updated_at
      ]
    end

    # Folding a newly seen spelling into an existing entity: widens the alias list, re-embeds the
    # combined names, and appends the contributing statement id.
    update :recompute_from_pipeline do
      accept [
        :canonical_name,
        :kind,
        :aliases,
        :alias_embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :derived_from
      ]
    end

    # Used both by subject erasure and by the pruning pass that drops entities left without any
    # mention after a rebuild.
    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Note that reads are pipeline-only, not scope-gated: this cache has no public surface at
    # all. Adding a route or tool that exposes it would leak names across scope boundaries,
    # because an entity spans every scope that mentioned it.
    policy action([:read, :create_from_pipeline, :recompute_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false

    # The first surface form that created the row, plus a coarse inferred kind (for example a
    # person or an organisation). Neither is authoritative; both are resolution heuristics.
    attribute :canonical_name, :string, allow_nil?: false
    attribute :kind, :string, allow_nil?: false

    # Every spelling folded onto this entity so far. Exact alias matching is the cheap first
    # resolution step, before any embedding comparison runs.
    attribute :aliases, {:array, :string}, allow_nil?: false, default: []

    # Embedding of the canonical name and aliases together, used for cosine comparison against a
    # newly seen surface form. Excluded from default selects because it is large.
    attribute :alias_embedding, :vector, select_by_default?: false

    # Pinned embedder identity for the vector above; comparisons are only meaningful within one
    # provider/model/version/dimensions tuple.
    attribute :embedding_provider, :string
    attribute :embedding_model, :string
    attribute :embedding_version, :string
    attribute :embedding_dimensions, :integer

    # Statements that contributed to this entity. The audit trail of a derived row, and the
    # reason the cache can always be rebuilt from surviving knowledge.
    attribute :derived_from, {:array, :uuid}, allow_nil?: false, default: []
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One row per canonical name and kind within an Account.
  identities do
    identity :canonical_name_kind, [:canonical_name, :kind]
  end
end

defmodule MemHouse.Knowledge.EntityMention do
  @moduledoc """
  Rebuildable link between a statement and an entity mention.

  It is pipeline-internal retrieval data. Erasure and import recompute it from surviving governed
  statements. No external surface may read these rows. One derived value leaves: the pipeline may
  fold a mention's `surface_form` into an entity card as that card's label, bounded to the card's
  own sources in its own scope.
  """

  use MemHouse.Resource, domain: MemHouse.Knowledge, table: "entity_mentions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create_from_pipeline do
      accept [:knowledge_item_id, :scope_id, :entity_id, :surface_form, :confidence]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Pipeline-only reads, matching the entity rows: this cache has no public surface.
    policy action([:read, :create_from_pipeline]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :knowledge_item_id, :uuid, allow_nil?: false

    # Copied from the statement so a rebuild can scope its work; it is not an access grant.
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :entity_id, :uuid, allow_nil?: false

    # The exact text that matched inside the statement. Content-bearing, so it leaves this cache
    # only as an entity card's label, and only when the card's own sources supply it (ADR 0011).
    attribute :surface_form, :string, allow_nil?: false

    # How sure the resolver is about this link. When retrieval expands from one statement to
    # another through a shared entity, the lower of the two mention confidences becomes the
    # neighbour's edge score, so a shaky match contributes a weak candidate.
    attribute :confidence, :float, allow_nil?: false
    create_timestamp :inserted_at
  end

  # One row per statement, entity, and surface form, so re-running resolution is idempotent.
  identities do
    identity :knowledge_entity_surface, [:knowledge_item_id, :entity_id, :surface_form]
  end
end
