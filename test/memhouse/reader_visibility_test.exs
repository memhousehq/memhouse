# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.ReaderVisibilityTest do
  @moduledoc """
  Evidence that a read is performed for somebody, and shows only what that somebody may see.

  Personal knowledge belongs to its subject until promotion carries it wider, and promotion
  is where the subject agreed. A reader who names nobody has agreed with nobody, so only
  public statements are theirs to read.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Identity
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory

  require Ash.Query

  @scope "/reader"

  setup do
    bootstrap =
      Identity.bootstrap_human(%{
        email: "reader@example.test",
        name: "Reader Admin",
        password: "correct horse battery staple"
      })

    agent =
      Identity.provision_agent(bootstrap.actor, %{
        key: "reader-agent",
        name: "Reader Agent",
        scope_path: "/",
        role: "member"
      })

    {:ok, ingesting_actor} = Identity.authenticate_bearer(agent.api_key)

    # One turn per speaker, so both exist as peers and as session participants.
    for {key, content} <- [
          {"caroline", "Caroline keeps bees on her allotment."},
          {"melanie", "Melanie teaches watercolour on Tuesdays."}
        ] do
      {:ok, _} =
        Memory.ingest_message(
          %{
            "session_id" => "reader-session",
            "scope_path" => @scope,
            "peer_key" => key,
            "content" => content
          },
          ingesting_actor
        )
    end

    # Re-authenticated after the scope exists. An actor's authorized scopes are a snapshot
    # taken when the credential was verified, and ingest re-resolves them for its own write;
    # a read does not, so the reading actor has to be resolved after the topology it reads.
    {:ok, agent_actor} = Identity.authenticate_bearer(agent.api_key)

    %{bootstrap: bootstrap, agent_actor: agent_actor}
  end

  test "a personal statement reaches its subject and nobody else", ctx do
    seed!(ctx, "caroline", "Caroline is allergic to shellfish.", sensitivity: "personal")

    assert "Caroline is allergic to shellfish." in statements(ctx, "caroline")
    refute "Caroline is allergic to shellfish." in statements(ctx, "melanie")
  end

  test "promotion above peer level is what makes a personal statement shared", ctx do
    seed!(ctx, "caroline", "Caroline is allergic to shellfish.",
      sensitivity: "personal",
      target_level: "scope"
    )

    # The subject already agreed: an above-peer proposal is held until they do, so an active
    # row at scope level carries that agreement with it.
    assert "Caroline is allergic to shellfish." in statements(ctx, "melanie")
  end

  test "a reader who names nobody sees public statements only", ctx do
    seed!(ctx, "caroline", "Caroline is allergic to shellfish.", sensitivity: "personal")
    seed!(ctx, "caroline", "Caroline holds the allotment gate rota.", sensitivity: "public")
    seed!(ctx, "caroline", "Caroline tracks the build pipeline.", sensitivity: "internal")

    found = statements(ctx, nil)
    listed_found = listed(ctx, nil)

    assert "Caroline holds the allotment gate rota." in found
    refute "Caroline is allergic to shellfish." in found
    refute "Caroline tracks the build pipeline." in found

    assert "Caroline holds the allotment gate rota." in listed_found
    refute "Caroline is allergic to shellfish." in listed_found
    refute "Caroline tracks the build pipeline." in listed_found
  end

  test "internal knowledge is shared, because internal is not personal", ctx do
    seed!(ctx, "caroline", "Caroline reviews the release notes.", sensitivity: "internal")

    assert "Caroline reviews the release notes." in statements(ctx, "melanie")
  end

  test "naming a reader borrows none of that reader's reach", ctx do
    seed!(ctx, "caroline", "Caroline is allergic to shellfish.", sensitivity: "personal")

    # A credential granted only inside a child scope. KnowledgeItem's read policy grants a
    # self-view on subject_peer_id that ignores scope entirely, so without the scope filter
    # every read path applies, naming Caroline here would reach her statements anywhere in
    # the Account. Reading for a peer must not hand out that peer's reach.
    limited = limited_agent_actor!(ctx)

    assert statements(%{ctx | agent_actor: limited}, "caroline") == []
  end

  test "the knowledge listing applies the same rule as retrieval", ctx do
    seed!(ctx, "caroline", "Caroline is allergic to shellfish.", sensitivity: "personal")

    # Two doors to the same statements. A rule applied to only one of them is not a rule.
    assert "Caroline is allergic to shellfish." in listed(ctx, "caroline")
    refute "Caroline is allergic to shellfish." in listed(ctx, "melanie")
  end

  test "a nil peer_id machine credential without peer_key sees public statements only in context", ctx do
    seed!(ctx, "caroline", "Caroline is allergic to shellfish.", sensitivity: "personal")
    seed!(ctx, "caroline", "Caroline holds the allotment gate rota.", sensitivity: "public")
    seed!(ctx, "caroline", "Caroline tracks the build pipeline.", sensitivity: "internal")

    # Create a machine credential with no peer. An internal caller must explicitly provide peer_key
    # for ingest, but for reads it represents a peerless non-internal reader.
    DataLayer.with_account_key(account_key(), [role: :member], fn _account, peerless_actor ->
      # Force peer_id to nil to simulate a peerless machine credential
      peerless_actor = %{peerless_actor | peer_id: nil}

      context_result =
        MemHouse.Context.get(
          MemHouse.DataLayer.with_free_account(fn account, _actor -> account end),
          peerless_actor,
          [
            MemHouse.Topology.Scope
            |> Ash.Query.filter(path == ^@scope)
            |> Ash.Query.set_tenant(
              MemHouse.DataLayer.with_free_account(fn account, _actor -> account.id end)
            )
            |> Ash.read_one!(actor: %{peerless_actor | scope_ids: :all})
          ],
          %{},
          false
        )

      knowledge_statements =
        context_result["knowledge"]
        |> Enum.map(& &1["statement"])

      assert "Caroline holds the allotment gate rota." in knowledge_statements
      refute "Caroline is allergic to shellfish." in knowledge_statements
      refute "Caroline tracks the build pipeline." in knowledge_statements
    end)
  end

  # Writes one active statement about `subject_key` directly, so a test names the exact
  # sensitivity and level it is about instead of depending on what an extractor proposes.
  defp seed!(ctx, subject_key, statement, opts) do
    DataLayer.with_account_key(account_key(), [role: :system, pipeline?: true], fn account,
                                                                                   actor ->
      scope =
        MemHouse.Topology.Scope
        |> Ash.Query.filter(path == ^@scope)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: %{actor | scope_ids: :all})

      subject = peer_by_key!(ctx, subject_key)

      proposed =
        KnowledgeItem
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create_from_pipeline, %{
          scope_id: scope.id,
          subject_peer_id: subject.id,
          statement: statement,
          kind: "fact",
          confidence: 1.0,
          evidence_level: "direct",
          sensitivity: Keyword.fetch!(opts, :sensitivity),
          state: "proposed",
          target_level: Keyword.get(opts, :target_level, "peer"),
          extracting_model: "test:reader-visibility",
          pipeline_version: "f5-1"
        })
        |> Ash.create!(actor: actor)

      # Knowledge enters proposed and only the lifecycle may activate it, so the settled
      # row these tests read is produced the same way the pipeline produces one.
      MemHouse.Governance.Engine.transition!(proposed, actor, %{state: "active"},
        reason: "reader_visibility_seed",
        channel: "pipeline"
      )
    end)
  end

  defp statements(ctx, peer_key, scope_path \\ @scope) do
    peer_key
    |> search_attrs()
    |> Map.put("scope_path", scope_path)
    |> Memory.search(ctx.agent_actor)
    |> Map.fetch!("candidates")
    |> Enum.map(& &1["statement"])
  end

  defp listed(ctx, peer_key) do
    search_attrs(peer_key)
    |> Map.delete("query")
    |> Memory.query_knowledge(ctx.agent_actor)
    |> Enum.map(& &1["statement"])
  end

  # An agent whose only grant is a child of the scope holding the seeded statement. Its own
  # turn creates that child scope, because provisioning requires the scope to exist.
  defp limited_agent_actor!(ctx) do
    child = "#{@scope}/limited"

    {:ok, _} =
      Memory.ingest_message(
        %{
          "session_id" => "reader-limited",
          "scope_path" => child,
          "peer_key" => "priya",
          "content" => "Priya runs the Thursday standup."
        },
        ctx.agent_actor
      )

    # The admin's own grants were resolved before this scope existed, and provisioning
    # re-checks authority at the target scope, so the actor is resolved again.
    {:ok, signed_in} =
      Identity.sign_in_password("reader@example.test", "correct horse battery staple")

    limited =
      Identity.provision_agent(signed_in.actor, %{
        key: "limited-agent",
        name: "Limited Agent",
        scope_path: child,
        role: "member"
      })

    {:ok, actor} = Identity.authenticate_bearer(limited.api_key)
    actor
  end

  defp account_key do
    MemHouse.DataLayer.with_free_account(fn account, _actor -> account.key end)
  end

  defp search_attrs(nil), do: %{"query" => "Caroline", "scope_path" => @scope, "limit" => "50"}

  defp search_attrs(peer_key),
    do: Map.put(search_attrs(nil), "peer_key", peer_key)

  defp peer_by_key!(_ctx, key) do
    DataLayer.with_account_key(account_key(), [role: :system], fn account, actor ->
      MemHouse.Accounts.Peer
      |> Ash.Query.filter(key == ^key)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)
    end)
  end
end
