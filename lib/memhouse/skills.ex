# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Skills do
  @moduledoc """
  Ash domain for procedural memory: what a person or agent must already know before running a
  skill, and whether they know it yet.

  A human-authored skill card defines which governed knowledge a scope requires and whether each
  gap blocks or warns.

  ## Cards are authored configuration, not knowledge

  Cards take effect when published as a new immutable version and do not pass governance. A card
  cannot satisfy itself; only governed knowledge can satisfy requirements.

  ## Inheritance

  Requirements inherit down the scope tree and merge by key, nearest scope wins. A child scope
  can override an inherited requirement by reusing its key, add new keys, or switch an inherited
  key off. Descendants therefore do not carry copies of their ancestors' cards.

  ## Readiness

  Readiness compares selectors with authorized knowledge and runs no model, text search, or
  reasoning. Required gaps block; preferred gaps warn. Expired or due-for-revalidation knowledge
  never satisfies a requirement, even before the sweeper runs.

  When a requirement permits it, the report may include a prompt to ask the person for the
  missing information. Their answer is not knowledge: it must be submitted as an ordinary raw
  observation, pass extraction and the approval gates, and only then can it satisfy the
  requirement on a later check. Nothing in this domain writes knowledge.
  """

  use Ash.Domain

  resources do
    resource MemHouse.Skills.SkillRequirementCard
  end

  @doc """
  Publishes a new version of a skill requirement card. See `MemHouse.Skills.Authoring.publish/2`.
  """
  defdelegate publish(actor, attrs), to: MemHouse.Skills.Authoring

  @doc """
  Produces a gap report for one skill, peer, and scope.
  See `MemHouse.Skills.Readiness.check_readiness/2`.
  """
  defdelegate check_readiness(actor, attrs), to: MemHouse.Skills.Readiness
end

defmodule MemHouse.Skills.SkillRequirementCard do
  @moduledoc """
  One published, immutable version of the knowledge a skill requires at one scope.

  A row is: this Account, this scope, this skill key, this version number, and the list of
  normalized requirements in force. Publishing never edits a row — it inserts the next version
  and deactivates the previous one — so the exact contract that was in force when a past
  readiness check ran is still readable afterwards.

  Rows are authored configuration rather than extracted knowledge. They do not pass the approval
  gates, they are not meant to hold user content, and their requirements can only be *satisfied*
  by governed knowledge, never by another card.

  ## Reading a row

  `requirements` is a list of normalized requirement maps. An enabled one carries a stable
  `key`, a `level` of `required` or `preferred`, a `source_policy`, and a metadata `selector`; a
  disabled one carries only its `key` and `enabled: false` and exists to switch an inherited key
  off. `active` marks the version currently in force for its scope and skill; at most one
  version should be active, and publishing enforces that. `requirement_schema_version` pins the
  selector language the requirements are written in.

  ## Mistakes to avoid

  * Do not put statement text, examples, or secrets into `requirements`. Cards are configuration
    and are not covered by the erasure paths that clean up knowledge.
  * Do not mutate `requirements` in place to "fix" a card. Publish a new version; an in-place
    edit erases the record of what a past readiness check was judged against.
  * Do not expose the create or update actions to machine credentials. Authoring what an agent
    must know is a human decision.
  """

  use MemHouse.Resource,
    domain: MemHouse.Skills,
    table: "skill_requirement_cards"

  # Every read and write is rewritten to the tenant Account, so a card published in one Account
  # is invisible to another even when both use the same scope path and skill key.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    # Create-only by design: a new version is an insert, and no action updates `requirements`.
    # The validation below rejects the write unless the schema version matches the selector
    # language this build implements and the requirements are already in their normalized form,
    # so what readiness later evaluates is byte-for-byte what was reviewed at publish time.
    #
    # The audit change appends one hash-chained event after the row is persisted, inside the
    # same transaction. `content_fields` names the attributes whose values are hashed into a
    # single digest; the digest is stored and the values are not, so the log can prove which
    # version was published without holding the card's text.
    create :create_version do
      accept [
        :scope_id,
        :skill_key,
        :description,
        :requirement_schema_version,
        :version,
        :requirements,
        :active
      ]

      validate MemHouse.Skills.Validations.Requirements

      change {MemHouse.Governance.Changes.AuditResource,
              category: "configuration",
              action: "skill_requirement_card.published",
              resource_type: "skill_requirement_card",
              content_fields: [
                :skill_key,
                :description,
                :requirement_schema_version,
                :version,
                :requirements
              ]}
    end

    # Retiring a version flips `active` and nothing else — the requirements stay readable, so a
    # past readiness result can still be explained. `require_atomic?` is off because the audit
    # change runs after the row is persisted and needs the resulting record, which an atomic
    # in-database update cannot provide.
    update :deactivate do
      accept []
      require_atomic? false
      change set_attribute(:active, false)

      change {MemHouse.Governance.Changes.AuditResource,
              category: "configuration",
              action: "skill_requirement_card.deactivated",
              resource_type: "skill_requirement_card",
              content_fields: [:skill_key, :version, :active]}
    end
  end

  policies do
    # Account isolation first and unconditionally: no action of any kind reaches a row whose
    # Account differs from the caller's.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # A card is readable by anyone who may read the scope it is attached to, which is what makes
    # inherited requirements visible to a descendant scope's readiness check.
    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    # Authoring is restricted to Account administrators, curators, and the internal system
    # actor. The check is on the role alone, not on the credential kind, so an agent peer must
    # never be granted one of those roles: it could then rewrite the requirements it is judged
    # against.
    policy action_type([:create, :update, :destroy]) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :curator, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true

    # The stable name of the skill this card governs, as a lowercase slug. Cards inherit by
    # matching this key across the scope path.
    attribute :skill_key, :string, allow_nil?: false, public?: true

    # Free-text note for the human authoring or reviewing the card. Never used for matching.
    attribute :description, :string, public?: true

    # The version identity of the selector language the requirements are written in, currently
    # `f9-1`. Publishing rejects any other value, so every stored card speaks the language this
    # build implements. Advancing the string is a deliberate contract transition: it changes the
    # shape reviewers author and readiness reports carry, and it obliges whoever changes it to
    # migrate or re-publish existing cards and record the change in the changelog.
    attribute :requirement_schema_version, :string,
      allow_nil?: false,
      default: "f9-1",
      public?: true

    # Monotonically increasing per scope and skill. Publishing computes the next value from the
    # highest existing version, including retired ones, so numbers are never reused.
    attribute :version, :integer, allow_nil?: false, public?: true

    # The normalized requirement list, stored exactly as validated. Readiness evaluates these
    # maps verbatim; there is no normalization step at read time.
    attribute :requirements, {:array, :map}, allow_nil?: false, default: [], public?: true

    # Whether this version is the one currently in force. Publishing deactivates the previous
    # active version in the same transaction as the insert.
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Version numbers are unique per scope and skill within an Account (the tenant is implicit
    # in the identity because every query is Account-scoped). Publishing serializes on an
    # advisory lock; this constraint is the database-level backstop that keeps two concurrent
    # publishes from minting the same version number.
    identity :scope_skill_version, [:scope_id, :skill_key, :version]
  end
end
