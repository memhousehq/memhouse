# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleLiveTest do
  @moduledoc """
  End-to-end evidence for the browser console: who may open it, what each role is
    shown, and that the pages render against a real Account rather than a fixture.

    1. **An unauthenticated or machine caller reaching the console.
  """

  use MemHouseWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MemHouse.Accounts.ExternalIdentity
  alias MemHouse.Accounts.Peer
  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine, as: GovernanceEngine
  alias MemHouse.Identity
  alias MemHouse.Knowledge.Entity
  alias MemHouse.Knowledge.EntityMention
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.Projection
  alias MemHouse.Memory
  alias MemHouse.Topology.Scope
  alias MemHouseWeb.Console.Loader

  require Ash.Query

  @password "correct horse battery staple"

  describe "reaching the console" do
    test "an anonymous visitor is sent to sign in", %{conn: conn} do
      assert redirected_to(get(conn, "/console")) == "/sign-in"
      assert redirected_to(get(conn, "/console/knowledge")) == "/sign-in"
      assert redirected_to(get(conn, "/console/tools")) == "/sign-in"
      assert redirected_to(get(conn, "/console/me")) == "/sign-in"
    end

    test "the bare origin points at the console", %{conn: conn} do
      assert redirected_to(get(conn, "/")) == "/console"
    end

    test "a machine credential cannot open a console session", %{conn: conn} do
      %{actor: admin} = bootstrap_admin!()

      %{api_key: api_key} =
        Identity.provision_agent(admin, %{"key" => "console-agent", "scope_path" => "/"})

      # An API key is a valid credential on the JSON surface. It is not a person,
      # so the browser surface must refuse it rather than resolve it.
      conn = conn |> init_test_session(governance_token: api_key) |> get("/console")

      assert redirected_to(conn) == "/sign-in"
    end

    test "sign-in rejects a wrong password without saying why", %{conn: conn} do
      bootstrap_admin!()

      conn = post(conn, "/sign-in", %{"email" => "admin@example.test", "password" => "wrong"})

      assert redirected_to(conn) == "/sign-in?error=invalid"
    end

    test "a correct sign-in opens the console", %{conn: conn} do
      bootstrap_admin!()

      conn = post(conn, "/sign-in", %{"email" => "admin@example.test", "password" => @password})

      assert redirected_to(conn) == "/console"
      assert get_session(conn, :governance_token)
    end
  end

  describe "the pages an account admin sees" do
    setup [:seed_world]

    test "the overview counts what is stored and offers the operator tiles", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console") |> html_response(200)

      assert html =~ "Overview"
      assert html =~ "Statements you can read"
      assert html =~ "Lifecycle"
      # Operator tiles are for account admins only.
      assert html =~ "System readiness"
      assert html =~ "Recorded usage"
      assert html =~ "Operations"
    end

    test "the explorer lists the ingested statement", %{
      conn: conn,
      admin_token: token,
      statement: statement
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      assert html =~ "Knowledge"
      assert html =~ statement
    end

    test "the detail page shows provenance, lifecycle, and the raw observation", %{
      conn: conn,
      admin_token: token,
      knowledge_id: id,
      statement: statement,
      observation: observation
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge/#{id}") |> html_response(200)

      assert html =~ statement
      assert html =~ "Provenance"
      assert html =~ "Lifecycle"
      assert html =~ "How this was produced"
      # The raw observation is the whole point of the page: a reader must be
      # able to check the claim against what was actually said.
      assert html =~ observation
    end

    test "an unknown statement id reports not found rather than forbidden", %{
      conn: conn,
      admin_token: token
    } do
      html =
        conn
        |> sign_in(token)
        |> get("/console/knowledge/#{Ecto.UUID.generate()}")
        |> html_response(200)

      assert html =~ "Statement not found"
    end

    test "the scope directory shows the tree and the grants behind it", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/scopes") |> html_response(200)

      assert html =~ "Directory"
      assert html =~ "/console-test"
      assert html =~ "Role grants"
    end

    test "the scope directory shows index coverage for a scope whose refresh never ran", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/scopes") |> html_response(200)

      # The world is seeded by ingestion alone, so its statements exist and its vectors do
      # not — the state a cancelled projection refresh leaves behind. Without this column the
      # page is identical to a fully indexed Account.
      assert html =~ "Indexed"
      assert html =~ "Mentions"
      assert html =~ "coverage-gap"
    end

    test "the graph renders SVG nodes and no entity data", %{conn: conn, admin_token: token} do
      html = conn |> sign_in(token) |> get("/console/graph") |> html_response(200)

      assert html =~ "<svg"
      assert html =~ "node-scope"
      # The recall cache must not surface here under any name.
      refute html =~ "canonical_name"
      refute html =~ "entity_mention"
    end

    test "sources shows the raw observation it was extracted from", %{
      conn: conn,
      admin_token: token,
      observation: observation
    } do
      html = conn |> sign_in(token) |> get("/console/sources") |> html_response(200)

      assert html =~ "Observations"
      assert html =~ observation
    end

    test "skills offers a readiness check and the card library", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/skills") |> html_response(200)

      assert html =~ "Check your readiness"
      assert html =~ "Card library"
    end

    test "the tool workbench exposes and runs the complete MCP action inventory", %{
      conn: conn,
      admin_token: token,
      statement: statement
    } do
      {:ok, view, html} = live(sign_in(conn, token), "/console/tools")

      for tool <-
            ~w(ingest get_context search ask query_knowledge check_readiness resolve_validation set_ask_preference) do
        assert html =~ ~s|id="tool-#{tool}"|
      end

      # The page is read as intent first: a group heading, a human title, and an
      # action-shaped submit label, with the action name kept as detail.
      for label <- ["Retrieve", "Operate", "Evaluate", "Browse knowledge", "Save observation"] do
        assert html =~ label
      end

      html =
        render_submit(view, "run", %{
          "tool" => "query_knowledge",
          "session_id" => "console-tools-query",
          "scope_path" => "/console-test",
          "state" => "active",
          "limit" => "5"
        })

      assert html =~ "Result · query_knowledge"
      assert html =~ "Browse knowledge · run 1"
      assert html =~ "Statements"
      assert html =~ "What was submitted"
      assert html =~ statement

      html =
        render_submit(view, "run", %{
          "tool" => "search",
          "session_id" => "console-tools-search",
          "scope_path" => "/console-test",
          "query" => "asynchronous standups",
          "profile" => "balanced",
          "limit" => "5"
        })

      assert html =~ "Result · search"
      assert html =~ ~s|&quot;profile&quot;: &quot;balanced&quot;|
      assert html =~ ~s|&quot;candidates&quot;|
      assert html =~ ~s|&quot;retrieval_outcomes&quot;|
      assert html =~ ~s|&quot;state&quot;: &quot;missing_embeddings&quot;|
      assert html =~ ~s|&quot;embedded_count&quot;: 0|
      assert html =~ "rebuild scope derived data"

      # A degraded index returns the same shape as a healthy one, so the state
      # has to be readable without opening the payload.
      assert html =~ "Index health"
      assert html =~ "missing_embeddings — rebuild scope derived data"

      # The previous run is kept so two calls can be compared without rerunning
      # the first one.
      assert html =~ "Earlier runs"
      assert html =~ "Result · query_knowledge"

      html =
        render_submit(view, "run", %{
          "tool" => "ingest",
          "session_id" => "console-tools-ingest",
          "scope_path" => "/console-test",
          "role" => "user",
          "content" => "Avery writes release notes on Fridays."
        })

      assert html =~ "Result · ingest"
      assert html =~ ~s|&quot;status&quot;: &quot;accepted&quot;|

      html =
        render_submit(view, "run", %{
          "tool" => "set_ask_preference",
          "max_per_session" => "1"
        })

      assert html =~ "Result · set_ask_preference"
      assert html =~ ~s|&quot;max_per_session&quot;: 1|

      html =
        render_submit(view, "run", %{
          "tool" => "resolve_validation",
          "_id" => Ecto.UUID.generate(),
          "verdict" => "skip"
        })

      assert html =~ "Tool call failed. Check the fields and your access"
      refute html =~ "Result · resolve_validation"

      # A failed call must not discard the context of the runs that succeeded.
      assert html =~ "Result · set_ask_preference"

      html = render_click(view, "clear-runs")

      refute html =~ "Result · set_ask_preference"
    end

    test "the workbench diagnoses retrieval past the ordinary result window", %{
      conn: conn,
      admin: admin,
      admin_token: token
    } do
      seeded =
        for index <- 1..20 do
          ingest_statement!(
            admin,
            "diagnostic-#{index}",
            "/console-test",
            "Avery published release checklist number #{index}."
          )
        end

      activate_knowledge!(admin, Enum.map(seeded, & &1.id))

      {:ok, view, html} = live(sign_in(conn, token), "/console/tools")

      assert html =~ "Retrieval diagnostic"
      assert html =~ "Not production-equivalent"
      # Closed until asked for: the ordinary forms must not change shape because
      # an administrator happens to be signed in.
      refute html =~ "Run diagnostic"

      # An ordinary search still runs on the ordinary defaults, and says so when
      # it stopped at the limit rather than at the end of the matches.
      normal =
        render_submit(view, "run", %{
          "tool" => "search",
          "session_id" => "console-tools-window",
          "scope_path" => "/console-test",
          "query" => "release checklist",
          "profile" => "balanced"
        })

      assert normal =~ "deeper candidates may exist"

      html = render_click(view, "toggle-diagnostic")

      assert html =~ "Run diagnostic"
      assert html =~ ~s|name="strategies[]"|
      assert html =~ "query-independent"
      assert html =~ ~s|max="#{MemHouseWeb.Console.Diagnostic.limit_cap()}"|

      html =
        render_submit(view, "run-diagnostic", %{
          "query" => "release checklist",
          "scope_path" => "/console-test",
          "profile" => "balanced",
          "limit" => "50",
          "strategies" => ["lexical"],
          "deadline" => "on"
        })

      assert html =~ "Diagnostic result · not production-equivalent"
      assert html =~ "Beyond the ordinary window"
      assert html =~ "rank below the ordinary"
      assert html =~ "Reproducible request"

      # The exported request reproduces the run and identifies nobody. It is read
      # out of its own block: the page also carries the earlier run's context,
      # and asserting over the whole document would not test the export.
      request = diagnostic_request(html)

      assert request =~ ~s|&quot;mode&quot;: &quot;diagnostic&quot;|
      assert request =~ ~s|&quot;limit&quot;: 50|
      assert request =~ ~s|&quot;strategies&quot;: [\n    &quot;lexical&quot;\n  ]|
      assert request =~ ~s|&quot;scope_path&quot;: &quot;/console-test&quot;|
      refute request =~ "console-tools-window"
      refute request =~ admin.account_id
      refute request =~ "csrf"

      # Matched query terms are marked, and the marking is server-rendered
      # escaped markup rather than statement text reaching the page raw.
      assert html =~ "<mark>release</mark>"
      assert html =~ "<mark>checklist</mark>"

      # Ranks are the fused positions, so a candidate keeps the place it earned
      # even once the list below is narrowed.
      assert html =~ ~s|value="13"|

      # The rank explanation is opt-in, so the run above carries none.
      refute html =~ "Rank explanation"

      html =
        render_submit(view, "run-diagnostic", %{
          "query" => "release checklist",
          "scope_path" => "/console-test",
          "profile" => "balanced",
          "limit" => "50",
          "strategies" => ["lexical"],
          "deadline" => "on",
          "trace" => "on"
        })

      assert html =~ "Rank explanation"
      assert html =~ "Fusion contribution"
      assert html =~ "Local rank"
      assert html =~ "Local score"

      # Query-dependent-only display is honest about an isolated strategy that
      # never reads the query: it shows nothing rather than the same rows.
      html =
        render_submit(view, "run-diagnostic", %{
          "query" => "release checklist",
          "scope_path" => "/console-test",
          "profile" => "balanced",
          "limit" => "50",
          "strategies" => ["salience_recency"],
          "deadline" => "on",
          "query_dependent_only" => "on"
        })

      assert html =~ "No query-dependent strategy voted for any candidate"

      # An unregistered strategy name is refused without naming internals.
      html =
        render_submit(view, "run-diagnostic", %{
          "query" => "release",
          "scope_path" => "/console-test",
          "profile" => "balanced",
          "strategies" => ["not_a_strategy"]
        })

      assert html =~ "Diagnostic run failed"
    end

    test "the workbench carries one run context that every card starts from", %{
      conn: conn,
      admin_token: token
    } do
      {:ok, view, html} = live(sign_in(conn, token), "/console/tools")

      assert html =~ ~s|id="scope-options"|
      assert html =~ "Start a new session id"

      html =
        render_change(view, "context", %{"session_id" => "shared", "scope_path" => "/nowhere"})

      # Every card's collapsed context reflects the shared value, and an
      # unauthorized path is named before a call is made with it.
      assert length(String.split(html, "shared")) - 1 >= 6
      assert html =~ "Not a scope you can read"

      refute render_click(view, "new-session") =~ ~s|value="shared"|
    end

    test "the tool diagnosis compares stored and configured embedding identities", %{
      admin: admin,
      knowledge_id: knowledge_id
    } do
      admin = Identity.refresh_actor(admin)
      item = load_knowledge!(admin, knowledge_id, select: [:scope_id, :embedding])
      identity = configured_embedding_identity(admin)

      index_knowledge!(admin, item, identity)
      seed_resolution_metrics!(admin, knowledge_id)

      health = Loader.retrieval_health(admin, "/console-test")

      assert health.state == :ready
      assert health.statement_count == 1
      assert health.embedded_count == 1
      assert health.coverage == 1.0
      assert health.mention_count > 0
      assert health.embedding_identities == [health.configured_identity]

      item = load_knowledge!(admin, knowledge_id, select: [:embedding])

      index_knowledge!(admin, item, %{
        provider: "retired-provider",
        model: "retired-model",
        version: "0",
        dimensions: identity.dimensions
      })

      mismatch = Loader.retrieval_health(admin, "/console-test")

      assert mismatch.state == :identity_mismatch
      assert mismatch.next_action == "rebuild scope derived data"
      refute inspect(mismatch) =~ statement_for(admin, knowledge_id)
    end

    test "the personal page offers the subject gestures", %{conn: conn, admin_token: token} do
      html = conn |> sign_in(token) |> get("/console/me") |> html_response(200)

      assert html =~ "About me"
      assert html =~ "Consent requests"
      assert html =~ "Erasure"
    end

    test "operations reports content-free entity resolution quality signals", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      knowledge_id: knowledge_id
    } do
      seed_resolution_metrics!(admin, knowledge_id)

      MemHouse.Retrieval.Diagnostics.record(
        admin.account_id,
        %{
          profile: "thorough",
          profile_version: "f7-1",
          latency_ms: 750,
          pre_rerank_remaining_ms: 600,
          retrieval_outcomes: [
            %{
              component: "reranker",
              status: "dropped",
              reason_class: "timeout",
              elapsed_ms: 500,
              budget_remaining_ms: 100
            }
          ]
        },
        1_500
      )

      metrics = Loader.operations(admin).entity_resolution

      assert metrics.entity_count == 2
      assert metrics.mention_count == 3
      assert metrics.singleton_entity_rate == 0.5
      assert metrics.mentions_per_entity_p50 == 1
      assert metrics.mentions_per_entity_p95 == 2
      assert %{range: "1", entity_count: 1} in metrics.aliases_per_entity
      assert %{range: "2–3", entity_count: 1} in metrics.aliases_per_entity

      html = conn |> sign_in(token) |> get("/console/operations") |> html_response(200)

      assert html =~ "Readiness"
      assert html =~ "Extractor calls per message"
      assert html =~ "Extractor tokens per message"
      assert html =~ "Extractor cost per message"
      assert html =~ "Permanent extraction failures"
      assert html =~ "Entity resolution quality"
      assert html =~ "Singleton entity rate"
      assert html =~ "50.0%"
      assert html =~ "Gate matrix"
      assert html =~ "Retrieval tunings"
      assert html =~ "Scope retrieval health"
      assert html =~ "Latest retrieval outcome"
      assert html =~ ~s|id="retrieval-outcomes"|
      assert html =~ "reranker"
      assert html =~ "timeout"
      refute html =~ "SecretNeedle104"
      refute html =~ "NeverRenderAlias71"
    end

    test "scope retrieval health resolves the effective profile without reading content", %{
      admin: admin,
      knowledge_id: knowledge_id
    } do
      admin = Identity.refresh_actor(admin)
      health = Loader.retrieval_health(admin, "/console-test", "balanced", nil)

      assert health.state == :missing_embeddings
      assert health.statement_count == 1
      assert health.embedded_count == 0
      assert health.effective_profile.name == :balanced
      assert health.effective_profile.version == "f7-1"
      assert health.effective_profile.deadline_ms > 0
      assert health.probe == %{model_calls: 0, content_read: false}
      refute inspect(health) =~ statement_for(admin, knowledge_id)
    end
  end

  describe "what a member is not shown" do
    setup [:seed_world]

    test "no governance queue link and no operations link", %{conn: conn, member_token: token} do
      html = conn |> sign_in(token) |> get("/console") |> html_response(200)

      assert html =~ "Overview"
      refute html =~ "Governance queue"
      refute html =~ "System readiness"
      refute html =~ ~s|href="/console/operations"|
    end

    test "the operations page declines rather than crashing", %{conn: conn, member_token: token} do
      # The resources behind this page refuse a lesser role outright, so an
      # ungated render would raise. The redirect is the evidence that the gate
      # runs before the first query.
      assert redirected_to(conn |> sign_in(token) |> get("/console/operations")) == "/console"

      assert {:ok, member} = Identity.authenticate_bearer(token)
      assert_raise Ash.Error.Forbidden, fn -> Loader.operations(member) end
    end

    test "no retrieval diagnostic controls, and a hand-sent event is refused", %{
      conn: conn,
      member_token: token
    } do
      {:ok, view, html} = live(sign_in(conn, token), "/console/tools")

      assert html =~ "Tool workbench"
      refute html =~ "Retrieval diagnostic"
      refute html =~ ~s|name="strategies[]"|

      # The page not rendering a control is not the gate. An event sent by hand
      # has to be refused too, and the operation layer refuses it again.
      assert render_click(view, "toggle-diagnostic") =~ "for account administrators"

      html =
        render_submit(view, "run-diagnostic", %{
          "query" => "release",
          "scope_path" => "/console-test",
          "strategies" => ["lexical"]
        })

      assert html =~ "for account administrators"
      refute html =~ "Diagnostic result"

      assert {:ok, member} = Identity.authenticate_bearer(token)

      assert_raise Ash.Error.Forbidden, fn ->
        Memory.diagnostic_search(%{"scope_path" => "/", "query" => "release"}, member)
      end
    end

    test "the explorer offers no undecided lifecycle state as a filter", %{
      conn: conn,
      member_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      assert html =~ ~s|value="active"|
      refute html =~ ~s|value="proposed"|
      refute html =~ ~s|value="held"|
    end

    test "a scope the member holds no grant on is absent, not empty", %{
      conn: conn,
      member_token: token,
      statement: statement
    } do
      # The member in this world holds a role only on the root scope, with no
      # propagation, so `/console-test` is out of reach entirely. It must not
      # appear in the directory as an empty row: absent and empty are
      # deliberately indistinguishable from outside, and rendering the path
      # would disclose that the scope exists at all.
      directory = conn |> sign_in(token) |> get("/console/scopes") |> html_response(200)

      assert directory =~ "Directory"
      refute directory =~ "/console-test"

      explorer = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      refute explorer =~ statement

      workbench = conn |> sign_in(token) |> get("/console/tools") |> html_response(200)

      assert workbench =~ "Tool workbench"
      refute workbench =~ "/console-test"
    end

    test "co-mention neighbors include only readable scopes", %{
      conn: conn,
      admin: admin,
      member_id: member_id,
      member_token: member_token,
      knowledge_id: knowledge_id
    } do
      readable =
        ingest_statement!(
          admin,
          "console-shared-readable",
          "/console-test",
          "The release owner publishes the weekly checklist."
        )

      hidden =
        ingest_statement!(
          admin,
          "console-shared-hidden",
          "/console-hidden",
          "The private review also names the release owner."
        )

      activate_knowledge!(admin, [knowledge_id, readable.id, hidden.id])
      link_shared_entity!(admin, [knowledge_id, readable.id, hidden.id])
      admin = Identity.refresh_actor(admin)

      Identity.grant_role(admin, %{
        "scope_path" => "/console-test",
        "peer_id" => member_id,
        "role" => "reader",
        "propagate" => false
      })

      assert {:ok, member} = Identity.authenticate_bearer(member_token)
      detail = Loader.knowledge_detail(member, knowledge_id)

      assert detail.co_mentions_count == 1
      refute detail.co_mentions_truncated?
      assert Enum.map(detail.co_mentions, & &1.id) == [readable.id]

      html =
        conn
        |> sign_in(member_token)
        |> get("/console/knowledge/#{knowledge_id}")
        |> html_response(200)

      assert html =~ "Shared-entity neighbors"
      assert html =~ "Other statements"
      assert html =~ readable.statement
      refute html =~ hidden.statement
      refute html =~ "NeverRenderSharedEntity71"
    end
  end

  describe "the scoped graph" do
    setup [:seed_world]

    test "opens on the shallowest readable scope rather than the whole tree", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      statement: statement
    } do
      admin = Identity.refresh_actor(admin)
      data = Loader.graph(admin)

      assert data.focus.path == "/"
      assert data.parent == nil
      assert Enum.map(data.children, & &1.path) == ["/console-test"]
      # The child is a drill-down target, not a container: its statements belong
      # to the view you reach by entering it.
      assert data.knowledge == []

      html = conn |> sign_in(token) |> get("/console/graph") |> html_response(200)

      assert html =~ "This is the highest scope you can read."
      assert html =~ "Inside this scope:"
      refute html =~ statement
    end

    test "the focus travels in the URL and survives a reload", %{
      conn: conn,
      admin_token: token,
      statement: statement
    } do
      html =
        conn
        |> sign_in(token)
        |> get("/console/graph?scope=%2Fconsole-test")
        |> html_response(200)

      assert html =~ "Up to /"
      assert html =~ statement
    end

    test "drilling into a child and back up rewrites the URL", %{conn: conn, admin_token: token} do
      {:ok, view, _html} = live(sign_in(conn, token), "/console/graph")

      view
      |> element(".graph-children button[phx-value-scope='/console-test']")
      |> render_click()

      assert_patched(view, "/console/graph?scope=%2Fconsole-test")
      assert render(view) =~ "Up to /"

      view |> element("button", "Up to /") |> render_click()

      assert_patched(view, "/console/graph?scope=%2F")
      assert render(view) =~ "This is the highest scope you can read."
    end

    test "descendants are an explicit option, not the default", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      statement: statement
    } do
      admin = Identity.refresh_actor(admin)

      refute Loader.graph(admin).descendants?
      assert Loader.graph(admin, descendants?: true).descendants?

      html =
        conn
        |> sign_in(token)
        |> get("/console/graph?descendants=1")
        |> html_response(200)

      # The root holds no statement of its own; the subtree's statement appears
      # only because descendants were asked for.
      assert html =~ statement
    end

    test "a shared entity becomes an anonymous hub linking readable statements", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      knowledge_id: knowledge_id
    } do
      neighbor =
        ingest_statement!(
          admin,
          "console-graph-shared",
          "/console-test",
          "The release owner publishes the weekly checklist."
        )

      activate_knowledge!(admin, [knowledge_id, neighbor.id])
      link_shared_entity!(admin, [knowledge_id, neighbor.id])
      admin = Identity.refresh_actor(admin)

      data = Loader.graph(admin, scope: "/console-test")

      assert [cluster] = data.clusters
      assert cluster.label == "Shared entity 1"
      assert Enum.sort(cluster.knowledge_ids) == Enum.sort([knowledge_id, neighbor.id])
      refute data.clusters_truncated?
      # The ordinal is the whole identity a cluster has; nothing carries the
      # entity row it was grouped by.
      refute Map.has_key?(cluster, :entity_id)

      html =
        conn
        |> sign_in(token)
        |> get("/console/graph?scope=%2Fconsole-test")
        |> html_response(200)

      assert html =~ "node-cluster"
      assert html =~ "Shared entity 1"
      refute html =~ "NeverRenderSharedEntity71"
      refute html =~ "NeverRenderSharedSurface71"
    end

    test "a hub takes its name from the card, never from the entity row", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      knowledge_id: knowledge_id
    } do
      neighbor =
        ingest_statement!(
          admin,
          "console-graph-named",
          "/console-test",
          "The release owner publishes the weekly checklist."
        )

      activate_knowledge!(admin, [knowledge_id, neighbor.id])
      link_named_entity!(admin, [knowledge_id, neighbor.id], "release owner")
      admin = Identity.refresh_actor(admin)

      data = Loader.graph(admin, scope: "/console-test")

      assert [cluster] = data.clusters
      assert cluster.label == "release owner"
      assert cluster.labelled?
      # The label is the scope-local surface form. The entity row's own name is never read, and
      # the grouping coordinate still does not travel with the cluster.
      refute Map.has_key?(cluster, :entity_id)

      html =
        conn
        |> sign_in(token)
        |> get("/console/graph?scope=%2Fconsole-test")
        |> html_response(200)

      assert html =~ "release owner"
      refute html =~ "NeverRenderCanonical72"
    end

    test "the graph renders its empty state for a peer who holds no grant", %{
      conn: conn,
      admin: admin
    } do
      # `focus` is nil for this actor, and the page has a dedicated state for it. Anything in the
      # loader that dereferences focus without a nil clause turns that state into a 500.
      token = create_ungranted_peer!(admin)

      html =
        conn
        |> sign_in(token)
        |> get("/console/graph")
        |> html_response(200)

      assert html =~ "You hold no grant on any scope"
    end

    test "a cluster is described by the card in the scope its statements live in", %{
      admin: admin,
      knowledge_id: knowledge_id
    } do
      # Cards exist per scope and the drawn set is the focus plus its descendants, never its
      # ancestors. A cluster whose statements sit in a child scope must still find its own card.
      child =
        ingest_statement!(
          admin,
          "console-graph-child",
          "/console-test/child",
          "The release owner signs off the child rollout."
        )

      sibling =
        ingest_statement!(
          admin,
          "console-graph-child",
          "/console-test/child",
          "The release owner reviews the child runbook."
        )

      activate_knowledge!(admin, [knowledge_id, child.id, sibling.id])
      link_named_entity!(admin, [child.id, sibling.id], "release owner")
      admin = Identity.refresh_actor(admin)

      data = Loader.graph(admin, scope: "/console-test", descendants?: true)

      assert [cluster] = data.clusters
      assert cluster.label == "release owner"
      assert Enum.sort(cluster.knowledge_ids) == Enum.sort([child.id, sibling.id])
    end

    test "selecting a named hub shows its card and separates what the summary covers", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      knowledge_id: knowledge_id
    } do
      neighbor =
        ingest_statement!(
          admin,
          "console-graph-panel",
          "/console-test",
          "The release owner publishes the weekly checklist."
        )

      third =
        ingest_statement!(
          admin,
          "console-graph-panel",
          "/console-test",
          "The release owner signs off each deploy."
        )

      activate_knowledge!(admin, [knowledge_id, neighbor.id, third.id])
      link_named_entity!(admin, [knowledge_id, neighbor.id, third.id], "release owner")
      admin = Identity.refresh_actor(admin)

      data = Loader.graph(admin, scope: "/console-test")
      assert [cluster] = data.clusters

      {:ok, view, _html} = live(conn |> sign_in(token), "/console/graph?scope=%2Fconsole-test")

      html =
        view
        |> element("g.node-cluster[phx-value-id='#{cluster.id}']")
        |> render_click()

      assert html =~ "release owner"
      assert html =~ "kind-concept"
      assert html =~ "Summary"
      # Three sources, so the deterministic provider extracted rather than invented.
      assert html =~ "extracted from the sources"
      assert html =~ "Summarised"
      # Every member is a card source here, so the second list must not appear at all.
      refute html =~ "Not in the summary"
    end

    test "an unnamed hub shows neither a summary nor the two member lists", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      knowledge_id: knowledge_id
    } do
      neighbor =
        ingest_statement!(
          admin,
          "console-graph-plain",
          "/console-test",
          "The release owner publishes the weekly checklist."
        )

      activate_knowledge!(admin, [knowledge_id, neighbor.id])
      link_shared_entity!(admin, [knowledge_id, neighbor.id])
      admin = Identity.refresh_actor(admin)

      data = Loader.graph(admin, scope: "/console-test")
      assert [cluster] = data.clusters
      refute cluster.labelled?

      {:ok, view, _html} = live(conn |> sign_in(token), "/console/graph?scope=%2Fconsole-test")

      html =
        view
        |> element("g.node-cluster[phx-value-id='#{cluster.id}']")
        |> render_click()

      assert html =~ "Shared entity 1"
      assert html =~ "waiting to be rebuilt"
      refute html =~ "Summarised"
      refute html =~ "Not in the summary"
      refute html =~ "NeverRenderSharedSurface71"
    end

    test "two entities named in one statement join their hubs", %{
      admin: admin,
      knowledge_id: knowledge_id
    } do
      second =
        ingest_statement!(
          admin,
          "console-graph-comention",
          "/console-test",
          "The release owner keeps the deploy calendar."
        )

      third =
        ingest_statement!(
          admin,
          "console-graph-comention",
          "/console-test",
          "The billing service bills on the deploy calendar."
        )

      activate_knowledge!(admin, [knowledge_id, second.id, third.id])

      # Distinct membership sets, so neither group is collapsed, and both share the first
      # statement, which is what makes them co-mentioned.
      link_named_entities!(admin, [
        {"release owner", [knowledge_id, second.id]},
        {"deploy calendar", [second.id, third.id]}
      ])

      admin = Identity.refresh_actor(admin)
      data = Loader.graph(admin, scope: "/console-test")

      assert length(data.clusters) == 2
      assert Enum.all?(data.clusters, & &1.labelled?)
      assert [{source, target}] = data.cluster_edges
      assert source != target
      assert Enum.sort([source, target]) == Enum.sort(Enum.map(data.clusters, & &1.id))

      # The edge carries ordinals, never the grouping coordinate it was resolved through.
      refute data |> inspect() |> String.contains?("entity_id")
    end

    test "an unnamed hub takes no co-mention edge", %{
      admin: admin,
      knowledge_id: knowledge_id
    } do
      # An unnamed hub is either a collapsed group or one with no usable card. Joining it would
      # let a reader count the entities inside it by counting the lines leaving it, which is
      # exactly what the collapse prevents.
      second =
        ingest_statement!(
          admin,
          "console-graph-unnamed",
          "/console-test",
          "The release owner keeps the deploy calendar."
        )

      third =
        ingest_statement!(
          admin,
          "console-graph-unnamed",
          "/console-test",
          "The billing service bills on the deploy calendar."
        )

      activate_knowledge!(admin, [knowledge_id, second.id, third.id])

      # No refresh runs, so neither group has a card and neither hub is named.
      DataLayer.with_actor(admin, fn account, actor ->
        pipeline = pipeline_actor(actor)

        Enum.each(
          [
            {"release owner", [knowledge_id, second.id]},
            {"deploy calendar", [second.id, third.id]}
          ],
          fn {form, ids} ->
            entity =
              create!(
                Entity,
                :create_from_pipeline,
                %{
                  canonical_name: "NeverRenderCanonical-#{form}",
                  kind: "concept",
                  aliases: [form],
                  derived_from: ids
                },
                account.id,
                pipeline
              )

            Enum.each(ids, &create_mention!(account.id, pipeline, &1, entity.id, form))
          end
        )
      end)

      admin = Identity.refresh_actor(admin)
      data = Loader.graph(admin, scope: "/console-test")

      assert length(data.clusters) == 2
      refute Enum.any?(data.clusters, & &1.labelled?)
      assert data.cluster_edges == []
    end

    test "a peer profile in a drawn scope never reaches the graph payload", %{
      admin: admin,
      knowledge_id: knowledge_id
    } do
      # `Knowledge.Projection` authorizes reads on `scope_id` alone and filters neither kind nor
      # peer, so the graph's own `kind` filter is the only thing keeping another subject's
      # provisional slice out of this payload. Drop it and this sentinel appears.
      neighbor =
        ingest_statement!(
          admin,
          "console-graph-peer",
          "/console-test",
          "The release owner publishes the weekly checklist."
        )

      activate_knowledge!(admin, [knowledge_id, neighbor.id])
      link_named_entity!(admin, [knowledge_id, neighbor.id], "release owner")
      seed_peer_profile!(admin, "/console-test", "NeverRenderPeerProfile73")
      admin = Identity.refresh_actor(admin)

      rendered = admin |> Loader.graph(scope: "/console-test") |> inspect()

      assert rendered =~ "release owner"
      refute rendered =~ "NeverRenderPeerProfile73"
    end

    test "a hub never reaches a statement outside the drawn scope", %{
      conn: conn,
      admin: admin,
      admin_token: token,
      knowledge_id: knowledge_id
    } do
      hidden =
        ingest_statement!(
          admin,
          "console-graph-hidden",
          "/console-hidden",
          "The private review also names the release owner."
        )

      activate_knowledge!(admin, [knowledge_id, hidden.id])
      link_shared_entity!(admin, [knowledge_id, hidden.id])
      admin = Identity.refresh_actor(admin)

      # Both statements share an entity and the admin may read both, but only
      # one is in the drawn scope. A cluster of one member is not a
      # relationship, so nothing is drawn rather than a hub with a stub line.
      assert Loader.graph(admin, scope: "/console-test").clusters == []

      html =
        conn
        |> sign_in(token)
        |> get("/console/graph?scope=%2Fconsole-test")
        |> html_response(200)

      refute html =~ hidden.statement
    end

    test "a member sees only the scope they hold and no path they do not", %{
      conn: conn,
      member_token: member_token
    } do
      assert {:ok, member} = Identity.authenticate_bearer(member_token)
      data = Loader.graph(member)

      assert data.focus.path == "/"
      assert data.children == []
      assert data.knowledge == []

      # An unauthorized path in the URL narrows to a readable scope rather than
      # widening, and never reports whether the requested path exists.
      assert Loader.graph(member, scope: "/console-test").focus.path == "/"

      html =
        conn
        |> sign_in(member_token)
        |> get("/console/graph?scope=%2Fconsole-test")
        |> html_response(200)

      refute html =~ "/console-test"
      assert html =~ "No scope below this one is readable"
    end

    test "a truncated scope says so and points at the explorer", %{
      conn: conn,
      admin: admin,
      admin_token: token
    } do
      admin = Identity.refresh_actor(admin)

      ingest_statement!(
        admin,
        "console-graph-second",
        "/console-test",
        "The release owner publishes the weekly checklist."
      )

      data = Loader.graph(admin, scope: "/console-test", limit: 1)

      assert data.shown == 1
      assert data.total == 2
      assert data.truncated?

      html =
        conn
        |> sign_in(token)
        |> get("/console/graph?scope=%2Fconsole-test")
        |> html_response(200)

      # The page's own cap is far above two statements, so this render is the
      # honest untruncated case and must not claim otherwise. The route out to
      # the explorer is offered either way, because a graph is never the
      # complete list.
      refute html =~ "most confident first"
      assert html =~ "Open this scope in the explorer"
      assert html =~ "/console/knowledge?scope=%2Fconsole-test"
    end
  end

  describe "the knowledge explorer" do
    setup [:seed_world]

    test "browse is the default mode and runs no retrieval", %{conn: conn, admin_token: token} do
      html = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      assert html =~ "Browse"
      assert html =~ "Find"
      # Browsing must never issue a search: the two modes answer different
      # questions and one of them costs a retrieval run.
      refute html =~ "Retrieval preview"
      assert html =~ "Statements"
    end

    test "find mode runs retrieval once a scope is chosen", %{conn: conn, admin_token: token} do
      html =
        conn
        |> sign_in(token)
        |> get("/console/knowledge?mode=find&q=standups&scope=%2Fconsole-test")
        |> html_response(200)

      assert html =~ "Retrieval preview"
      assert html =~ "Strategies used"
      # The exhaustive list stays reachable underneath, because a ranking miss
      # is not proof the memory is empty.
      assert html =~ "Exhaustive list"
    end

    test "a query with no scope says so instead of listing silently", %{
      conn: conn,
      admin_token: token
    } do
      html =
        conn
        |> sign_in(token)
        |> get("/console/knowledge?mode=find&q=standups")
        |> html_response(200)

      refute html =~ "Retrieval preview"
      assert html =~ "Retrieval needs a scope"
    end

    test "active filters are summarized and clearable", %{conn: conn, admin_token: token} do
      html =
        conn
        |> sign_in(token)
        |> get("/console/knowledge?scope=%2Fconsole-test&state=active")
        |> html_response(200)

      assert html =~ "Active filters"
      assert html =~ "filter-chip"
      assert html =~ "Clear all"
      # Each chip removes only itself, so the other filter survives its link.
      assert html =~ "state=active"
    end

    test "the scope control offers typeahead over authorized paths only", %{
      conn: conn,
      admin_token: admin_token,
      member_token: member_token
    } do
      html = conn |> sign_in(admin_token) |> get("/console/knowledge") |> html_response(200)

      assert html =~ ~s|list="console-scope-paths"|
      assert html =~ ~s|<datalist id="console-scope-paths">|
      assert html =~ ~s|value="/console-test"|

      member = build_conn() |> sign_in(member_token) |> get("/console/knowledge")

      refute html_response(member, 200) =~ ~s|value="/console-test"|
    end

    test "page size, sort, and an out-of-range page are all bounded", %{admin: admin} do
      # The bootstrap actor predates the scope ingest created, so it must be
      # refreshed before it can read anything inside it.
      admin = Identity.refresh_actor(admin)

      assert %{page_size: 25, sort: "confidence", page: 1} =
               Loader.knowledge_list(admin, %{})

      assert %{page_size: 100} = Loader.knowledge_list(admin, %{"per_page" => "100"})

      # A hand-typed size would turn a browsing surface into an export.
      assert %{page_size: 25} = Loader.knowledge_list(admin, %{"per_page" => "5000"})
      assert %{page_size: 25} = Loader.knowledge_list(admin, %{"per_page" => "not a number"})

      assert %{sort: "recorded"} = Loader.knowledge_list(admin, %{"sort" => "recorded"})
      assert %{sort: "confidence"} = Loader.knowledge_list(admin, %{"sort" => "id; drop table"})

      # A deep link outlives the filters it was written against.
      assert %{page: 1, page_count: 1} = Loader.knowledge_list(admin, %{"page" => "99"})
    end

    test "a scope filter reports how much it contains", %{admin: admin} do
      admin = Identity.refresh_actor(admin)

      assert %{descendant_count: nil, filtered?: false} = Loader.knowledge_list(admin, %{})

      assert %{descendant_count: 0, filtered?: true} =
               Loader.knowledge_list(admin, %{"scope" => "/console-test"})

      # The root contains `/console-test`, and a scope filter takes the whole
      # subtree with it.
      assert %{descendant_count: 1} = Loader.knowledge_list(admin, %{"scope" => "/"})
    end

    test "an empty result says which kind of empty it is", %{conn: conn, member_token: token} do
      # The member holds a non-propagating root grant, so they can read nothing
      # inside `/console-test` and their unfiltered explorer is genuinely empty.
      unfiltered = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      assert unfiltered =~ "You can read no statements at all yet"

      filtered =
        build_conn()
        |> sign_in(token)
        |> get("/console/knowledge?kind=preference")
        |> html_response(200)

      assert filtered =~ "Nothing matches these filters"
    end

    test "lifecycle and sensitivity are labelled, not colour-only", %{
      conn: conn,
      admin_token: token
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge") |> html_response(200)

      assert html =~ "badge-glyph"
      assert html =~ "What these labels mean"
      # Enum spelling belongs to the machine; the reader gets prose.
      assert html =~ "Needs revalidation"
      refute html =~ ">needs_revalidation<"
    end
  end

  describe "the statement page" do
    setup [:seed_world]

    test "the statement and the available actions lead the page", %{
      conn: conn,
      admin_token: token,
      knowledge_id: id,
      statement: statement
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge/#{id}") |> html_response(200)

      assert html =~ "What you can do"

      # Order is the point of this page: the claim and what to do about it must
      # come before the evidence that produced it.
      assert index(html, statement) < index(html, "What you can do")
      assert index(html, "What you can do") < index(html, "Provenance")
      assert index(html, "Provenance") < index(html, "How this was produced")
    end

    test "pipeline and gate metadata stay behind one disclosure", %{
      conn: conn,
      admin_token: token,
      knowledge_id: id
    } do
      html = conn |> sign_in(token) |> get("/console/knowledge/#{id}") |> html_response(200)

      assert html =~ ~s|<details class="technical">|
      assert index(html, ~s|<details class="technical">|) < index(html, "How this was produced")
    end

    test "an unavailable action explains itself rather than vanishing", %{
      conn: conn,
      admin: admin,
      member_id: member_id,
      member_token: member_token,
      knowledge_id: id
    } do
      # A provisional statement is visible to its subject alone, so it has to
      # settle before a reader can be shown the empty-action explanation.
      activate_knowledge!(admin, [id])
      admin = Identity.refresh_actor(admin)

      Identity.grant_role(admin, %{
        "scope_path" => "/console-test",
        "peer_id" => member_id,
        "role" => "reader",
        "propagate" => false
      })

      html =
        conn |> sign_in(member_token) |> get("/console/knowledge/#{id}") |> html_response(200)

      assert html =~ "What you can do"
      assert html =~ "belong to the subject of a statement"
    end

    test "the list link and the return link preserve filters", %{
      conn: conn,
      admin_token: token,
      knowledge_id: id
    } do
      list =
        conn
        |> sign_in(token)
        |> get("/console/knowledge?scope=%2Fconsole-test")
        |> html_response(200)

      assert list =~ "back=scope"

      detail =
        build_conn()
        |> sign_in(token)
        |> get("/console/knowledge/#{id}?back=#{URI.encode_www_form("scope=/console-test")}")
        |> html_response(200)

      assert detail =~ "Back to the list"
      assert detail =~ "/console/knowledge?scope=%2Fconsole-test"
    end

    test "a foreign return value cannot leave the explorer", %{
      conn: conn,
      admin_token: token,
      knowledge_id: id
    } do
      html =
        conn
        |> sign_in(token)
        |> get(
          "/console/knowledge/#{id}?back=" <>
            URI.encode_www_form("redirect=https://evil.test/&scope=/console-test")
        )
        |> html_response(200)

      # Only the explorer's own filter keys survive, so `back` can name no
      # destination outside it.
      refute html =~ "evil.test"
      assert html =~ "/console/knowledge?scope=%2Fconsole-test"
    end
  end

  # ----------------------------------------------------------------------------
  # World
  # ----------------------------------------------------------------------------

  # Byte offset of the first occurrence, for asserting page order.
  defp index(html, needle) do
    case :binary.match(html, needle) do
      {start, _length} -> start
      :nomatch -> flunk("expected the page to contain #{inspect(needle)}")
    end
  end

  # One Account holding a real administrator, a real member, one ingested
  # observation, and the statement extracted from it. Everything is created
  # through the ordinary paths — bootstrap, ingest, role grant — so the test
  # exercises the same code a running deployment does.
  defp seed_world(%{conn: _conn} = context) do
    %{actor: admin, token: admin_token} = bootstrap_admin!()

    observation = "Avery prefers asynchronous standups."

    {:ok, message} =
      Memory.ingest_message(
        %{
          "session_id" => "console-session",
          "scope_path" => "/console-test",
          "role" => "user",
          "content" => observation
        },
        admin
      )

    {:ok, [knowledge]} =
      Memory.extract_message_for_account(message["id"], admin.account_id)

    %{id: member_id, token: member_token} = create_member!(admin)

    Map.merge(context, %{
      admin: admin,
      admin_token: admin_token,
      member_id: member_id,
      member_token: member_token,
      observation: observation,
      knowledge_id: Map.fetch!(knowledge, "id"),
      statement: Map.fetch!(knowledge, "statement")
    })
  end

  defp bootstrap_admin! do
    Identity.bootstrap_human(%{
      email: "admin@example.test",
      name: "Console Admin",
      password: @password
    })
  end

  defp load_knowledge!(admin, knowledge_id, opts) do
    DataLayer.with_actor(admin, fn account, actor ->
      KnowledgeItem
      |> Ash.Query.filter(id == ^knowledge_id)
      |> Ash.Query.select(Keyword.fetch!(opts, :select))
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)
    end)
  end

  defp statement_for(admin, knowledge_id) do
    load_knowledge!(admin, knowledge_id, select: [:statement]).statement
  end

  defp configured_embedding_identity(admin) do
    :embedder
    |> MemHouse.Model.Config.resolve(%{account_id: admin.account_id, actor: admin})
    |> MemHouse.Model.Config.embedding_identity()
  end

  defp index_knowledge!(admin, item, identity) do
    embedding = item.embedding || List.duplicate(0.001, identity.dimensions)

    DataLayer.with_actor(admin, fn account, actor ->
      item
      |> Ash.Changeset.for_update(:index_from_pipeline, %{
        embedding: embedding,
        embedding_provider: identity.provider,
        embedding_model: identity.model,
        embedding_version: identity.version,
        embedding_dimensions: identity.dimensions
      })
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.update!(actor: pipeline_actor(actor))
    end)
  end

  # Registers a second person with a password credential and grants them the
  # member role at the root without propagation, then signs them in and returns
  # their token.
  #
  # A non-propagating grant is what makes this peer a useful test subject: they
  # can open the console, and they can reach nothing inside `/console-test`. A
  # propagating grant would hide the difference between "no access" and "no
  # rows".
  defp create_member!(admin) do
    peer_id =
      DataLayer.with_actor(admin, fn account, actor ->
        peer =
          Peer
          |> Ash.Changeset.new()
          |> Ash.Changeset.set_tenant(account.id)
          |> Ash.Changeset.for_create(:register_with_password, %{
            key: "console-member",
            name: "Console Member",
            kind: "human",
            email: "member@example.test",
            password: @password,
            password_confirmation: @password
          })
          |> Ash.create!(actor: Actor.for_account(account, role: :system))

        ExternalIdentity
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:create, %{
          peer_id: peer.id,
          provider: "password",
          subject: "member@example.test",
          email: "member@example.test",
          assurance: "medium",
          linked_at: Clock.utc_now(),
          active: true
        })
        |> Ash.create!(actor: actor)

        peer.id
      end)

    Identity.grant_role(admin, %{
      "scope_path" => "/",
      "peer_id" => peer_id,
      "role" => "member",
      "propagate" => false
    })

    {:ok, %{token: token}} = Identity.sign_in_password("member@example.test", @password)
    %{id: peer_id, token: token}
  end

  # A password peer with no role grant at all. They authenticate, so every console page must
  # render its empty state for them rather than raise.
  defp create_ungranted_peer!(admin) do
    DataLayer.with_actor(admin, fn account, actor ->
      peer =
        Peer
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:register_with_password, %{
          key: "console-ungranted",
          name: "Console Ungranted",
          kind: "human",
          email: "ungranted@example.test",
          password: @password,
          password_confirmation: @password
        })
        |> Ash.create!(actor: Actor.for_account(account, role: :system))

      ExternalIdentity
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(account.id)
      |> Ash.Changeset.for_create(:create, %{
        peer_id: peer.id,
        provider: "password",
        subject: "ungranted@example.test",
        email: "ungranted@example.test",
        assurance: "medium",
        linked_at: Clock.utc_now(),
        active: true
      })
      |> Ash.create!(actor: actor)

      peer.id
    end)

    {:ok, %{token: token}} = Identity.sign_in_password("ungranted@example.test", @password)
    token
  end

  defp seed_resolution_metrics!(admin, knowledge_id) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      first =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "NeverRenderAlias71",
            kind: "person",
            aliases: ["NeverRenderAlias71", "NRA71"],
            derived_from: [knowledge_id]
          },
          account.id,
          pipeline
        )

      second =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "NeverRenderSingleton71",
            kind: "concept",
            aliases: ["NeverRenderSingleton71"],
            derived_from: [knowledge_id]
          },
          account.id,
          pipeline
        )

      create_mention!(account.id, pipeline, knowledge_id, first.id, "NeverRenderAlias71")
      create_mention!(account.id, pipeline, knowledge_id, first.id, "NRA71")
      create_mention!(account.id, pipeline, knowledge_id, second.id, "NeverRenderSingleton71")
    end)
  end

  defp ingest_statement!(admin, session_id, scope_path, content) do
    {:ok, message} =
      Memory.ingest_message(
        %{
          "session_id" => session_id,
          "scope_path" => scope_path,
          "role" => "user",
          "content" => content
        },
        admin
      )

    {:ok, [knowledge]} =
      Memory.extract_message_for_account(message["id"], admin.account_id)

    knowledge
    |> then(&%{id: Map.fetch!(&1, "id"), statement: Map.fetch!(&1, "statement")})
  end

  defp activate_knowledge!(admin, knowledge_ids) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      Enum.each(knowledge_ids, fn knowledge_id ->
        item =
          KnowledgeItem
          |> Ash.Query.filter(id == ^knowledge_id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: pipeline)

        if item.state != "active" do
          GovernanceEngine.transition!(
            item,
            pipeline,
            %{state: "active", verification: "auto_verified"},
            reason: "console_entity_observability_test",
            channel: "pipeline"
          )
        end
      end)
    end)
  end

  defp link_shared_entity!(admin, knowledge_ids) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      entity =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "NeverRenderSharedEntity71",
            kind: "concept",
            aliases: ["NeverRenderSharedEntity71"],
            derived_from: knowledge_ids
          },
          account.id,
          pipeline
        )

      knowledge_ids
      |> Enum.with_index()
      |> Enum.each(fn {knowledge_id, index} ->
        create_mention!(
          account.id,
          pipeline,
          knowledge_id,
          entity.id,
          "NeverRenderSharedSurface71-#{index}"
        )
      end)
    end)
  end

  # A peer-profile projection standing in for another subject's provisional slice. It is given
  # the *same* entity id as the scope's real entity card on purpose: that is what makes the
  # loader's `kind` filter load-bearing rather than decorative. Without the filter both rows land
  # under one `{scope, entity}` key and the sentinel can win.
  defp seed_peer_profile!(admin, scope_path, sentinel) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      scope =
        Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)

      card =
        Projection
        |> Ash.Query.filter(scope_id == ^scope.id and kind == "entity_card")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: pipeline)
        |> List.first()

      refute is_nil(card), "fixture needs an entity card before seeding the collision"

      create!(
        Projection,
        :upsert_from_pipeline,
        %{
          cache_key: "peer:#{scope.id}:sentinel",
          scope_id: scope.id,
          peer_id: admin.peer_id,
          entity_id: card.entity_id,
          kind: "peer_profile",
          content: %{
            "label" => sentinel,
            "summary" => sentinel,
            "knowledge" => [%{"id" => Ash.UUID.generate(), "statement" => sentinel}]
          },
          source_ids: []
        },
        account.id,
        pipeline
      )
    end)
  end

  # Links the statements through one entity that every mention spells the same way, then builds
  # the projections. The shared spelling is what gives the card a label; `link_shared_entity!`
  # deliberately varies its forms and produces a card with a lexically-chosen one.
  # Links several entities in one pass, each with its own spelling and its own statement set, then
  # builds the projections once. `link_named_entity!` refreshes per call, which is fine for one
  # entity and wrong for a co-mention fixture: the entities have to exist together before the
  # cards are built.
  defp link_named_entities!(admin, specs) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      Enum.each(specs, fn {surface_form, knowledge_ids} ->
        entity =
          create!(
            Entity,
            :create_from_pipeline,
            %{
              canonical_name: "NeverRenderCanonical-#{surface_form}",
              kind: "concept",
              aliases: [surface_form],
              derived_from: knowledge_ids
            },
            account.id,
            pipeline
          )

        Enum.each(
          knowledge_ids,
          &create_mention!(account.id, pipeline, &1, entity.id, surface_form)
        )
      end)

      {_form, ids} = hd(specs)

      scope_id =
        KnowledgeItem
        |> Ash.Query.filter(id == ^hd(ids))
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)
        |> Map.fetch!(:scope_id)

      MemHouse.Context.Builder.refresh_scope(account.id, scope_id)
    end)
  end

  defp link_named_entity!(admin, knowledge_ids, surface_form) do
    DataLayer.with_actor(admin, fn account, actor ->
      pipeline = pipeline_actor(actor)

      entity =
        create!(
          Entity,
          :create_from_pipeline,
          %{
            canonical_name: "NeverRenderCanonical72",
            kind: "person",
            aliases: [surface_form],
            derived_from: knowledge_ids
          },
          account.id,
          pipeline
        )

      Enum.each(
        knowledge_ids,
        &create_mention!(account.id, pipeline, &1, entity.id, surface_form)
      )

      scope_id =
        KnowledgeItem
        |> Ash.Query.filter(id == ^hd(knowledge_ids))
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline)
        |> Map.fetch!(:scope_id)

      MemHouse.Context.Builder.refresh_scope(account.id, scope_id)
    end)
  end

  defp create_mention!(account_id, actor, knowledge_id, entity_id, surface_form) do
    knowledge =
      KnowledgeItem
      |> Ash.Query.filter(id == ^knowledge_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    create!(
      EntityMention,
      :create_from_pipeline,
      %{
        knowledge_item_id: knowledge.id,
        scope_id: knowledge.scope_id,
        entity_id: entity_id,
        surface_form: surface_form,
        confidence: 1.0
      },
      account_id,
      actor
    )
  end

  defp pipeline_actor(%Actor{} = actor),
    do: %{actor | role: :system, scope_ids: :all, pipeline?: true}

  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  # The copyable request block alone, so an export assertion cannot be satisfied
  # by something else the page happens to render.
  defp diagnostic_request(html) do
    [_match, json] = Regex.run(~r|<pre id="diagnostic-request"[^>]*>(.*?)</pre>|s, html)
    json
  end

  defp sign_in(conn, token), do: init_test_session(conn, governance_token: token)
end
