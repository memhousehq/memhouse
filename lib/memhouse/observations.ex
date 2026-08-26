# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Observations do
  @moduledoc """
  Ash domain for immutable raw messages and document versions.

  Agents and connectors write observations, never knowledge. Creation preserves original content
  and atomically records content-safe audit, idempotency, and extraction work. Document changes
  append versions or tombstones instead of overwriting history.
  """

  use Ash.Domain

  resources do
    resource MemHouse.Observations.Session
    resource MemHouse.Observations.SessionScope
    resource MemHouse.Observations.SessionParticipant
    resource MemHouse.Observations.Message
    resource MemHouse.Observations.Document
    resource MemHouse.Observations.DocumentVersion
  end
end

defmodule MemHouse.Observations.Session do
  @moduledoc """
  One conversation or agent run containing raw observations.

  Sessions are Account- and scope-bound through explicit links. They preserve source context but
  do not themselves become knowledge.
  """

  use MemHouse.Resource, domain: MemHouse.Observations, table: "sessions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    # Upsert keyed on the caller's external id, so repeated ingest calls for the same
    # conversation converge on one row. Only `status` is refreshed on a repeat; the scope, the
    # owning peer, and the opening time stay as first observed.
    create :ensure do
      accept [:scope_id, :peer_id, :external_id, :status, :opened_at]
      upsert? true
      upsert_identity :external_id
      upsert_fields [:status, :updated_at]
      change MemHouse.Context.Changes.InvalidateProjectionInputs
    end

    update :update do
      accept [:status, :closed_at]
      require_atomic? false
      change MemHouse.Context.Changes.InvalidateProjectionInputs
    end

    destroy :erase do
      require_atomic? false
      change MemHouse.Context.Changes.InvalidateProjectionInputs
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Creating and closing a session is ordinary Account-scoped metadata work, so those actions
    # are covered by the Account policy above and need no extra role check.
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # The peer that opened the session. Participants, including this one, are listed separately.
    attribute :peer_id, :uuid, allow_nil?: false, public?: true

    # The caller's own handle for the conversation; the upsert key.
    attribute :external_id, :string, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, default: "open", public?: true

    # Reserved and currently unwritten: no action accepts it. Summaries served to callers come
    # from the projection cache, not from this column.
    attribute :summary, :string
    attribute :opened_at, :utc_datetime_usec, public?: true
    attribute :closed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # Unique per Account: two Accounts may use the same external id without colliding.
  identities do
    identity :external_id, [:external_id]
  end
end

defmodule MemHouse.Observations.SessionScope do
  @moduledoc """
  Links a session to one scope with an association confidence.

  The link is Account-scoped and does not grant access; ordinary scope authorization still
  applies.
  """

  use MemHouse.Resource, domain: MemHouse.Observations, table: "session_scopes"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Idempotent on the session/scope pair; a repeat only refreshes the classification.
    create :ensure do
      accept [:session_id, :scope_id, :classification, :confirmed_at]
      upsert? true
      upsert_identity :session_scope
      upsert_fields [:classification, :confirmed_at, :updated_at]
    end

    # Promotes a tentative association once the scope is known for certain.
    update :confirm do
      accept [:classification, :confirmed_at]
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

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :session_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # "tentative" while the scope was only inferred, "confirmed" once stated explicitly.
    attribute :classification, :string, allow_nil?: false, default: "tentative", public?: true
    attribute :confirmed_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One row per session and scope, per Account.
  identities do
    identity :session_scope, [:session_id, :scope_id]
  end
end

defmodule MemHouse.Observations.SessionParticipant do
  @moduledoc """
  Records one Peer's membership in a session.

  Membership supplies provenance and speaker context but does not create a role grant.
  """

  use MemHouse.Resource,
    domain: MemHouse.Observations,
    table: "session_participants"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Idempotent on the session/peer pair; only the role is refreshed on a repeat.
    create :ensure do
      accept [:session_id, :peer_id, :role, :joined_at]
      upsert? true
      upsert_identity :session_peer
      upsert_fields [:role, :updated_at]
    end

    # Records departure by stamping `left_at`; the membership row itself survives, because the
    # peer really was present for the turns already recorded.
    update :leave do
      accept [:left_at]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    # There is no scope attribute to filter on, so Account isolation is the only read guard here.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :session_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, default: "participant", public?: true
    attribute :joined_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :left_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :session_peer, [:session_id, :peer_id]
  end
end

defmodule MemHouse.Observations.Message do
  @moduledoc """
  One immutable raw conversational turn.

  Creation is the external ingest write: it hashes content and atomically appends audit,
  idempotency, replay-safe extraction work, and a coalesced source-index refresh. Only the
  pipeline may turn it into knowledge or write the derived semantic index.
  """

  use MemHouse.Resource, domain: MemHouse.Observations, table: "messages"

  postgres do
    migration_types diskann_labels: {:array, :smallint}
  end

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Create-only for content. The two changes below run in order: hashing must happen before
    # the audit-and-enqueue hook, which uses the hash as the audit content reference and as the
    # deterministic idempotency key of the extraction job. The same hook also schedules the
    # scope-coalesced source index refresh; it never calls a provider in this transaction.
    create :create do
      accept [:session_id, :scope_id, :peer_id, :role, :content, :occurred_at]

      change MemHouse.Observations.Changes.HashContent
      change MemHouse.Observations.Changes.AuditAndEnqueueMessage
      change MemHouse.Context.Changes.InvalidateProjectionInputs
    end

    # Pipeline bookkeeping only: stamps when extraction finished. It cannot touch content.
    update :mark_extracted do
      accept [:extraction_completed_at]
      require_atomic? false
    end

    # Derived source-search data only. The immutable observation remains the
    # source of truth and a failed refresh leaves its previous index intact.
    update :index_from_pipeline do
      accept [
        :embedding,
        :embedding_provider,
        :embedding_model,
        :embedding_version,
        :embedding_dimensions,
        :diskann_labels,
        :source_indexed_at
      ]

      require_atomic? false
    end

    destroy :erase do
      require_atomic? false
      change MemHouse.Context.Changes.InvalidateProjectionInputs
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    # Submitting an observation deliberately needs no role beyond belonging to the Account: any
    # authenticated agent or peer may say what it saw. The restriction that matters is on the
    # other side — none of them can turn an observation into knowledge.

    policy action(:mark_extracted) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:index_from_pipeline) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :session_id, :uuid, allow_nil?: false, public?: true

    # The scope the turn was observed in. Anything extracted from it inherits this scope.
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # Who produced the turn. This is the *source*; who the turn is about is decided later by
    # extraction and recorded on the knowledge statement, not here.
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, public?: true

    # Verbatim observed text. Never rewritten.
    attribute :content, :string, allow_nil?: false, public?: true

    # SHA-256 of the content, derived on create. Not public, because it is machinery: it keys
    # the extraction job and stands in for the text in the audit chain.
    attribute :content_hash, :string, allow_nil?: false

    # Rebuildable source-recall index. Identity travels with every vector so a
    # query never compares coordinates from different embedding spaces.
    attribute :diskann_labels, {:array, :integer}, allow_nil?: false, default: []
    attribute :embedding_provider, :string
    attribute :embedding_model, :string
    attribute :embedding_version, :string
    attribute :embedding_dimensions, :integer
    attribute :embedding, :vector, select_by_default?: false
    attribute :source_indexed_at, :utc_datetime_usec

    # When the turn happened, which may be earlier than when it was submitted.
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true

    # Pipeline bookkeeping; not public.
    attribute :extraction_completed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

defmodule MemHouse.Observations.Document do
  @moduledoc """
  Stable identity for a logical source document.

  Connectors append immutable versions beneath this row. Remote deletion records a tombstone;
  history is never overwritten.
  """

  use MemHouse.Resource, domain: MemHouse.Observations, table: "documents"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Registers the logical document only. No content, no audit entry, and no job: those belong
    # to the version that carries the bytes, which is why this action has no attached changes.
    create :create do
      accept [
        :scope_id,
        :owner_peer_id,
        :connector_config_id,
        :external_id,
        :title,
        :source_kind,
        :source_uri,
        :source_metadata,
        :status
      ]
    end

    # Descriptive fields only. Nothing here can change which bytes the document points at.
    update :update_metadata do
      accept [:title, :source_uri, :source_metadata]
    end

    # Moves the current-version pointer after a new immutable version has been written, and
    # clears any tombstone because the source produced content again.
    update :publish_version do
      accept [:current_version_id, :current_content_hash, :status, :tombstoned_at]
      require_atomic? false
    end

    # Remote deletion. The row and all its versions stay; only the status changes, so provenance
    # for knowledge already derived from the document remains intact.
    update :tombstone do
      accept [:status, :tombstoned_at]
      require_atomic? false
    end

    # Import-only. A logical archive restores documents and versions in dependency order, so the
    # pointer to the current version is written in a second pass once that version exists. The
    # change writes whatever attributes the archive supplied directly, bypassing the accept list
    # on purpose — this is a restore of previously durable state, not new authored input.
    update :portability_restore do
      public? false
      require_atomic? false
      accept []
      argument :attributes, :map, allow_nil?: false
      change MemHouse.Portability.Changes.RestoreAttributes
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

    # Uploading a document is ordinary member work, but only in a scope where the caller holds
    # one of these roles. The pipeline branch covers connector-driven ingest.
    policy action(:create) do
      authorize_if {MemHouse.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:update_metadata) do
      authorize_if {MemHouse.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Version publication, tombstoning, and hard deletion must stay consistent with version
    # rows, blobs, chunks, and derived knowledge, so they are pipeline-internal.
    policy action([:publish_version, :tombstone, :erase]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    policy action(:portability_restore) do
      authorize_if actor_attribute_equals(:pipeline?, true)
      authorize_if {MemHouse.Policy.RoleIn, roles: [:system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :owner_peer_id, :uuid, public?: true

    # Set when the document arrived through a connector; nil for a direct upload.
    attribute :connector_config_id, :uuid, public?: true

    # Pointer to the version in force. The hash is the sync comparison key: an incoming payload
    # whose hash matches is a no-op, so re-syncing costs nothing and creates no history.
    attribute :current_version_id, :uuid, public?: true
    attribute :current_content_hash, :string, public?: true

    # The source system's own identifier, unique per connector within an Account.
    attribute :external_id, :string, public?: true
    attribute :title, :string, allow_nil?: false, public?: true

    # How the document arrived, e.g. an upload or a named connector kind.
    attribute :source_kind, :string, allow_nil?: false, default: "upload", public?: true
    attribute :source_uri, :string, public?: true

    # Connector-supplied descriptive metadata. It can carry source-side content, so it must not
    # be copied into audit metadata, telemetry, or job arguments.
    attribute :source_metadata, :map, allow_nil?: false, default: %{}, public?: true

    # "active" or tombstoned. A tombstone marks remote deletion without destroying history.
    attribute :status, :string, allow_nil?: false, default: "active", public?: true
    attribute :tombstoned_at, :utc_datetime_usec, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # One document per connector and external id, per Account. Two connectors may legitimately
  # expose the same external id, which is why the connector is part of the key.
  identities do
    identity :source_external_id, [:connector_config_id, :external_id]
  end
end

defmodule MemHouse.Observations.DocumentVersion do
  @moduledoc """
  Immutable snapshot of a document's bytes and metadata.

  Repeated content hashes are no-ops, changed content appends a version, and extraction proceeds
  through the ordinary governed pipeline. Bytes and connector metadata must not enter audit,
  telemetry, or job arguments.
  """

  use MemHouse.Resource,
    domain: MemHouse.Observations,
    table: "document_versions"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :document_id,
        :scope_id,
        :version,
        :content,
        :content_hash,
        :byte_size,
        :blob_ref,
        :media_type,
        :source_metadata,
        :occurred_at
      ]

      # Order matters. Hashing runs first because the audit-and-enqueue hook uses the hash as
      # the audit content reference and as the extraction job's idempotency key. Unlike
      # messages, the hash may be supplied: byte ingest already hashed the payload to address
      # the blob, and the version must carry that same digest rather than a hash of whatever
      # inline text happens to be present.
      change MemHouse.Observations.Changes.HashContentIfMissing
      change MemHouse.Observations.Changes.AuditAndEnqueueDocument
    end

    # Records the outcome of parsing, chunking, and embedding. Everything it writes is a
    # rebuildable cache; none of it changes the bytes this version stands for.
    update :mark_processed do
      accept [
        :extracted_text,
        :extraction_metadata,
        :chunk_count,
        :embedded_chunk_count,
        :processing_status,
        :extraction_completed_at
      ]

      require_atomic? false
    end

    # Records a failed processing attempt as a status plus an error *class*. The raw version and
    # its retryable job survive, so a later attempt can succeed without re-ingesting.
    update :mark_failed do
      accept [:processing_status, :last_error_class]
      require_atomic? false
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

    # Appending a version is submitting an observation: allowed for scope members, curators, and
    # admins, and for connector-driven ingest running as the pipeline.
    policy action(:create) do
      authorize_if {MemHouse.Policy.ScopeRole, roles: [:account_admin, :curator, :member]}
      authorize_if actor_attribute_equals(:pipeline?, true)
    end

    # Processing outcomes and deletion belong to the pipeline; a caller cannot claim a document
    # was processed, nor mark it failed to stop it being retried.
    policy action([:mark_processed, :mark_failed, :erase]) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :document_id, :uuid, allow_nil?: false, public?: true
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # Monotonic per document, starting at 1. Ordering history, not a semantic version.
    attribute :version, :integer, allow_nil?: false, public?: true

    # Inline payload. Normally nil, because bytes live in the blob store; it exists for rows
    # that predate blob storage and is not public.
    attribute :content, :string

    # SHA-256 of the payload. It addresses the blob, keys the extraction job, stands in for the
    # bytes in the audit chain, and tells sync whether anything actually changed.
    attribute :content_hash, :string, allow_nil?: false, public?: true
    attribute :byte_size, :integer, allow_nil?: false, default: 0, public?: true

    # Where the bytes actually are. Not public: it is storage addressing, and the adapter behind
    # it (local filesystem or object storage) is a deployment choice with no product meaning.
    attribute :blob_ref, :string, allow_nil?: false
    attribute :media_type, :string, allow_nil?: false, default: "text/plain", public?: true

    # Source-side descriptive metadata; can carry content, so keep it out of audit and telemetry.
    attribute :source_metadata, :map, allow_nil?: false, default: %{}, public?: true

    # Derived parse results. Rebuildable from the blob, excluded from logical export, and not
    # public — retrieval serves document text from the derived chunk cache, not from here.
    attribute :extracted_text, :string
    attribute :extraction_metadata, :map, allow_nil?: false, default: %{}

    # Progress counters for the derived chunk cache; also rebuilt by re-processing.
    attribute :chunk_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :embedded_chunk_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :processing_status, :string, allow_nil?: false, default: "pending", public?: true

    # An error class name only, never a provider message, so operators can see failure shapes
    # without seeing document content.
    attribute :last_error_class, :string

    # When the source produced this version, which is not when it was ingested.
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :extraction_completed_at, :utc_datetime_usec

    # No update timestamp: the durable facts of a version never change after creation.
    create_timestamp :inserted_at
  end

  # Two guarantees per Account: version numbers do not repeat within a document, and the same
  # bytes are never stored twice for the same document. The second one is what makes a repeated
  # sync of unchanged content a no-op instead of a growing history.
  identities do
    identity :document_version, [:document_id, :version]
    identity :document_hash, [:document_id, :content_hash]
  end
end
