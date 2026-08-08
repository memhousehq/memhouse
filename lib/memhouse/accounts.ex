# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Accounts do
  @moduledoc """
  Ash domain for Account tenancy and authenticated identities.

  The Account is always derived from a verified credential or trusted internal configuration,
  never request input. All identity resources remain inside that Account boundary.
  """

  use Ash.Domain

  resources do
    resource MemHouse.Accounts.Account
    resource MemHouse.Accounts.Peer
    resource MemHouse.Accounts.ExternalIdentity
    resource MemHouse.Accounts.ApiKey
  end
end

defmodule MemHouse.Accounts.Account do
  @moduledoc """
  One tenant and the isolation root for all durable data.

  Policies and database row-level security restrict access to the actor's Account. Infrastructure
  helpers provision Accounts; callers must not create request-selected tenants.
  """

  use MemHouse.Resource, domain: MemHouse.Accounts, table: "accounts"

  actions do
    read :read do
      primary? true
    end

    # Upsert-by-key so repeatedly opening a transaction for the same Account key
    # is idempotent. It deliberately does not touch `edition_slot`: an existing
    # Account keeps whatever slot it already holds.
    create :ensure do
      accept [:key, :name]
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:name, :updated_at]
    end

    # The only way an Account acquires the community slot. The slot value is set
    # by the action rather than accepted as input, so a caller cannot claim a
    # different edition. The partial unique index on `edition_slot` then makes a
    # second community Account fail at the database.
    create :provision_free do
      accept [:key, :name]
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:name, :edition_slot, :updated_at]
      change set_attribute(:edition_slot, "community-free")
    end

    update :update do
      accept [:name]
    end

    # The only way `consent_mode` changes. Deliberately its own action, not
    # folded into `:update`, and restricted below to account_admin (not
    # curator): this is a bigger privacy trade-off than anything else an
    # admin or curator can otherwise do, so it gets its own name in the audit
    # log and its own, narrower policy rather than riding along on a change
    # that also lets someone rename the Account.
    update :configure_governance do
      accept [:consent_mode]

      # Atomic updates are off because the audit append runs in Elixir after
      # the write, the same reason GateRule's :update turns it off.
      require_atomic? false

      # Mirrors MemHouse.Governance.Changes.AuditResource's own after_action
      # shape, but calls Audit.append! with result.id rather than
      # result.account_id: Account is not multitenant — it IS the tenant, so
      # it has no account_id attribute, and reusing that change verbatim
      # would raise KeyError at runtime. Reads the actor from the changeset's
      # own private context rather than the builtin after_action callback's
      # third (Ash.Resource.Change.Context) argument, whose `actor` field is
      # not populated for this DSL form in the Ash version this app pins.
      change after_action(fn changeset, result, _context ->
               actor = get_in(changeset.context, [:private, :actor])

               MemHouse.Governance.Audit.append!(actor, result.id, %{
                 actor_peer_id: Map.get(actor, :peer_id),
                 category: "configuration",
                 action: "account.consent_mode_changed",
                 resource_type: "account",
                 resource_id: result.id,
                 content_hash:
                   MemHouse.Governance.Audit.content_hash(%{consent_mode: result.consent_mode}),
                 metadata: %{}
               })

               {:ok, result}
             end)
    end
  end

  policies do
    # Provisioning happens before an Account id exists, so the only thing that
    # can be checked is that the key being created matches the key the caller
    # already pinned for this transaction.
    policy action([:ensure, :provision_free]) do
      authorize_if expr(key == ^actor(:account_key))
    end

    # Reads and updates require the row to be the actor's own Account. The
    # second clause covers internal transactions that resolved by key before an
    # id was known; it is limited to the non-grantable :system role.
    policy action_type([:read, :update]) do
      authorize_if expr(id == ^actor(:account_id))
      authorize_if expr(key == ^actor(:account_key) and ^actor(:role) == :system)
    end

    # Narrower than every other Account write, and layered on top of the
    # action_type([:read, :update]) policy above rather than replacing it:
    # both must pass, so this still requires the row to be the caller's own
    # Account *and* additionally requires a human account administrator. No
    # curator, no machine credential, no :system bypass — a mistaken or
    # malicious widening here removes a real privacy protection for every
    # personal item that Account ever proposes above peer level.
    policy action(:configure_governance) do
      authorize_if {MemHouse.Policy.HumanRoleIn, roles: [:account_admin]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    # Not public: the licensing slot is server-controlled, never client input.
    attribute :edition_slot, :string
    # "subject_required" (default) demands a real subject's verified grant
    # for every personal item aimed above peer level, exactly as before this
    # attribute existed. "auto" declares this Account has no real human
    # subject — a benchmark, eval, or imported corpus — and lets the
    # pipeline grant consent on the subject's behalf instead. It never
    # affects GateRule's own auto_keep/auto_place modes, only the separate
    # consent check in MemHouse.Governance.Engine.
    attribute :consent_mode, :string,
      allow_nil?: false,
      default: "subject_required",
      public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # Backs the upsert in :ensure and :provision_free, and guarantees one
    # Account per operator-visible key.
    identity :unique_key, [:key]
  end
end

defmodule MemHouse.Accounts.Peer do
  @moduledoc """
  A human or agent identity inside one Account.

  A Peer is durable identity, not a credential: passwords, API keys, and external proofs attach
  separately. Its stable key is unique only within the Account.
  """

  use MemHouse.Resource,
    domain: MemHouse.Accounts,
    table: "peers",
    extensions: [AshAuthentication]

  authentication do
    domain MemHouse.Accounts
    subject_name(:peer)
    # Sessions are not individually tracked, and combined with the disabled
    # token store below this means a signed token cannot be revoked before it
    # expires. The 12-hour lifetime is therefore the real bound on a leaked
    # token, which is why it is short.
    session_identifier(:unsafe)

    tokens do
      enabled?(true)
      # No token resource: tokens are stateless and verified by signature, so
      # authentication never needs a database round trip for the token itself.
      token_resource(false)
      signing_secret(MemHouse.Identity.SigningSecret)
      # 12 hours: long enough for a working day, short enough that an
      # unrevocable leaked token expires on its own.
      token_lifetime({12, :hours})
    end

    strategies do
      password :password do
        identity_field(:email)
        hashed_password_field(:hashed_password)
        registration_enabled?(true)
        # Sign-in tokens (short-lived tokens handed out mid-flow) are off:
        # a successful sign-in returns the session token directly.
        sign_in_tokens_enabled?(false)
      end

      api_key :api_key do
        # Only unexpired keys are reachable, because the relationship this
        # points at filters expired rows out. Expiry is therefore enforced at
        # lookup time, not by a sweeper.
        api_key_relationship(:valid_api_keys)
        api_key_hash_attribute(:api_key_hash)
      end
    end
  end

  # Every query and write is filtered to the acting Account. The same rule is
  # duplicated in the database as a row-level-security policy, so a bug in
  # application code cannot leak Peers across the Account wall.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    read :read do
      primary? true
    end

    # Idempotent upsert by Peer key. Used when a caller references a Peer that
    # should exist, so replaying the same request does not create duplicates.
    create :ensure do
      accept [:key, :name, :kind, :default_scope_id]
      upsert? true
      upsert_identity :unique_key
      upsert_fields [:name, :kind, :default_scope_id, :updated_at]
    end

    update :update do
      accept [:name, :kind, :default_scope_id]
    end

    # Human registration. The password arrives as a sensitive argument, is
    # hashed by the change below, and is never written as an attribute. The
    # confirmation validation runs on the same changeset so a mistyped password
    # cannot create an account nobody can sign into.
    create :register_with_password do
      accept [:key, :name, :kind, :default_scope_id]

      argument :email, :ci_string, allow_nil?: false

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

      change set_attribute(:email, arg(:email))
      change AshAuthentication.Strategy.Password.HashPasswordChange
      change AshAuthentication.GenerateTokenChange
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      # The freshly signed session token is returned as action metadata rather
      # than stored, since no token resource exists to store it in.
      metadata :token, :string, allow_nil?: false
    end

    # Verifies email and password and returns the matching Peer plus a session
    # token. Modelled as a read so a failed sign-in writes nothing.
    read :sign_in_with_password do
      get? true
      argument :email, :ci_string, allow_nil?: false
      argument :password, :string, allow_nil?: false, sensitive?: true
      prepare AshAuthentication.Strategy.Password.SignInPreparation
      metadata :token, :string, allow_nil?: false
    end

    # Hashes the presented key and looks for a matching unexpired row. No token
    # is issued: the key itself is the credential on every request.
    read :sign_in_with_api_key do
      argument :api_key, :string, allow_nil?: false, sensitive?: true
      prepare AshAuthentication.Strategy.ApiKey.SignInPreparation
    end

    # Reachable only by the internal erasure pipeline (see the policy below).
    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    # Sign-in has to read the Peer before an actor exists, so authentication's
    # own internal calls are allowed through. This bypass is scoped to calls
    # AshAuthentication makes itself; ordinary callers cannot trigger it.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # Applies to every action: the row must belong to the actor's Account.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Ash requires all applicable policies to pass, so erasure needs both the
    # Account match above and the internal pipeline flag. No externally
    # authenticated actor ever carries that flag.
    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    # Not public: the tenant is set from the authenticated identity, never
    # accepted as action input.
    attribute :account_id, :uuid, allow_nil?: false
    attribute :default_scope_id, :uuid, public?: true
    attribute :key, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :kind, :string, allow_nil?: false, default: "human", public?: true
    # Case-insensitive so sign-in is not defeated by capitalisation.
    attribute :email, :ci_string, public?: true
    # Only ever the hash. Marked sensitive so it is redacted from inspects,
    # logs, and error payloads.
    attribute :hashed_password, :string, sensitive?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_key, [:key]
    identity :unique_email, [:email]
  end

  relationships do
    # Expiry is applied here rather than at sign-in time: the API-key strategy
    # searches through this relationship, so an expired key simply has no
    # matching row and fails exactly like an unknown key.
    has_many :valid_api_keys, MemHouse.Accounts.ApiKey do
      destination_attribute :peer_id
      filter expr(is_nil(expires_at) or expires_at > now())
    end
  end
end

defmodule MemHouse.Accounts.ExternalIdentity do
  @moduledoc """
  Links one Peer to a verified external credential.

  The row records identity kind, provider reference, and assurance—not a reusable secret.
  Credential resolution must still derive the same Account and Peer.
  """

  use MemHouse.Resource, domain: MemHouse.Accounts, table: "external_identities"

  # Identities never cross the Account wall, in the application and again in the
  # database via row-level security.
  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :peer_id,
        :provider,
        :subject,
        :email,
        :assurance,
        :linked_at,
        :active,
        :metadata
      ]
    end

    # `provider`, `subject`, and `peer_id` are deliberately not updatable: an
    # identity is a fixed statement about which credential belongs to which
    # Peer. Rebinding it would silently transfer a login to another Peer.
    update :update do
      accept [:email, :assurance, :active, :metadata]
    end

    destroy :erase do
      require_atomic? false
    end
  end

  policies do
    # Applies to every action, reads included.
    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Linking, revoking, or removing a credential is Account administration.
    # Ordinary members and curators cannot grant themselves a new way in.
    policy action_type([:create, :update, :destroy]) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :system]}
    end

    # Erasure additionally requires the internal pipeline flag, on top of the
    # Account match and the admin/system role above.
    policy action(:erase) do
      authorize_if actor_attribute_equals(:pipeline?, true)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    # Which credential family proved the identity, e.g. "password" or "apikey".
    attribute :provider, :string, allow_nil?: false, public?: true
    # The provider-local handle: a lowercased email, or an API key's opaque id.
    # Never a secret or a hash.
    attribute :subject, :string, allow_nil?: false, public?: true
    attribute :email, :string, public?: true
    # "low" | "medium" | "high". Anything unrecognised is treated as low when
    # the value is turned into an actor.
    attribute :assurance, :string, allow_nil?: false, default: "medium", public?: true
    attribute :linked_at, :utc_datetime_usec, allow_nil?: false, public?: true
    # Revocation switch: authentication only accepts active identities.
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    # Not public: provider bookkeeping, never client-supplied.
    attribute :metadata, :map, allow_nil?: false, default: %{}
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # One Peer per provider subject: the same email or key id cannot be linked
    # to two Peers within an Account.
    identity :provider_subject, [:provider, :subject]
  end
end

defmodule MemHouse.Accounts.ApiKey do
  @moduledoc """
  A machine credential bound to one Peer and Account.

  Only the hash is stored; plaintext exists only when the key is issued. Authentication derives
  the Account from the opaque key id before verifying the secret inside that tenant.
  """

  use MemHouse.Resource, domain: MemHouse.Accounts, table: "api_keys"

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  actions do
    defaults [:destroy]

    # Global reads are permitted because the API-key lookup runs before an Ash
    # tenant can be established for the request. This is not a hole in the
    # Account wall: the transaction has already pinned the resolved Account into
    # the transaction-local database setting, and this table has forced
    # row-level security keyed on that setting, so PostgreSQL still refuses rows
    # from any other Account.
    read :read do
      primary? true
      multitenancy :allow_global
    end

    # Generates the key material, returns the plaintext once as action metadata,
    # and writes only its hash to `api_key_hash`. The `memhouse` prefix is what
    # bearer-credential dispatch matches on, so changing it changes how every
    # existing client's credential is recognised.
    create :create do
      primary? true
      accept [:account_id, :peer_id, :scope_id, :expires_at]

      change {AshAuthentication.Strategy.ApiKey.GenerateApiKey,
              prefix: :memhouse, hash: :api_key_hash}
    end
  end

  policies do
    # Sign-in must read candidate keys before any actor exists; only
    # AshAuthentication's own internal calls take this path.
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      authorize_if expr(account_id == ^actor(:account_id))
    end

    # Minting and revoking machine credentials is Account administration. A
    # member or curator cannot issue itself a key.
    policy action_type([:create, :destroy]) do
      authorize_if {MemHouse.Policy.RoleIn, roles: [:account_admin, :system]}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :account_id, :uuid, allow_nil?: false
    attribute :peer_id, :uuid, allow_nil?: false, public?: true
    # Optional restriction to one scope subtree; narrows access, never widens.
    attribute :scope_id, :uuid, public?: true
    # The only stored form of the credential. Sensitive, so it is redacted from
    # inspects, logs, and error payloads.
    attribute :api_key_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :expires_at, :utc_datetime_usec, public?: true
    # No update timestamp: a key is never edited, only created and destroyed.
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :peer, MemHouse.Accounts.Peer do
      source_attribute :peer_id
      destination_attribute :id
      allow_nil? false
    end

    belongs_to :account, MemHouse.Accounts.Account do
      source_attribute :account_id
      destination_attribute :id
      allow_nil? false
    end
  end

  identities do
    # Because the resource is multitenant on `account_id`, this becomes a
    # unique index over the Account plus the hash: one row per distinct key.
    identity :unique_api_key, [:api_key_hash]
  end
end
