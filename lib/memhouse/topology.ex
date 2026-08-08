# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Topology do
  @moduledoc """
  Ash domain for scoped containment, lateral relations, and role grants.

  Context inherits downward with nearest-scope overrides. Role grants inherit downward
  only when configured, and any applicable deny removes access. A scope relation may
  expand retrieval only when both endpoints are already authorized; it never grants access.
  """

  use Ash.Domain

  resources do
    resource MemHouse.Topology.Scope
    resource MemHouse.Topology.ScopeRelation
    resource MemHouse.Topology.RoleGrant
  end
end

defmodule MemHouse.Topology.Scope do
  @moduledoc """
  One node in an Account's containment tree.

  Scopes are created idempotently as paths are encountered. A path and parent are
  immutable because they define containment for every attached row; create a new scope
  instead of trying to move one.
  """

  use MemHouse.Resource, domain: MemHouse.Topology, table: "scopes"

  postgres do
    migration_types diskann_label: :smallint
  end

  # One Account per row, enforced again in the database by row-level security.
  # A path is unique within an Account, never across Accounts.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    # Idempotent creation keyed on the path, used while walking a path segment
    # by segment during ingest. A repeat only refreshes the label and state; the
    # parent link and the path itself stay as first written, because containment
    # is already derived from them.
    create :ensure do
      accept [:parent_id, :key, :name, :path, :state]
      upsert? true
      upsert_identity :unique_path
      upsert_fields [:name, :state, :updated_at]
    end

    # Relabelling and lifecycle only. `path` and `parent_id` are absent on
    # purpose: they define containment for every row that references this scope.
    update :update do
      accept [:name, :state]
    end

    # DiskANN labels are internal index metadata. Only the retrieval rebuild
    # path can allocate or release them; no scope API can observe or choose one.
    update :assign_diskann_label do
      accept [:diskann_label]
      require_atomic? false
    end
  end

  policies do
    # Account isolation applies to every action, including internal ones.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # A caller sees only the scopes its role grants resolved to. The scope's own
    # primary key is the column being matched here, since this *is* the scope.
    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :id}
    end

    policy action(:assign_diskann_label) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false

    # The enclosing scope; nil at the root. Convenient for walking upward, but
    # containment questions are answered from `path`.
    attribute :parent_id, :uuid, public?: true

    # Final path segment.
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true

    # Full address from the root. Inheritance, nearest-wins overrides, and
    # propagating role grants are all computed from this string.
    attribute :path, :string, allow_nil?: false, public?: true
    attribute :state, :string, allow_nil?: false, default: "active", public?: true
    attribute :diskann_label, :integer, public?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Backs the upsert and guarantees one row per path. Tenant-scoped, so the
    # database index is on (account_id, path) and two Accounts may both have
    # a `/team`.
    identity :unique_path, [:path]
  end
end

defmodule MemHouse.Topology.ScopeRelation do
  @moduledoc """
  A lateral link between scopes outside the containment line.

  Both endpoints must already be authorized. The link can expand retrieval but grants
  no access, and its endpoints are immutable so changes leave an auditable old pair.
  """

  use MemHouse.Resource, domain: MemHouse.Topology, table: "scope_relations"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [:source_scope_id, :target_scope_id, :kind, :metadata]
    end

    # The endpoints cannot be edited: repointing a link would change which
    # scopes retrieval may bridge without leaving any trace of the old pair.
    update :update do
      accept [:kind, :metadata]
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Both endpoints must be authorized. Seeing one side of a link never
    # entitles a caller to learn about the other.
    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeRelationAccess,
                    source_attribute: :source_scope_id, target_attribute: :target_scope_id}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :source_scope_id, :uuid, allow_nil?: false, public?: true
    attribute :target_scope_id, :uuid, allow_nil?: false, public?: true

    # What kind of link this is. Part of the uniqueness key, so the same pair of
    # scopes may carry several differently-kinded links.
    attribute :kind, :string, allow_nil?: false, default: "related", public?: true

    # Free-form bookkeeping. Not public: it is never accepted from, or returned
    # to, an external caller.
    attribute :metadata, :map, allow_nil?: false, default: %{}
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # One link per ordered pair and kind, so re-recording the same relation
    # fails rather than accumulating duplicates that would double-count during
    # retrieval expansion.
    identity :unique_relation, [:source_scope_id, :target_scope_id, :kind]
  end
end

defmodule MemHouse.Topology.RoleGrant do
  @moduledoc """
  One peer's allow or deny role grant at one scope.

  Propagating grants inherit downward, never upward. Any applicable deny removes the
  scope regardless of stronger allows. Grants are resolved at authentication time, so
  callers that need an immediate change must resolve a fresh actor.
  """

  use MemHouse.Resource, domain: MemHouse.Topology, table: "role_grants"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :scope_id,
        :peer_id,
        :role,
        :effect,
        :propagate,
        :granted_by_peer_id,
        :granted_at
      ]
    end

    # The subject of a grant cannot be edited. Changing `scope_id` or `peer_id`
    # would move an existing grant to a different person or place while keeping
    # its original "granted by" evidence, which would make the audit trail lie.
    update :update do
      accept [:role, :effect, :propagate]
    end

    # The only destroy, and it exists for erasing a peer: removing someone means
    # removing the grants that named them. There is no administrator-facing
    # delete — revoking authority is an update that flips the grant to a deny,
    # which keeps the decision visible. Non-atomic so it runs record by record
    # over the rows the erasure walk selected.
    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Grants are visible where the caller can already see the scope; this does
    # not restrict the listing to the caller's own grants.
    policy action_type(:read) do
      authorize_if {MemHouse.Policy.ScopeAccess, attribute: :scope_id}
    end

    # Only an Account administrator *at that scope* may change authority there,
    # so administering one subtree never becomes authority to administer
    # another. Internal `:system` actors pass this check by definition.
    policy action_type([:create, :update, :destroy]) do
      authorize_if {MemHouse.Policy.ScopeRole, attribute: :scope_id, roles: [:account_admin]}
    end

    # Every applicable policy must pass, so this narrows destroys further rather
    # than offering an alternative route: `:erase` additionally demands the
    # internal pipeline flag. An Account administrator cannot call it, and the
    # erasure actor satisfies the rule above by carrying the `:system` role.
    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :scope_id, :uuid, allow_nil?: false, public?: true
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    attribute :role, :string, allow_nil?: false, public?: true

    # "allow" or "deny". A deny that reaches a scope removes it outright.
    attribute :effect, :string, allow_nil?: false, default: "allow", public?: true

    # Whether this grant reaches the scopes contained in `scope_id`. Defaults to
    # true, so a grant written high in the tree covers the subtree unless the
    # grantor says otherwise.
    attribute :propagate, :boolean, allow_nil?: false, default: true, public?: true

    # Who granted it and when: the durable evidence for an authority decision.
    attribute :granted_by_peer_id, :uuid, public?: true
    attribute :granted_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # `effect` is part of the key on purpose: the same peer may hold both an
    # allow and a deny for one role at one scope, and the deny is what takes
    # effect.
    identity :unique_grant, [:scope_id, :peer_id, :role, :effect]
  end
end
