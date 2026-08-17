# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.F1AshDomainBackboneTest do
  @moduledoc """
  Pins the durable-data boundary: every persistent row is owned by an Ash resource,
    reachable only through an Ash action, and walled off per Account by PostgreSQL
    row-level security.

    Authorization is derived from identity, never from request input.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Governance.AuditEvent
  alias MemHouse.Governance.PolicyConfig
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.LifecycleEvent
  alias MemHouse.Memory
  alias MemHouse.Observations.Message
  alias MemHouse.Repo
  alias MemHouse.Topology.Scope

  # The complete set of configured Ash domains. Order is the configured order and is asserted
  # verbatim against application configuration, so a domain added to one place and not the
  # other is caught here.
  @domains [
    MemHouse.Accounts,
    MemHouse.Topology,
    MemHouse.Observations,
    MemHouse.Documents,
    MemHouse.Knowledge,
    MemHouse.Governance,
    MemHouse.Model,
    MemHouse.Retrieval,
    MemHouse.Skills,
    MemHouse.Operations
  ]

  # Every durable resource the domains may expose, sorted. This is the authoritative census of
  # what may hold persistent state; anything storing durable data outside this list is writing
  # behind the Ash boundary and escapes tenancy, policy, and audit.
  @resources [
    MemHouse.Accounts.Account,
    MemHouse.Accounts.ApiKey,
    MemHouse.Accounts.ExternalIdentity,
    MemHouse.Accounts.Peer,
    MemHouse.Documents.ConnectorConfig,
    MemHouse.Documents.DocumentChunk,
    MemHouse.Governance.AuditEvent,
    MemHouse.Governance.Consent,
    MemHouse.Governance.ErasureRequest,
    MemHouse.Governance.GateDecision,
    MemHouse.Governance.GateRule,
    MemHouse.Governance.McpTools,
    MemHouse.Governance.PeerAskPreference,
    MemHouse.Governance.PeerQuery,
    MemHouse.Governance.PeerQueryDelivery,
    MemHouse.Governance.PolicyConfig,
    MemHouse.Governance.ValidationItem,
    MemHouse.Knowledge.Attribution,
    MemHouse.Knowledge.Entity,
    MemHouse.Knowledge.EntityMention,
    MemHouse.Knowledge.KnowledgeItem,
    MemHouse.Knowledge.KnowledgeRelation,
    MemHouse.Knowledge.LifecycleEvent,
    MemHouse.Knowledge.Projection,
    MemHouse.Knowledge.Provenance,
    MemHouse.Model.ModelRoleConfig,
    MemHouse.Observations.Document,
    MemHouse.Observations.DocumentVersion,
    MemHouse.Observations.Message,
    MemHouse.Observations.Session,
    MemHouse.Observations.SessionParticipant,
    MemHouse.Observations.SessionScope,
    MemHouse.Operations.DreamTimeWatermark,
    MemHouse.Operations.PipelineRun,
    MemHouse.Operations.UsageEvent,
    MemHouse.Retrieval.RecallDocument,
    MemHouse.Retrieval.RetrievalProfile,
    MemHouse.Skills.SkillRequirementCard,
    MemHouse.Topology.RoleGrant,
    MemHouse.Topology.Scope,
    MemHouse.Topology.ScopeRelation
  ]

  # Every table that must carry the Account wall in the database itself: `accounts` plus each
  # table with an `account_id` column. A tenant table missing from this list would still be
  # filtered by Ash policies in normal operation, but would be readable by anything that
  # reaches PostgreSQL another way. The assertion below proves every listed table has the
  # policy; keeping the list complete when a tenant table is added is a review obligation.
  @rls_tables ~w(
    accounts api_keys attributions audit_events connector_configs document_chunks document_versions
    documents dream_time_watermarks entities entity_mentions erasure_requests external_identities gate_decisions
    governance_gate_rules knowledge_consents knowledge_items knowledge_lifecycle_events
    knowledge_relations messages model_role_configs peer_ask_preferences peer_queries
    peer_query_deliveries peers pipeline_runs policy_configs projections provenances recall_documents
    retrieval_profiles role_grants scope_relations scopes session_participants session_scopes
    sessions skill_requirement_cards usage_events validation_items
  )

  # Removes every credential a provider could pick up, so the seed ingests below cannot reach
  # a network endpoint: this suite is about the data boundary, and no assertion should depend
  # on a live model. Both values are global to the node, hence the capture/restore and
  # `async: false`.
  setup do
    original_api_key = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:memhouse, :models)

    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:memhouse, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      if original_api_key do
        System.put_env("OPENROUTER_API_KEY", original_api_key)
      else
        System.delete_env("OPENROUTER_API_KEY")
      end

      Application.put_env(:memhouse, :models, original_models)
    end)

    :ok
  end

  # Equality in both directions is the point: a resource present in a domain but missing from
  # the list fails, and a listed resource that no domain exposes fails too. Neither direction
  # may be softened into a subset check, or the tripwire stops firing.
  test "the F1 resource inventory is registered across the modular Ash domains" do
    resources =
      @domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.sort()

    assert resources == Enum.sort(@resources)
    assert Application.fetch_env!(:memhouse, :ash_domains) == @domains
  end

  # Two independent Accounts, each with one scope and one ingested observation, so that a
  # cross-Account read has something it could wrongly return.
  test "Ash actions enforce the Account wall and governance separation" do
    seed!("f1-action-a", "/f1/action/a")
    seed!("f1-action-b", "/f1/action/b")

    {account_a, actor_a} =
      DataLayer.with_account_key("f1-action-a", fn account, actor -> {account, actor} end)

    {account_b, _actor_b} =
      DataLayer.with_account_key("f1-action-b", fn account, actor -> {account, actor} end)

    # Naming a foreign tenant on the query is exactly the attack this wall exists for: the
    # Account comes from the actor's identity, so the request parameter buys nothing and the
    # read comes back empty rather than raising. Any row here is a cross-Account data leak.
    assert [] =
             Scope
             |> Ash.Query.set_tenant(account_b.id)
             |> Ash.read!(actor: actor_a)

    visible_scope_id = scope_id!("f1-action-a", "/f1/action/a")
    scope_limited_actor = Actor.for_account(account_a, scope_ids: [visible_scope_id])

    # Inside the right Account, an actor whose grants cover only one scope still sees only that
    # scope. Account isolation and scope authorization are separate filters and both apply.
    assert [%Scope{path: "/f1/action/a"}] =
             Scope
             |> Ash.Query.set_tenant(account_a.id)
             |> Ash.read!(actor: scope_limited_actor)

    # Knowledge has exactly one writer: the extraction pipeline. An ordinary member actor
    # holding a valid Account and a scope it can read still cannot mint a statement, because
    # anything written this way would skip extraction provenance and governance review.
    assert {:error, _forbidden} =
             KnowledgeItem
             |> Ash.Changeset.for_create(:create_from_pipeline, %{
               scope_id: visible_scope_id,
               statement: "A member attempted to bypass the knowledge pipeline."
             })
             |> Ash.Changeset.set_tenant(account_a.id)
             |> Ash.create(actor: actor_a)

    # Governance configuration is administrator-only. If a member could write a policy row it
    # could widen its own gates, so the same create must fail for a member and succeed for an
    # administrator of the same Account — the difference is the role, nothing else.
    assert {:error, _forbidden} =
             PolicyConfig
             |> Ash.Changeset.for_create(:create, %{
               key: "gate-b",
               value: %{threshold: 0.9},
               version: 1
             })
             |> Ash.Changeset.set_tenant(account_a.id)
             |> Ash.create(actor: actor_a)

    admin = Actor.for_account(account_a, role: :account_admin)

    assert {:ok, %PolicyConfig{key: "gate-b"}} =
             PolicyConfig
             |> Ash.Changeset.for_create(:create, %{
               key: "gate-b",
               value: %{threshold: 0.9},
               version: 1
             })
             |> Ash.Changeset.set_tenant(account_a.id)
             |> Ash.create(actor: admin)
  end

  test "content and audit stay durable while lifecycle history has one retention action" do
    # Observations are written once. The single destroy action is subject erasure, which is a
    # deliberate right-to-be-forgotten path, not an ordinary delete; the one update action
    # accepts only `extraction_completed_at`, not the stored content. A second destroy action
    # appearing here would mean raw history became routinely deletable.
    assert action_types(Message) == [:create, :destroy, :read, :update]
    assert Ash.Resource.Info.action(Message, :erase).type == :destroy

    # Lifecycle rows are immutable while retained. Only the internal retention worker can remove
    # an expired row. Audit has no destroy action and remains the permanent evidence chain.
    assert action_types(LifecycleEvent) == [:create, :destroy, :read]
    assert Ash.Resource.Info.action(LifecycleEvent, :prune).type == :destroy

    assert LifecycleEvent
           |> Ash.Resource.Info.actions()
           |> Enum.filter(&(&1.type == :destroy))
           |> Enum.map(& &1.name) == [:prune]

    assert action_types(AuditEvent) == [:create, :read]

    # A knowledge statement is fixed at mint time. Merging duplicates and moving an item
    # through its lifecycle must not be able to swap the text underneath an existing id, or
    # every citation, decision, and audit hash referring to that id would silently change
    # meaning. Correcting a statement is instead a new item that supersedes the old one.
    refute :statement in action_accept(KnowledgeItem, :merge_from_pipeline)
    refute :statement in action_accept(KnowledgeItem, :transition)
    assert :statement in action_accept(KnowledgeItem, :create_from_pipeline)
  end

  # This is the test the row-level-security policies could not previously earn: PostgreSQL
  # exempts superusers from row-level security unconditionally, and FORCE ROW LEVEL SECURITY
  # only removes the table owner's exemption, never the superuser's. Every connection this
  # suite made before MemHouse.Database.AppRole existed was a superuser, so a query issued
  # with no Account setting at all still returned rows — the isolation failure this asserts
  # against would have passed silently. Confirming the role's own catalog attributes first is
  # what makes the zero-rows assertion below mean something rather than being a coincidence of
  # this particular row set.
  test "the connection cannot bypass row-level security, and an undeclared Account sees nothing" do
    assert %{rows: [[current_role, superuser?, bypass_rls?]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT current_user::text, COALESCE(rolsuper, false), COALESCE(rolbypassrls, false)
               FROM pg_roles
               WHERE rolname = current_user
               """,
               []
             )

    refute superuser?, "connected as #{current_role}, which is a superuser and exempt from RLS"

    refute bypass_rls?,
           "connected as #{current_role}, which holds BYPASSRLS and is exempt from RLS"

    seed!("f1-undeclared", "/f1/undeclared")

    # Seeding goes through the Account-scoped transaction helper, which leaves its Account
    # settings installed on this connection for the rest of the enclosing transaction — under
    # the sandbox, that is the rest of this test. Clearing both explicitly is what makes the
    # query below run with no Account declared at all, not one accidentally left by the setup
    # that would trivially see its own row.
    Ecto.Adapters.SQL.query!(Repo, "SELECT set_config('memhouse.account_id', '', true)", [])
    Ecto.Adapters.SQL.query!(Repo, "SELECT set_config('memhouse.account_key', '', true)", [])

    # No Account setting is installed on this connection at all — not even a foreign one. A
    # superuser or BYPASSRLS role would still return the row created above; the restricted role
    # this suite now runs as must return nothing.
    assert %{rows: []} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT id FROM scopes WHERE path = $1",
               ["/f1/undeclared"]
             )
  end

  test "Postgres RLS filters reads and rejects cross-Account writes for a non-owner role" do
    seed!("f1-rls-a", "/f1/rls/a")
    seed!("f1-rls-b", "/f1/rls/b")

    account_a_id = account_id!("f1-rls-a")
    account_b_id = account_id!("f1-rls-b")

    # Catalog check, not a behaviour check: every walled table must have row security enabled
    # (relrowsecurity), forced so the table owner is subject to it too (relforcerowsecurity),
    # and carry the one named Account policy. Enabled-but-not-forced would silently do nothing
    # for the role a release normally connects as.
    assert %{rows: policy_rows} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT class.relname
               FROM pg_class AS class
               JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
               JOIN pg_policy AS policy ON policy.polrelid = class.oid
               WHERE namespace.nspname = 'public'
                 AND class.relname = ANY($1)
                 AND class.relrowsecurity
                 AND class.relforcerowsecurity
                 AND policy.polname = 'memhouse_account_wall'
               ORDER BY class.relname
               """,
               [@rls_tables]
             )

    assert Enum.map(policy_rows, &hd/1) == Enum.sort(@rls_tables)

    # No role switch happens here, and that absence is the point. This connection already runs
    # as the restricted role the application connects as everywhere, which is neither a
    # superuser nor granted BYPASSRLS, so the policies below are the same ones a production
    # query meets. An earlier version of this test created a throwaway unprivileged role and
    # switched to it, because the suite itself connected as a superuser and would otherwise
    # have proved nothing; that scaffolding would now hide the very regression it was
    # compensating for, since a suite that fell back to a superuser would still pass.

    # This is how an Account is declared to the database: a transaction-local setting (the
    # third argument makes it local) that the policy compares each row against. It is set by
    # the Account-scoped transaction helper in production, never taken from user input.
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('memhouse.account_id', $1, true)",
      [account_a_id]
    )

    # The query asks for both scopes by path and no Account filter at all. Only the current
    # Account's row may come back; the other one must be invisible at the database level.
    assert %{rows: [[^account_a_id, "/f1/rls/a"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT account_id::text, path
               FROM scopes
               WHERE path IN ('/f1/rls/a', '/f1/rls/b')
               ORDER BY path
               """,
               []
             )

    # The wall blocks writes as well as reads: inserting a row stamped with a different Account
    # violates the policy's check clause and PostgreSQL refuses it. Without this, a compromised
    # or buggy caller could plant rows inside another tenant even though it could not read them.
    assert_raise Postgrex.Error, fn ->
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        INSERT INTO scopes
          (id, account_id, key, name, path, state, inserted_at, updated_at)
        VALUES
          (gen_random_uuid(), $1::uuid, 'blocked', 'blocked', '/f1/rls/blocked',
           'active', NOW(), NOW())
        """,
        [Ecto.UUID.dump!(account_b_id)]
      )
    end
  end

  # Creates an Account, its scope chain, a peer, a session, and one observation by going
  # through the ordinary ingest path, so the fixtures are built the same way production data is
  # rather than by inserting rows behind the Ash boundary this suite is testing.
  defp seed!(account_key, scope_path) do
    assert {:ok, _message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "#{account_key}-session",
               "scope_path" => scope_path,
               "peer_key" => "#{account_key}-peer",
               "content" => "F1 keeps every Account behind Ash actions and PostgreSQL RLS."
             })
  end

  # The distinct action kinds a resource exposes, sorted, so an assertion can state the whole
  # surface: a resource with no destroy action simply has no supported way to delete a row.
  defp action_types(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The attributes an action will take from caller input. An attribute absent from this list
  # cannot be set through that action no matter what the caller sends.
  defp action_accept(resource, action_name) do
    resource
    |> Ash.Resource.Info.action(action_name)
    |> Map.fetch!(:accept)
  end

  # Direct SQL on purpose: reading these identifiers through Ash would install tenancy state
  # that the test is trying to exercise from the database side.
  #
  # The Account key has to be declared first because this connection is subject to the wall
  # like any other. The policy on `accounts` matches a row by id *or* by key, and the key is
  # the half that exists before an id is known — the same bootstrap path the Account-scoped
  # transaction helper uses. Declaring it here rather than trusting whatever a prior helper
  # left installed is what makes this safe to call regardless of call order.
  defp account_id!(key) do
    set_account_key!(key)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(Repo, "SELECT id::text FROM accounts WHERE key = $1", [key])

    id
  end

  # The `scopes` policy matches only by account id — unlike `accounts`, it has no key fallback
  # for bootstrapping — so the id has to be resolved and declared before this can see anything.
  defp scope_id!(account_key, path) do
    account_id = account_id!(account_key)
    set_account_id!(account_id)

    %{rows: [[id]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT id::text FROM scopes WHERE account_id = $1::uuid AND path = $2",
        [Ecto.UUID.dump!(account_id), path]
      )

    id
  end

  # Mirrors the transaction-local settings `MemHouse.DataLayer` installs in production, so a
  # test reading raw SQL meets the same row-level-security policies a real request would.
  defp set_account_key!(account_key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('memhouse.account_key', $1, true)",
      [account_key]
    )
  end

  defp set_account_id!(account_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT set_config('memhouse.account_id', $1, true)",
      [account_id]
    )
  end
end
