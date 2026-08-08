# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Identity.SigningSecret do
  @moduledoc """
  Reads the session-token signing secret from runtime configuration.

  Missing configuration fails closed. Rotating the secret invalidates all stateless tokens.
  """

  use AshAuthentication.Secret

  @doc """
  Returns the configured signing secret.

  The four arguments are the strategy name, resource, options, and context that
  the authentication framework passes to every secret provider; none of them
  affect the answer here, because one secret covers the whole deployment.

  Returns `{:ok, secret}` when a `:signing_secret` is configured, and `:error`
  when it is absent — which makes token operations fail rather than fall back to
  an insecure default. Raises if the identity configuration block itself is
  missing, since that is a deployment misconfiguration rather than a runtime
  condition to tolerate.
  """
  @impl true
  def secret_for(_name, _resource, _opts, _context) do
    :memhouse
    |> Application.fetch_env!(:identity)
    |> Keyword.fetch(:signing_secret)
  end
end

defmodule MemHouse.Identity.CredentialLocator do
  @moduledoc """
  Finds an API key's Account before normal tenant isolation can begin.

  This reviewed bootstrap exception passes only the opaque credential id to a read-only
  security-definer function. It returns only an Account id; secret verification still happens
  inside the resulting Account transaction. All failures remain indistinguishable.
  """

  alias MemHouse.Repo

  @doc """
  Maps a presented API key to the id of the Account that minted it.

  `api_key` is the full plaintext credential as sent by the client. It is parsed
  locally, not looked up by value — only the embedded id reaches the database,
  and the secret portion of the key never leaves this module.

  Returns `{:ok, account_id}` as a string, or `:error`. Every failure mode
  collapses to the same `:error`: a non-binary argument, a malformed key, a
  checksum mismatch, an id that matches no row, or a database exception. That
  uniformity is intentional — a distinguishable failure would let an attacker
  learn whether a key id exists. Never make this function more informative.
  """
  def account_id_for_api_key(api_key) when is_binary(api_key) do
    with {:ok, api_key_id} <- api_key_id(api_key),
         # The function is SECURITY DEFINER with row security switched off and
         # returns only account_id, so this is the one lookup that can run
         # before an Account is pinned. An unknown id yields NULL, which the
         # is_binary/1 check below turns into the same :error as a bad key.
         %{rows: [[account_id]]} <-
           Ecto.Adapters.SQL.query!(
             Repo,
             "SELECT memhouse_resolve_api_key_account($1::uuid)::text",
             [api_key_id]
           ),
         true <- is_binary(account_id) do
      {:ok, account_id}
    else
      _ -> :error
    end
  rescue
    # A malformed id that PostgreSQL refuses to cast raises rather than
    # returning a row. Swallowing it keeps every rejection path identical from
    # the caller's point of view, which is the whole point of this module.
    _error -> :error
  end

  def account_id_for_api_key(_api_key), do: :error

  # Recovers the credential row id from the key itself, without touching the
  # database. A generated key is "<prefix>_<body>_<checksum>", where the body
  # base62-decodes to 32 secret bytes followed by the 16-byte row id. The
  # checksum is verified before any database work, so a mangled or invented key
  # is rejected here rather than costing a round trip. The 32 secret
  # bytes are deliberately discarded: they are the part that gets hashed and
  # compared later, and they must not be carried any further than this.
  defp api_key_id(api_key) do
    with [_prefix, middle, crc32] <- String.split(api_key, "_", parts: 3),
         {:ok, <<random_bytes::binary-size(32), id::binary-size(16)>>} <-
           AshAuthentication.Base.bindecode62(middle),
         {:ok, expected_crc32} <- AshAuthentication.Base.decode62(crc32),
         true <- expected_crc32 == :erlang.crc32(random_bytes <> id) do
      {:ok, id}
    else
      _ -> :error
    end
  end
end

defmodule MemHouse.Identity.RoleResolver do
  @moduledoc """
  Resolves a Peer's grants into authorized scopes and effective roles.

  Propagation is downward, any applicable deny removes the scope, and API-key restrictions can
  only narrow access. Cross-links never grant access. Results are snapshots, so callers must
  re-resolve after grant changes.
  """

  alias MemHouse.Accounts.Peer
  alias MemHouse.Actor
  alias MemHouse.Topology.RoleGrant
  alias MemHouse.Topology.Scope

  require Ash.Query

  # Comparison ranks for picking the strongest allow. The numbers themselves
  # carry no meaning beyond their order: reader is weakest, account-admin
  # strongest. `:system` is absent on purpose — it is not grantable, so a grant
  # row can never resolve to it, and looking it up here would raise.
  @role_rank %{reader: 1, member: 2, curator: 3, account_admin: 4}

  @doc """
  Builds the authorization context for an authenticated Peer.

  `account` is the resolved Account record and `peer` the authenticated Peer.
  `identity` is a keyword list describing the credential that was accepted:

  - `:identity_id` — the linked credential record's id, carried for auditing.
  - `:kind` — `:password` or `:api_key`.
  - `:assurance` — how strongly that credential is trusted.
  - `:api_key` — optional; anything exposing a `:scope_id`. When that scope id
    is present the resulting context is confined to that scope's subtree.

  Returns a `MemHouse.Actor`. A Peer with no applicable grants still gets a
  valid context, but with an empty scope list and the floor role of `:reader`,
  so it authenticates successfully and can reach nothing.

  Raises if the Account's scopes or the Peer's grants cannot be read.
  """
  def resolve(account, %Peer{} = peer, identity) do
    # Reading every scope and grant needs Account-wide visibility, which the
    # caller's own context by definition does not have yet.
    system = Actor.for_account(account, role: :system)

    scopes =
      Scope
      |> Ash.Query.sort(path: :asc)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: system)

    grants =
      RoleGrant
      |> Ash.Query.filter(peer_id == ^peer.id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: system)

    scopes_by_id = Map.new(scopes, &{&1.id, &1})
    key_scope = restricted_scope(identity[:api_key], scopes_by_id)

    # One pass per scope in the Account. Grants are matched by path rather than
    # by walking parent links, so a grant whose own scope has since disappeared
    # simply stops applying instead of raising.
    scope_roles =
      scopes
      |> Enum.reduce(%{}, fn scope, roles ->
        applicable =
          Enum.filter(grants, fn grant ->
            grant_scope = Map.get(scopes_by_id, grant.scope_id)
            grant_scope && applies?(grant, grant_scope.path, scope.path)
          end)

        # Deny wins outright. It is checked before any allow is even
        # considered, so no combination of allows can override it and a
        # stronger role does not beat a weaker deny.
        role =
          if Enum.any?(applicable, &(&1.effect == "deny")) do
            nil
          else
            applicable
            |> Enum.filter(&(&1.effect == "allow"))
            |> Enum.map(&role_atom/1)
            # An unrecognised role string is dropped rather than guessed at, so
            # a typo in a grant grants nothing instead of something arbitrary.
            |> Enum.reject(&is_nil/1)
            |> Enum.max_by(&Map.fetch!(@role_rank, &1), fn -> nil end)
          end

        # A scope only enters the map if it survived the deny check and also
        # falls inside the presented key's restriction. Absence from this map is
        # the denial: there is no separate negative entry to consult.
        if role && inside_key_scope?(scope, key_scope) do
          Map.put(roles, scope.id, role)
        else
          roles
        end
      end)

    # Coarse checks use a single role, so take the strongest held anywhere.
    # With no authorized scope at all this floors at :reader, which is harmless
    # precisely because the scope list is empty.
    role =
      scope_roles
      |> Map.values()
      |> Enum.max_by(&Map.fetch!(@role_rank, &1), fn -> :reader end)

    %Actor{
      account_id: account.id,
      account_key: account.key,
      peer_id: peer.id,
      identity_id: identity[:identity_id],
      identity_kind: identity[:kind],
      assurance: identity[:assurance],
      credential_scope_id: key_scope && key_scope.id,
      role: role,
      scope_ids: Map.keys(scope_roles),
      scope_roles: scope_roles,
      pipeline?: false
    }
  end

  # Does a grant reach a target scope? Either it sits on that exact scope, or it
  # propagates from a containing ancestor. Containment is tested on the path
  # string with a trailing separator appended, so "/team" does not match
  # "/teamwork". The root is special-cased because appending a separator to "/"
  # would produce "//" and match nothing.
  defp applies?(grant, grant_path, scope_path) do
    grant_path == scope_path ||
      (grant.propagate &&
         (grant_path == "/" || String.starts_with?(scope_path, grant_path <> "/")))
  end

  # The scope an API key is confined to, or nil for an unrestricted credential
  # or a password session. A restriction naming a scope that no longer exists
  # also yields nil here, which leaves the Peer's own grants in force.
  defp restricted_scope(nil, _scopes_by_id), do: nil
  defp restricted_scope(%{scope_id: nil}, _scopes_by_id), do: nil
  defp restricted_scope(%{scope_id: scope_id}, scopes_by_id), do: Map.get(scopes_by_id, scope_id)

  # Unrestricted credentials admit every scope; a restricted one admits only its
  # own scope and descendants. Same trailing-separator rule as above.
  defp inside_key_scope?(_scope, nil), do: true

  defp inside_key_scope?(scope, key_scope) do
    key_scope.path == "/" || scope.path == key_scope.path ||
      String.starts_with?(scope.path, key_scope.path <> "/")
  end

  # Grants written by this codebase use hyphenated role names; the underscored
  # spelling maps to the same role. Anything else returns nil and is discarded
  # by the caller rather than treated as a role.
  defp role_atom(%{role: "account-admin"}), do: :account_admin
  defp role_atom(%{role: "account_admin"}), do: :account_admin
  defp role_atom(%{role: "curator"}), do: :curator
  defp role_atom(%{role: "member"}), do: :member
  defp role_atom(%{role: "reader"}), do: :reader
  defp role_atom(_grant), do: nil
end

defmodule MemHouse.Identity do
  @moduledoc """
  Authenticates credentials and returns identity-derived authorization contexts.

  Passwords and API keys converge on the same Account and role resolution. The module stores no
  plaintext credentials, returns opaque failures, and never accepts Account selection from a
  request.
  """

  alias AshAuthentication.{Info, Strategy}
  alias AshAuthentication.Jwt.Config, as: JwtConfig
  alias MemHouse.Accounts.ApiKey
  alias MemHouse.Accounts.ExternalIdentity
  alias MemHouse.Accounts.Peer
  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Identity.CredentialLocator
  alias MemHouse.Identity.RoleResolver
  alias MemHouse.Topology.RoleGrant
  alias MemHouse.Topology.Scope

  require Ash.Query

  @doc """
  Creates the first human administrator and everything that Account needs to work.

  This is the cold-start path an operator runs once. In a single transaction it
  provisions the community Account, creates the containment root scope, registers
  the Peer with a hashed password, records the password credential at medium
  assurance, and grants that Peer a propagating administrator role at the root —
  which is what makes every later scope reachable.

  `attrs` accepts atom or string keys and must contain `"name"`, `"email"`, and
  `"password"`. `"key"` is optional; without it a Peer key is derived from the
  email by lowercasing it and replacing runs of non-alphanumeric characters with
  hyphens.

  Returns a map with `:account`, `:peer`, `:actor`, and `:token`. The token is
  a ready-to-use session token, returned here because nothing stores it.

  Raises on any failure, and the whole transaction rolls back — a half-created
  administrator with no root grant would be worse than no administrator. Running
  it again for the same email raises, because the Peer key and email are unique
  within the Account; the Account row and the root scope are upserts, so those
  parts are idempotent.
  """
  def bootstrap_human(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    # One transaction: Account, root scope, Peer, credential link, and root
    # grant either all exist afterwards or none of them do.
    DataLayer.with_free_account(fn account, system ->
      root_scope = ensure_root_scope!(account.id, system)

      peer =
        Peer
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:register_with_password, %{
          key: Map.get(attrs, "key", normalized_key(Map.fetch!(attrs, "email"))),
          name: Map.fetch!(attrs, "name"),
          kind: "human",
          default_scope_id: root_scope.id,
          email: Map.fetch!(attrs, "email"),
          password: Map.fetch!(attrs, "password"),
          password_confirmation: Map.fetch!(attrs, "password")
        })
        |> Ash.create!(actor: system)

      identity =
        link_identity!(
          account.id,
          system,
          peer.id,
          "password",
          # Subject is the lowercased email so lookups match regardless of how
          # the address was typed at sign-in.
          String.downcase(Map.fetch!(attrs, "email")),
          Map.fetch!(attrs, "email"),
          # Medium: a self-chosen password with no second factor and no verified
          # email behind it. High is reserved for issued machine credentials.
          "medium"
        )

      # Propagating administrator at the containment root. This is the seed of
      # all later authority: every scope created under the root inherits it, so
      # without this grant the new administrator could reach nothing. The
      # grantor is recorded as the Peer itself, since nobody else exists yet.
      grant_role!(
        account.id,
        system,
        root_scope.id,
        peer.id,
        "account-admin",
        "allow",
        true,
        peer.id
      )

      actor =
        RoleResolver.resolve(account, peer,
          identity_id: identity.id,
          kind: :password,
          assurance: :medium
        )

      %{account: account, peer: peer, actor: actor, token: peer.__metadata__[:token]}
    end)
  end

  @doc """
  Creates an agent Peer, grants it a role, and mints its API key.

  `admin` must be an administrator context; there is no other clause, so any
  other actor raises `FunctionClauseError` rather than being politely refused.
  Holding the administrator role somewhere is not enough — the caller must hold
  it at the specific scope being provisioned into, which is re-checked below.

  `attrs` accepts atom or string keys:

  - `"key"` (required) — the agent Peer's stable handle.
  - `"name"` — defaults to the key.
  - `"scope_path"` — where the agent lives, defaulting to the root `"/"`.
  - `"role"` — defaults to `"member"`.
  - `"propagate"` — whether the grant reaches descendant scopes, default true.
  - `"restrict_to_scope"` — when true the key is bound to that scope's subtree,
    so even if the Peer is later granted more, this key still cannot use it.
  - `"expires_at"` — optional expiry; without it the key never expires.

  Returns `%{peer: peer, api_key: plaintext}`. **The plaintext key is returned
  exactly once and is not recoverable** — only its hash is stored. A caller that
  drops it must destroy the key and issue a new one.

  Raises `Ash.Error.Forbidden` when the caller is not an administrator at the
  target scope, and raises when the scope path names nothing. All the writes
  share one transaction, so a failure leaves no orphaned Peer or key.
  """
  def provision_agent(%Actor{role: :account_admin} = admin, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    DataLayer.with_actor(admin, fn account, _actor ->
      system = Actor.for_account(account, role: :system)
      scope = scope_by_path!(account.id, system, Map.get(attrs, "scope_path", "/"))
      # The struct match above only proves the caller is an administrator
      # somewhere. Authority is per scope, so re-check it at this exact scope
      # before creating a credential that will live inside it.
      require_scope_role!(admin, scope.id, [:account_admin])

      peer =
        Peer
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:ensure, %{
          key: Map.fetch!(attrs, "key"),
          name: Map.get(attrs, "name", Map.fetch!(attrs, "key")),
          kind: "agent",
          default_scope_id: scope.id
        })
        |> Ash.create!(actor: system)

      grant_role!(
        account.id,
        system,
        scope.id,
        peer.id,
        Map.get(attrs, "role", "member"),
        "allow",
        Map.get(attrs, "propagate", true),
        admin.peer_id
      )

      api_key =
        ApiKey
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create, %{
          account_id: account.id,
          peer_id: peer.id,
          scope_id: if(Map.get(attrs, "restrict_to_scope", false), do: scope.id),
          expires_at: Map.get(attrs, "expires_at")
        })
        |> Ash.create!(actor: system)

      link_identity!(
        account.id,
        system,
        peer.id,
        "apikey",
        # Subject is the key row's id, never the key or its hash. The id is not
        # secret; it is the same value the key itself carries in the clear.
        api_key.id,
        nil,
        # High: the credential was issued by an administrator rather than chosen
        # by its holder, so its provenance is known.
        "high"
      )

      # Only moment the plaintext key is ever available. It is not stored, so
      # this return value is the caller's only chance to capture it.
      %{peer: peer, api_key: api_key.__metadata__[:plaintext_api_key]}
    end)
  end

  @doc """
  Grants or denies a role to a Peer at one scope.

  `admin` must be an administrator context; any other actor raises
  `FunctionClauseError`, and an administrator who lacks that role at the target
  scope specifically raises `Ash.Error.Forbidden`.

  `attrs` accepts atom or string keys and requires `"scope_path"`, `"peer_id"`,
  and `"role"`. Optional keys:

  - `"effect"` — `"allow"` (default) or `"deny"`. A deny is absolute: it removes
    the scope from the target Peer entirely, and no allow anywhere can restore
    it. That is the point of a deny, and it applies to administrators too.
  - `"propagate"` — default true, meaning the grant also covers every scope
    contained beneath this one. Set false to affect only this exact scope.

  Returns the created grant record. The grantor and grant time are recorded from
  the calling context, not from input, so the trail cannot be forged.

  Takes effect for a Peer the next time its context is resolved; sessions
  already in flight keep the permissions they were issued with.
  """
  def grant_role(%Actor{role: :account_admin} = admin, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    DataLayer.with_actor(admin, fn account, _actor ->
      system = Actor.for_account(account, role: :system)
      scope = scope_by_path!(account.id, system, Map.fetch!(attrs, "scope_path"))
      # Authority is per scope: being an administrator elsewhere does not permit
      # editing grants here.
      require_scope_role!(admin, scope.id, [:account_admin])

      grant_role!(
        account.id,
        system,
        scope.id,
        Map.fetch!(attrs, "peer_id"),
        Map.fetch!(attrs, "role"),
        Map.get(attrs, "effect", "allow"),
        Map.get(attrs, "propagate", true),
        admin.peer_id
      )
    end)
  end

  @doc """
  Authenticates whatever credential arrived in the request's bearer slot.

  The credential kind is decided by its shape. Generated API keys begin with
  `memhouse_`. The legacy `cartulary_` prefix remains accepted so existing beta
  credentials keep working. These prefixes route to the API-key path. Any other
  binary value is treated as a session token.

  Returns `{:ok, actor}` with a fully resolved authorization context, or
  `{:error, :unauthorized}`. The error is identical for an unparseable
  credential, a wrong one, an expired one, and a valid one belonging to an
  Account without the community slot, so nothing about the system's contents can
  be inferred from a rejection. Does not raise.
  """
  def authenticate_bearer("memhouse_" <> _rest = api_key), do: authenticate_api_key(api_key)
  def authenticate_bearer("cartulary_" <> _rest = api_key), do: authenticate_api_key(api_key)
  def authenticate_bearer(token) when is_binary(token), do: authenticate_token(token)
  def authenticate_bearer(_token), do: {:error, :unauthorized}

  @doc """
  Verifies a human's email and password and starts a session.

  Runs against the one community Account; a Peer that is not in it cannot sign
  in even with correct credentials.

  Returns `{:ok, %{peer: peer, actor: actor, token: token}}`, where `token` is a
  signed session token the caller presents on subsequent requests, or
  `{:error, :unauthorized}`. Wrong password, unknown email, a non-binary
  argument, and an unprovisioned deployment all produce that same error, and any
  exception raised underneath is rescued into it. Does not raise.

  The password is never logged, stored, or echoed back; only its hash is ever
  compared.
  """
  def sign_in_password(email, password) when is_binary(email) and is_binary(password) do
    result =
      DataLayer.with_existing_free_account(fn account, _system ->
        strategy = Info.strategy!(Peer, :password)

        case Strategy.action(
               strategy,
               :sign_in,
               %{email: email, password: password},
               tenant: account.id
             ) do
          {:ok, peer} ->
            identity =
              identity_link!(account.id, peer.id, "password", String.downcase(email))

            {:ok,
             %{
               peer: peer,
               actor:
                 RoleResolver.resolve(account, peer,
                   identity_id: identity.id,
                   kind: :password,
                   assurance: assurance_atom(identity.assurance)
                 ),
               token: peer.__metadata__[:token]
             }}

          {:error, _error} ->
            {:error, :unauthorized}
        end
      end)

    result
  rescue
    # A missing Account, a missing credential link, or any other raise here must
    # look exactly like a wrong password. Never let a specific reason escape.
    _error -> {:error, :unauthorized}
  end

  def sign_in_password(_email, _password), do: {:error, :unauthorized}

  @doc """
  Re-derives an authorization context from the current state of the database.

  `actor` must already carry a `peer_id`; internal system contexts have none and
  raise `FunctionClauseError`. The credential's identity, kind, assurance, and
  any scope restriction are carried across unchanged — this refreshes what the
  Peer is *allowed to do*, not who it is.

  Use it when a grant may have changed since the context was issued. Because
  role resolution is a snapshot, a long-lived context otherwise keeps stale
  permissions; refreshing is how a newly added deny actually starts biting.

  Returns a `MemHouse.Actor`. Raises if the Peer no longer exists.
  """
  def refresh_actor(%Actor{peer_id: peer_id} = actor) when is_binary(peer_id) do
    DataLayer.with_actor(actor, fn account, _actor ->
      system = Actor.for_account(account, role: :system)

      peer =
        Peer
        |> Ash.Query.filter(id == ^peer_id)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: system)

      # The key restriction has to be carried forward explicitly. Dropping it
      # here would silently promote a scope-restricted key to full Peer access
      # on the first refresh.
      RoleResolver.resolve(account, peer,
        identity_id: actor.identity_id,
        kind: actor.identity_kind,
        assurance: actor.assurance,
        api_key: %{scope_id: actor.credential_scope_id}
      )
    end)
  end

  # Two steps, in this order for a reason. First find which Account the key
  # belongs to, using only the id embedded in the key. Then open a transaction
  # pinned to that Account and verify the key's hash inside it, where ordinary
  # Account isolation and row-level security are in force. Step one proves
  # nothing; all the authentication happens in step two.
  defp authenticate_api_key(api_key) do
    case CredentialLocator.account_id_for_api_key(api_key) do
      {:ok, account_id} ->
        DataLayer.with_account_id(account_id, fn account, _system ->
          authenticate_api_key_in_account(account, api_key)
        end)

      _ ->
        {:error, :unauthorized}
    end
  rescue
    _error -> {:error, :unauthorized}
  end

  # The community build serves exactly one Account, the one holding the
  # community slot. A structurally valid key belonging to any other Account is
  # rejected by the catch-all clause below with the same opaque error as a
  # forged key, so key holders cannot detect other tenants.
  defp authenticate_api_key_in_account(%{edition_slot: "community-free"} = account, api_key) do
    strategy = Info.strategy!(Peer, :api_key)

    case Strategy.action(strategy, :sign_in, %{api_key: api_key}, tenant: account.id) do
      {:ok, peer} ->
        # The matched key row travels back as action metadata. It is passed on
        # to role resolution because it carries the key's optional scope
        # restriction, which must be applied to the resulting context.
        api_key_record = peer.__metadata__[:api_key]
        identity = identity_link!(account.id, peer.id, "apikey", api_key_record.id)

        {:ok,
         RoleResolver.resolve(account, peer,
           identity_id: identity.id,
           kind: :api_key,
           assurance: assurance_atom(identity.assurance),
           api_key: api_key_record
         )}

      {:error, _error} ->
        {:error, :unauthorized}
    end
  end

  defp authenticate_api_key_in_account(_account, _api_key), do: {:error, :unauthorized}

  # Session-token path. The token is verified against the community Account's
  # id, and the Peer it names must exist inside that Account — a validly signed
  # token for a Peer that has since been removed is rejected.
  defp authenticate_token(token) do
    DataLayer.with_existing_free_account(fn account, _system ->
      case verify_token(token, account.id) do
        {:ok, %{"sub" => subject}} ->
          case AshAuthentication.subject_to_user(subject, Peer, tenant: account.id) do
            {:ok, peer} ->
              identity =
                identity_link!(
                  account.id,
                  peer.id,
                  "password",
                  peer.email |> to_string() |> String.downcase()
                )

              {:ok,
               RoleResolver.resolve(account, peer,
                 identity_id: identity.id,
                 kind: :password,
                 assurance: assurance_atom(identity.assurance)
               )}

            _ ->
              {:error, :unauthorized}
          end

        _ ->
          {:error, :unauthorized}
      end
    end)
  rescue
    _error -> {:error, :unauthorized}
  end

  # Every claim is checked explicitly rather than trusting the library's
  # defaults, because a valid signature alone does not make a token the right
  # token. Each line below rules out a distinct forgery or confusion:
  #
  #   tenant  - the token was minted for this Account, not another one;
  #   purpose - it is a user session, not a token issued for some other flow;
  #   sub     - it names a Peer, so a subject for a different resource type
  #             cannot be smuggled in;
  #   exp/nbf - it is inside its validity window. Since tokens are stateless and
  #             cannot be revoked, expiry is the only way one ever stops working;
  #   iss     - it came from this authentication stack;
  #   aud     - the token format matches the library version now running.
  #
  # Time comes from the injectable clock so tests can move it deterministically.
  defp verify_token(token, account_id) do
    now = Clock.utc_now() |> DateTime.to_unix()
    signer = JwtConfig.token_signer(Peer, [], %{})

    with {:ok, claims} <- Joken.verify(token, signer),
         true <- claims["tenant"] == account_id,
         true <- claims["purpose"] == "user",
         true <- is_binary(claims["sub"]) and String.starts_with?(claims["sub"], "peer?"),
         true <- is_integer(claims["exp"]) and claims["exp"] > now,
         true <- is_integer(claims["nbf"]) and claims["nbf"] <= now,
         true <-
           is_binary(claims["iss"]) and
             String.starts_with?(claims["iss"], "AshAuthentication "),
         true <- valid_audience?(claims["aud"]) do
      {:ok, claims}
    else
      _ -> :error
    end
  end

  # The audience claim is a version requirement string describing which
  # authentication library versions can read this token. It is matched against
  # the version actually loaded, so a token minted by an incompatible version is
  # refused instead of being half-understood. A missing or unparseable audience
  # is a failure, never a pass.
  defp valid_audience?(audience) when is_binary(audience) do
    with {:ok, requirement} <- Version.parse_requirement(audience),
         {:ok, version_chars} <- :application.get_key(:ash_authentication, :vsn),
         {:ok, version} <- version_chars |> to_string() |> Version.parse() do
      Version.match?(version, requirement)
    else
      _ -> false
    end
  end

  defp valid_audience?(_audience), do: false

  # The containment root every other scope hangs beneath. Its path is "/", which
  # the inheritance rules special-case, and it is created by upsert so repeated
  # bootstraps are harmless.
  defp ensure_root_scope!(account_id, actor) do
    Scope
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{
      key: "root",
      name: "MemHouse",
      path: "/",
      state: "active"
    })
    |> Ash.create!(actor: actor)
  end

  # Returns nil when the path names no scope, which every caller then trips over
  # immediately. That is intended: provisioning into a mistyped path must fail
  # loudly rather than quietly land somewhere else.
  defp scope_by_path!(account_id, actor, path) do
    Scope
    |> Ash.Query.filter(path == ^path)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  # Records that a Peer can authenticate through one provider. Write side; the
  # read side is identity_link!/4 below. Nothing secret is stored: the subject
  # is an email or an API key row id, never a password, hash, or key.
  defp link_identity!(
         account_id,
         actor,
         peer_id,
         provider,
         subject,
         email,
         assurance
       ) do
    ExternalIdentity
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create, %{
      peer_id: peer_id,
      provider: provider,
      subject: to_string(subject),
      email: email,
      assurance: assurance,
      linked_at: Clock.utc_now(),
      active: true
    })
    |> Ash.create!(actor: actor)
  end

  # Fetches the credential link backing a successful authentication, so its
  # assurance level can be carried into the caller's context. The `active`
  # filter is the revocation check: with no active link this returns nil, the
  # caller's next field access raises, and the enclosing rescue turns the whole
  # sign-in into `{:error, :unauthorized}` even though the password or key
  # matched. Authenticating against a revoked credential must not succeed with
  # a default assurance.
  defp identity_link!(account_id, peer_id, provider, subject) do
    subject = to_string(subject)

    # A minimal Account-wide context. Credential links live outside the scope
    # tree, so the caller's own (not yet resolved) permissions cannot be used to
    # read them.
    system = %{
      account_id: account_id,
      account_key: nil,
      role: :system,
      scope_ids: :all,
      scope_roles: %{},
      pipeline?: false
    }

    ExternalIdentity
    |> Ash.Query.filter(
      peer_id == ^peer_id and provider == ^provider and subject == ^subject and
        active == true
    )
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: system)
  end

  # Writes one role grant. Grantor and timestamp are supplied by the calling
  # code rather than accepted from request input, so the record of who granted
  # what, and when, cannot be spoofed by a client.
  defp grant_role!(
         account_id,
         actor,
         scope_id,
         peer_id,
         role,
         effect,
         propagate,
         granted_by_peer_id
       ) do
    RoleGrant
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create, %{
      scope_id: scope_id,
      peer_id: peer_id,
      role: role,
      effect: effect,
      propagate: propagate,
      granted_by_peer_id: granted_by_peer_id,
      granted_at: Clock.utc_now()
    })
    |> Ash.create!(actor: actor)
  end

  # Unknown or missing assurance falls to :low rather than raising. Failing
  # closed here means a malformed stored value costs trust, never grants it.
  defp assurance_atom("high"), do: :high
  defp assurance_atom("medium"), do: :medium
  defp assurance_atom(_assurance), do: :low

  # Authority is per scope, so a coarse "is an administrator" test is not
  # enough. A scope missing from the map is unauthorized, and `nil not in
  # permitted_roles` makes that the failing case without a special branch.
  # Raises a forbidden error with no detail, so the caller learns that it may
  # not act here but nothing about why or about the scope's contents.
  defp require_scope_role!(%Actor{scope_roles: scope_roles}, scope_id, permitted_roles) do
    if Map.get(scope_roles, scope_id) not in permitted_roles do
      raise Ash.Error.Forbidden, errors: []
    end
  end

  # Derives a Peer key from an email when the caller did not supply one:
  # lowercase, every run of non-alphanumeric characters collapsed to a single
  # hyphen, and no leading or trailing hyphen. Keys are visible identifiers, so
  # they stay predictable and free of punctuation.
  defp normalized_key(email) do
    email
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Callers pass attribute maps with either atom or string keys; normalising up
  # front lets the rest of the module fetch with one spelling.
  defp stringify_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
