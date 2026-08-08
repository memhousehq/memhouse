# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.F3IdentityTenancyBasicRbacTest do
  @moduledoc """
  Pins how a caller becomes an authorized actor: who they are, which Account that puts
    them in, and which scopes they may touch.

    There are two credential paths and one actor shape.
  """

  use MemHouseWeb.ConnCase, async: false
  use ExUnitProperties

  alias MemHouse.Accounts.ApiKey
  alias MemHouse.Accounts.Peer
  alias MemHouse.DataLayer
  alias MemHouse.Identity
  alias MemHouse.Identity.RoleResolver
  alias MemHouse.Repo
  alias MemHouse.Topology.RoleGrant
  alias MemHouse.Topology.Scope
  alias MemHouse.Topology.ScopeRelation

  require Ash.Query

  test "password and API-key strategies derive one Account and linked Peer identities", %{
    conn: conn
  } do
    bootstrap = bootstrap_human!()

    assert {:ok, %{actor: password_actor, token: password_token}} =
             Identity.sign_in_password("admin@example.test", "correct horse battery staple")

    # Everything an authorization decision needs comes from the credential: the Account, the
    # Peer behind it, how the identity was proved, and how strongly. Identity kind and assurance
    # are carried separately from the role because governance cares about both — some decisions
    # are open only to a human identity regardless of how privileged a machine credential is.
    assert password_actor.account_id == bootstrap.account.id
    assert password_actor.peer_id == bootstrap.peer.id
    assert password_actor.identity_kind == :password
    assert password_actor.assurance == :medium
    assert password_actor.role == :account_admin

    # A wrong password yields the same opaque tuple as any other rejection: no hint about
    # whether the account exists.
    assert {:error, :unauthorized} =
             Identity.sign_in_password("admin@example.test", "not the password")

    # The HTTP sign-in endpoint must go through the same code as the direct call above, so the
    # two are asserted side by side rather than only through the web layer.
    assert %{"data" => %{"token" => endpoint_token, "token_type" => "Bearer"}} =
             conn
             |> post(~p"/api/auth/password", %{
               "email" => "admin@example.test",
               "password" => "correct horse battery staple"
             })
             |> json_response(200)

    assert is_binary(password_token)
    assert is_binary(endpoint_token)

    agent =
      Identity.provision_agent(bootstrap.actor, %{
        key: "agent-one",
        name: "Agent One",
        scope_path: "/",
        role: "member"
      })

    # The agent gets its own Peer and its own key, and lands in the same Account as its
    # provisioner with the role that provisioning asked for — a machine credential cannot
    # inherit the administrator role of the human who created it.
    assert String.starts_with?(agent.api_key, "memhouse_")
    assert {:ok, api_actor} = Identity.authenticate_bearer(agent.api_key)
    assert api_actor.account_id == bootstrap.account.id
    assert api_actor.peer_id == agent.peer.id
    assert api_actor.identity_kind == :api_key
    assert api_actor.assurance == :high
    assert api_actor.role == :member

    # One linked identity record per credential path — the human password identity and the
    # agent's key — both bound to this Account. A credential with no Account binding would have
    # no tenant to resolve to.
    assert %{rows: [[2]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT count(*) FROM external_identities WHERE account_id = $1",
               [Ecto.UUID.dump!(bootstrap.account.id)]
             )

    # The key just handed to the caller must not be recoverable from the database. This is the
    # only moment the plaintext exists in the test, so it is the only moment the check is
    # possible.
    refute database_contains_plaintext?(agent.api_key)
  end

  test "the community free slot permits one authenticated Account", _context do
    bootstrap = bootstrap_human!()

    assert bootstrap.account.edition_slot == "community-free"

    # Enforced by a partial unique index on the edition slot, so the limit holds against direct
    # SQL and any future code path, not just the provisioning function. The insert is deliberately
    # raw for that reason: it bypasses every application-level guard and must still be refused.
    #
    # Declaring the Account key first is what lets this test reach the index at all: the
    # connection here is the same restricted role production connects as, and row-level
    # security's WITH CHECK clause would otherwise reject the insert before the index ever saw
    # it, since a fresh id and an undeclared key match neither half of the accounts policy. The
    # key is declared, never the id, matching the row this statement is about to attempt.
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('memhouse.account_key', $1, true)",
      ["second-free"]
    )

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO accounts
                 (id, key, name, edition_slot, inserted_at, updated_at)
               VALUES
                 (gen_random_uuid(), 'second-free', 'Second Free',
                  'community-free', NOW(), NOW())
               """
             )
  end

  test "unknown and malformed credentials return the same non-leaking failure", %{conn: conn} do
    bootstrap_human!()

    # A real, correctly formed, verifiable key — belonging to a different Account. This is the
    # interesting case: it is the one an implementation is most tempted to answer differently,
    # with a "wrong tenant" style message, which would confirm to an attacker that the key is
    # genuine.
    foreign_api_key = foreign_api_key!()

    missing = post(conn, ~p"/api/v1/search", %{"query" => "anything"})

    malformed =
      conn
      |> put_req_header("authorization", "Bearer memhouse_not-a-real-key")
      |> post(~p"/api/v1/search", %{"query" => "anything"})

    foreign =
      conn
      |> put_req_header("authorization", "Bearer #{foreign_api_key}")
      |> post(~p"/api/v1/search", %{"query" => "anything"})

    # Same status and byte-identical bodies. Comparing the raw bodies rather than the decoded
    # maps is intentional: a difference in wording, key order, or added detail is exactly the
    # leak being prevented.
    assert missing.status == 401
    assert malformed.status == 401
    assert foreign.status == 401
    assert missing.resp_body == malformed.resp_body
    assert missing.resp_body == foreign.resp_body
    assert Jason.decode!(missing.resp_body) == %{"error" => "Unauthorized"}
  end

  test "cross-linked scopes are visible only when both endpoints are authorized" do
    unique = System.unique_integer([:positive])

    DataLayer.with_account_key("f3-link-#{unique}", [role: :system], fn account, system ->
      peer = create_peer!(account.id, system, "link-peer-#{unique}")
      source = create_scope!(account.id, system, "/link-#{unique}/source", nil)
      target = create_scope!(account.id, system, "/link-#{unique}/target", nil)

      # Two unrelated scopes — neither contains the other — joined only by a cross-link, and a
      # reader grant on just one end.
      create_grant!(account.id, system, source.id, peer.id, "reader", "allow", false)

      relation =
        ScopeRelation
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create, %{
          source_scope_id: source.id,
          target_scope_id: target.id,
          kind: "related"
        })
        |> Ash.create!(actor: system)

      source_only = RoleResolver.resolve(account, peer, kind: :password, assurance: :medium)

      # Access to one end reveals nothing about the link. If the relation were visible here, a
      # reader of any scope could discover — and then follow, during retrieval — edges into
      # scopes they were never granted.
      assert [] =
               ScopeRelation
               |> Ash.Query.filter(id == ^relation.id)
               |> Ash.Query.set_tenant(account.id)
               |> Ash.read!(actor: source_only)

      # Grant the other end, then re-resolve. The actor must be rebuilt rather than reused: its
      # authorized scope list is computed when the credential is resolved, so an actor already
      # in hand never silently gains scopes that were granted after it was built.
      create_grant!(account.id, system, target.id, peer.id, "reader", "allow", false)
      both = RoleResolver.resolve(account, peer, kind: :password, assurance: :medium)

      assert [%ScopeRelation{id: relation_id}] =
               ScopeRelation
               |> Ash.Query.filter(id == ^relation.id)
               |> Ash.Query.set_tenant(account.id)
               |> Ash.read!(actor: both)

      assert relation_id == relation.id
    end)
  end

  # Randomized Account keys, because a wall that holds only for the two names a fixture happens
  # to use is not a wall. 12 runs: each one creates two Accounts with real rows, so the run
  # count is bounded by database cost rather than by how much coverage would be nice.
  property "Account policy never exposes a foreign tenant" do
    check all(
            suffix <- string(:alphanumeric, min_length: 4, max_length: 12),
            max_runs: 12
          ) do
      # The generated suffix alone can repeat across runs; the counter makes each pair of
      # Accounts distinct within the single sandbox transaction shared by the whole property.
      unique = "#{suffix}-#{System.unique_integer([:positive])}"

      {account_a, actor_a} =
        DataLayer.with_account_key("f3-wall-a-#{unique}", [role: :system], fn account, actor ->
          create_scope!(account.id, actor, "/wall-a-#{unique}", nil)
          {account, actor}
        end)

      account_b =
        DataLayer.with_account_key("f3-wall-b-#{unique}", [role: :system], fn account, actor ->
          create_scope!(account.id, actor, "/wall-b-#{unique}", nil)
          account
        end)

      assert account_a.id != account_b.id

      # The second Account genuinely has a scope to find, and the first Account's actor still
      # sees nothing when the query is aimed at that tenant. An empty result must come from the
      # actor's identity, never from there being nothing there.
      assert [] =
               Scope
               |> Ash.Query.set_tenant(account_b.id)
               |> Ash.read!(actor: actor_a)
    end
  end

  # Generates a containment chain 2 to 6 scopes deep, one allow grant at its root that may or
  # may not propagate, and optionally one deny somewhere along the chain. The deny is generated
  # over a wider range than the chain length on purpose, so some runs place it past the end and
  # exercise the no-deny path as well. 20 runs keeps the database work bounded.
  property "propagating allows inherit down containment and any applicable deny wins" do
    check all(
            child_count <- integer(1..5),
            propagate <- boolean(),
            deny_at <- one_of([constant(nil), integer(0..5)]),
            max_runs: 20
          ) do
      unique = System.unique_integer([:positive])

      DataLayer.with_account_key("f3-rbac-#{unique}", [role: :system], fn account, system ->
        peer = create_peer!(account.id, system, "rbac-peer-#{unique}")

        # A straight chain: each scope is the child of the previous one, so list position is
        # also containment depth and the expectation below can be stated by index.
        scopes =
          Enum.reduce(0..child_count, [], fn index, scopes ->
            parent = List.last(scopes)
            path = "/rbac-#{unique}/" <> Enum.map_join(0..index, "/", &"s#{&1}")
            scopes ++ [create_scope!(account.id, system, path, parent && parent.id)]
          end)

        root = hd(scopes)
        create_grant!(account.id, system, root.id, peer.id, "member", "allow", propagate)

        # Ignore a generated deny that falls past the end of this run's chain; those runs test
        # the plain inheritance behaviour with no deny at all.
        effective_deny_at =
          if is_integer(deny_at) && deny_at <= child_count, do: deny_at

        if effective_deny_at do
          denied_scope = Enum.at(scopes, effective_deny_at)

          create_grant!(
            account.id,
            system,
            denied_scope.id,
            peer.id,
            "member",
            "deny",
            true
          )
        end

        actor = RoleResolver.resolve(account, peer, kind: :password, assurance: :medium)
        actual = MapSet.new(actor.scope_ids)

        # The independent model of the rule, and therefore the real specification of it:
        #
        #   allowed — the granted scope itself always; deeper scopes only when the grant
        #             propagates down containment.
        #   denied  — a propagating deny covers its own scope and everything beneath it.
        #
        # Deny is applied after allow and cannot be outvoted, which is why it is a separate
        # subtraction rather than another entry in a precedence ordering. Note the deny wins
        # even at the very scope that carries the allow.
        expected =
          scopes
          |> Enum.with_index()
          |> Enum.filter(fn {_scope, index} ->
            allowed = index == 0 || propagate
            denied = is_integer(effective_deny_at) && index >= effective_deny_at
            allowed && !denied
          end)
          |> MapSet.new(fn {scope, _index} -> scope.id end)

        # Set equality both ways: a missing scope is a usability bug, an extra one is a
        # privilege escalation.
        assert actual == expected
      end)
    end
  end

  # The first-operator path: creates the single community Account, its containment root, the
  # human Peer, the password identity, and a propagating administrator grant. Everything else
  # in this file hangs off it, because there is no other way to get a first identity.
  defp bootstrap_human! do
    Identity.bootstrap_human(%{
      email: "admin@example.test",
      name: "Test Admin",
      password: "correct horse battery staple"
    })
  end

  # Finds or creates a Peer by key. The find-or-create action keeps the property tests from
  # failing on a repeated generated key rather than on a real rule violation.
  defp create_peer!(account_id, actor, key) do
    Peer
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{key: key, name: key, kind: "human"})
    |> Ash.create!(actor: actor)
  end

  # Finds or creates one scope. `parent_id` is what establishes containment, and containment is
  # the only relationship role grants inherit along — passing nil makes a scope that inherits
  # nothing, which is exactly what the cross-link test needs.
  defp create_scope!(account_id, actor, path, parent_id) do
    # The key is the last path segment: a scope is identified by its own name within its parent,
    # while the full path is how callers address it.
    key = path |> String.split("/", trim: true) |> List.last()

    Scope
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:ensure, %{
      parent_id: parent_id,
      key: key,
      name: key,
      path: path,
      state: "active"
    })
    |> Ash.create!(actor: actor)
  end

  # A single role grant. `effect` is "allow" or "deny" and `propagate` decides whether it
  # reaches nested scopes; those two flags are the whole inheritance model. The grant time comes
  # from the injectable clock so tests never depend on wall time.
  defp create_grant!(account_id, actor, scope_id, peer_id, role, effect, propagate) do
    RoleGrant
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(:create, %{
      scope_id: scope_id,
      peer_id: peer_id,
      role: role,
      effect: effect,
      propagate: propagate,
      granted_at: MemHouse.Clock.utc_now()
    })
    |> Ash.create!(actor: actor)
  end

  # Reads the stored credential column back as text and asks whether it equals the plaintext
  # key. It must always answer false: the column holds a digest, so a database dump is useless
  # to an attacker. A true here means keys are recoverable from storage.
  defp database_contains_plaintext?(plaintext) do
    %{rows: [[found]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT EXISTS (
          SELECT 1
          FROM api_keys
          WHERE encode(api_key_hash, 'escape') = $1
        )
        """,
        [plaintext]
      )

    found
  end

  # Mints a genuinely valid API key inside a second, internal Account — one that does not hold
  # the community free slot. Used to prove that a real credential attached to the wrong Account
  # is rejected exactly like a fabricated one. The plaintext is available only from the freshly
  # created record's metadata, because it is never stored.
  defp foreign_api_key! do
    unique = System.unique_integer([:positive])

    DataLayer.with_account_key("f3-foreign-#{unique}", [role: :system], fn account, system ->
      peer = create_peer!(account.id, system, "foreign-peer-#{unique}")

      api_key =
        ApiKey
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create, %{
          account_id: account.id,
          peer_id: peer.id
        })
        |> Ash.create!(actor: system)

      api_key.__metadata__[:plaintext_api_key]
    end)
  end
end
