# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.MemoryControllerTest do
  @moduledoc """
  The frozen behaviour baseline for the JSON HTTP surface.

    Several literals asserted below — `"f5-1"` for the extraction and pipeline
    behaviour, `"f7-1"` for retrieval and context behaviour — are contract identities,
    not the application's semantic version. They tell a client which behaviour it is
    talking to and they do not move when the app version does.
  """

  use MemHouseWeb.ConnCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Governance.McpTools
  alias MemHouse.Identity
  alias MemHouse.Memory
  alias MemHouse.Model.GroundedAnswerProvider
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Repo

  require Ash.Query

  setup do
    # Remove any model credential the developer's shell or the loaded config
    # might supply, so nothing below can reach a live endpoint. The test
    # environment already resolves the generation roles to the local
    # deterministic provider at boot; this only makes sure a stray key cannot
    # undo that. Both values are restored on exit so the next test sees the
    # machine it expected.
    original_api_key = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:memhouse, :models)
    original_provider = Application.get_env(:memhouse, :model_provider)

    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:memhouse, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      GroundedAnswerProvider.stop()

      if original_api_key do
        System.put_env("OPENROUTER_API_KEY", original_api_key)
      else
        System.delete_env("OPENROUTER_API_KEY")
      end

      Application.put_env(:memhouse, :models, original_models)

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    # Creates the single community Account, its root scope, an administrator
    # peer with a propagating grant at that root, and a sign-in token. Without
    # the root grant the new administrator would be authorized for nothing,
    # because authority over a scope is inherited downward from an ancestor.
    # The token is the credential every authenticated request below presents;
    # the actor is used only for seeding, which goes through the domain rather
    # than HTTP.
    bootstrap =
      Identity.bootstrap_human(%{
        email: "admin@example.test",
        name: "Test Admin",
        password: "correct horse battery staple"
      })

    {:ok, actor: bootstrap.actor, token: bootstrap.token}
  end

  # Deliberately sent without a credential: the liveness probe must answer
  # before any identity exists, so an orchestrator can tell a starting
  # container from a wedged one. It also touches no database, which is why
  # container liveness should point here and readiness elsewhere — wiring
  # liveness to database checks turns a brief database blip into a restart
  # loop.
  test "GET /api/health freezes the POC health contract", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    # "f5-1" names the extraction and pipeline behaviour this build implements,
    # so a client can discover which extractor it is talking to. It is a
    # contract identity, not the release version, and does not change when the
    # application version does.
    assert %{"status" => "ok", "app" => "memhouse", "version" => "f5-1"} =
             json_response(conn, 200)

    assert_trace_id(conn)
  end

  test "GET /api/ready reports the matching embedding index", %{conn: conn} do
    conn = get(conn, ~p"/api/ready")

    assert %{
             "status" => "ready",
             "checks" => %{
               "model_calls" => %{
                 "status" => "ok",
                 "window_seconds" => 86_400,
                 "attempts" => 0,
                 "errors" => 0,
                 "unmetered" => 0,
                 "error_classes" => %{}
               },
               "embedding_index" => %{
                 "status" => "ok",
                 "configured_dimensions" => 1024,
                 "indexed_dimensions" => [1024]
               }
             },
             "governance" => %{
               "unattended" => false,
               "status" => "ok",
               "pending_human_reviews" => 0,
               "restricted_withheld" => 0
             }
           } = json_response(conn, 200)

    assert get_in(json_response(conn, 200), ["checks", "model_calls", "error_rate"]) == 0.0

    assert_trace_id(conn)
  end

  test "GET /api/ready reports an embedding-index mismatch without sensitive data", %{conn: conn} do
    original_roles = Application.fetch_env!(:memhouse, :model_roles)

    roles =
      Keyword.update!(original_roles, :embedder, fn config ->
        Map.put(config, :embedding_dimensions, 384)
      end)

    Application.put_env(:memhouse, :model_roles, roles)
    on_exit(fn -> Application.put_env(:memhouse, :model_roles, original_roles) end)

    conn = get(conn, ~p"/api/ready")

    assert %{
             "status" => "not_ready",
             "checks" => %{
               "embedding_index" => %{
                 "status" => "error",
                 "configured_dimensions" => 384,
                 "indexed_dimensions" => [1024]
               }
             }
           } = json_response(conn, 503)

    assert_trace_id(conn)
  end

  # The only write path an agent has. Note that the scope path in the body does
  # not exist yet: missing scopes, the session, and their links are created on
  # demand, so a client never has to provision topology before speaking.
  test "POST /api/v1/ingest accepts before extraction and exposes status", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    conn =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/ingest", ingest_attrs("ingest-session", "/contract/http/ingest"))

    assert %{"data" => %{"message_id" => message_id, "status" => "accepted"}} =
             json_response(conn, 202)

    refute Map.has_key?(json_response(conn, 202)["data"], "knowledge")
    assert extractor_usage_count(actor.account_id) == 0

    pending =
      conn
      |> recycle()
      |> with_identity(token)
      |> get(~p"/api/v1/ingest/#{message_id}")

    assert %{
             "data" => %{
               "message_id" => ^message_id,
               "status" => "pending",
               "extraction_completed_at" => nil,
               "knowledge" => [],
               "last_error_class" => nil,
               "attempt_count" => 0
             }
           } = json_response(pending, 200)

    restricted_actor = %{actor | role: :reader, scope_ids: []}
    assert {:error, :not_found} = Memory.ingest_status(message_id, restricted_actor)

    assert {:ok, [_knowledge]} = Memory.extract_message_for_account(message_id, actor.account_id)
    assert extractor_usage_count(actor.account_id) == 1

    completed =
      pending
      |> recycle()
      |> with_identity(token)
      |> get(~p"/api/v1/ingest/#{message_id}")

    assert %{
             "data" => %{
               "message_id" => ^message_id,
               "status" => "completed",
               "extraction_completed_at" => completed_at,
               "knowledge" => [
                 %{
                   "statement" => "Avery prefers concise weekly release summaries.",
                   "pipeline_version" => "f5-1"
                 }
               ],
               "last_error_class" => nil,
               "attempt_count" => 0
             }
           } = json_response(completed, 200)

    assert is_binary(completed_at)

    assert_trace_id(conn)
  end

  test "GET /api/v1/ingest/:message_id returns opaque 404 for an invalid id", %{
    conn: conn,
    token: token
  } do
    conn =
      conn
      |> with_identity(token)
      |> get("/api/v1/ingest/not-a-uuid")

    assert %{"error" => "Not found"} = json_response(conn, 404)
  end

  test "MCP ingest accepts without invoking the extractor", %{actor: actor} do
    input =
      Ash.ActionInput.for_action(McpTools, :ingest, %{
        session_id: "mcp-ingest-session",
        scope_path: "/contract/mcp/ingest",
        role: "user",
        content: "Avery prefers concise weekly release summaries."
      })

    assert {:ok, %{"message_id" => message_id, "status" => "accepted"}} =
             Ash.run_action(input, actor: actor)

    assert is_binary(message_id)
    assert extractor_usage_count(actor.account_id) == 0
  end

  test "POST /api/v1/operations/reconcile enqueues an Account sweep", %{
    conn: conn,
    token: token
  } do
    conn =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/operations/reconcile")

    assert %{"data" => %{"run_id" => run_id, "status" => "accepted"}} =
             json_response(conn, 202)

    assert %{rows: [["reconciler", "pending"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT kind, status FROM pipeline_runs WHERE id = $1",
               [Ecto.UUID.dump!(run_id)]
             )
  end

  test "POST /api/v1/operations/ingest/:id/requeue explicitly repairs a terminal anchor", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    assert {:ok, message} =
             Memory.ingest_message(
               ingest_attrs("repair-session", "/contract/http/repair"),
               actor
             )

    run = extraction_run!(actor, message["id"])

    # Test-only fixture setup: the completed anchor has no live batch claim, so the
    # governed production transition correctly refuses to classify it.
    Ash.Seed.update!(
      run,
      %{status: "terminal", last_error_class: "structured_validation_exhausted"},
      tenant: actor.account_id
    )

    member =
      Identity.provision_agent(actor, %{
        "key" => "requeue-member",
        "scope_path" => "/",
        "role" => "member"
      })

    denied =
      conn
      |> with_identity(member.api_key)
      |> post(~p"/api/v1/operations/ingest/#{message["id"]}/requeue")

    assert %{"error" => "Forbidden"} = json_response(denied, 403)

    assert %{status: "terminal", last_error_class: "structured_validation_exhausted"} =
             extraction_run!(actor, message["id"])

    response =
      denied
      |> recycle()
      |> with_identity(token)
      |> post(~p"/api/v1/operations/ingest/#{message["id"]}/requeue")

    assert %{"data" => %{"run_id" => run_id, "status" => "accepted"}} =
             json_response(response, 202)

    assert %{id: ^run_id, status: "pending", last_error_class: nil} =
             extraction_run!(actor, message["id"])

    conflict =
      response
      |> recycle()
      |> with_identity(token)
      |> post(~p"/api/v1/operations/ingest/#{message["id"]}/requeue")

    assert %{"error" => "Extraction is not repairable"} = json_response(conflict, 409)

    invalid =
      conflict
      |> recycle()
      |> with_identity(token)
      |> post("/api/v1/operations/ingest/not-a-uuid/requeue")

    assert %{"error" => "Invalid request"} = json_response(invalid, 422)

    missing =
      invalid
      |> recycle()
      |> with_identity(token)
      |> post("/api/v1/operations/ingest/#{Ecto.UUID.generate()}/requeue")

    assert %{"error" => "Not found"} = json_response(missing, 404)
  end

  defp extraction_run!(actor, message_id) do
    actor_opts = [role: :system, pipeline?: true]

    DataLayer.with_account_id(actor.account_id, actor_opts, fn account, pipeline_actor ->
      PipelineRun
      |> Ash.Query.filter(
        kind == "extraction" and target_type == "message" and target_id == ^message_id
      )
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: pipeline_actor)
    end)
  end

  test "POST /api/v1/operations/dream enqueues an Account dream-time pass", %{
    conn: conn,
    token: token
  } do
    conn = conn |> with_identity(token) |> post(~p"/api/v1/operations/dream")

    assert %{"data" => %{"run_id" => run_id, "status" => "accepted"}} = json_response(conn, 202)

    assert %{rows: [["dream_time", "pending"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT kind, status FROM pipeline_runs WHERE id = $1",
               [Ecto.UUID.dump!(run_id)]
             )
  end

  # Ranked retrieval with no answer generation. A scope path selects that scope
  # together with its ancestors, because context flows downward: a child scope
  # sees what its parents know and never the reverse. Account, authorization,
  # lifecycle, and source filtering all happen inside retrieval before any
  # candidate reaches this response, so a caller never post-filters.
  test "POST /api/v1/search freezes scoped retrieval contract", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-search", "/contract/http/search")

    conn =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/search", %{
        "scope_path" => "/contract/http/search",
        "query" => "release summaries"
      })

    assert %{
             "data" => %{
               # Search defaults to the middle profile; answering defaults to
               # the slower, more thorough one, because an answer justifies
               # more latency than a bare candidate list.
               "profile" => "balanced",
               # "f7-1" names the retrieval and context behaviour a client is
               # written against. Like the other identity strings here it is a
               # contract version, not the release version.
               "profile_version" => "f7-1",
               # A non-empty list is not an error — it is how the response
               # admits that results are partial, which is why the field exists
               # at all. Here it names `semantic` because this suite runs on
               # the deterministic fallback, which refuses to invent vectors
               # and therefore has no embedder: the strategy could not run.
               "dropped_strategies" => ["semantic"],
               # A separate list for strategies that ran and matched nothing.
               # Without it a caller cannot tell this page from one where every
               # strategy that reads the query text came back empty and the
               # rest ranked the scope by recency.
               "empty_strategies" => _empty,
               "disagreement" => %{"query_dependent_empty" => false},
               "candidates" => [%{"statement" => statement} | _]
             }
           } = json_response(conn, 200)

    # Candidates arrive in fused rank order. Each strategy scores in its own
    # space, so re-sorting by a raw per-strategy score compares numbers that
    # are not comparable and silently degrades the ranking.
    assert statement =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  test "POST /api/v1/source-search returns bounded immutable source citations", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    assert {:ok, message} =
             Memory.ingest_message(
               ingest_attrs("source-search-session", "/contract/http/source-search"),
               actor
             )

    conn =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/source-search", %{
        "scope_path" => "/contract/http/source-search",
        "query" => "concise weekly release summaries",
        "mode" => "exact",
        "excerpt_chars" => 80
      })

    assert %{
             "data" => %{
               "mode" => "exact",
               "status" => "ready",
               "degraded" => false,
               "results" => [
                 %{
                   "id" => message_id,
                   "session_id" => session_id,
                   "scope_id" => scope_id,
                   "speaker_key" => _speaker,
                   "occurred_at" => _occurred_at,
                   "excerpt" => excerpt,
                   "rank" => 1
                 }
               ]
             }
           } = json_response(conn, 200)

    assert message_id == message["id"]
    assert session_id == message["session_id"]
    assert scope_id == message["scope_id"]
    assert String.length(excerpt) <= 80
    refute Map.has_key?(json_response(conn, 200)["data"], "total")
    assert_trace_id(conn)
  end

  test "POST /api/v1/source-search rejects invalid typed arguments", %{conn: conn, token: token} do
    response =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/source-search", %{"limit" => "many"})

    assert %{"error" => "Invalid request"} = json_response(response, 422)
  end

  # Diagnostic options travel as a `DiagnosticGrant` struct precisely so a JSON
  # body cannot forge one. The token below is an account admin's password
  # identity — the identity that may run a diagnostic in the console — so a role
  # check alone would let these bodies through, and only the struct stops them.
  test "POST /api/v1/search and /ask cannot request diagnostic behaviour", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-grant", "/contract/http/grant")

    search =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/search", %{
        "scope_path" => "/contract/http/grant",
        "query" => "release summaries",
        "_diagnostic" => %{"limit" => 100, "trace?" => true, "deadline?" => false},
        "trace" => true
      })

    assert %{"data" => search_data} = json_response(search, 200)
    refute Map.has_key?(search_data, "diagnostic_trace")
    refute Map.has_key?(search_data, "diagnostic")
    assert length(search_data["candidates"]) <= 12

    ask =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/ask", %{
        "scope_path" => "/contract/http/grant",
        "question" => "What kind of release summaries does Avery prefer?",
        "_diagnostic" => %{"limit" => 100, "trace?" => true},
        "trace" => true
      })

    assert %{"data" => ask_data} = json_response(ask, 200)
    refute Map.has_key?(ask_data, "diagnostic_trace")
    refute Map.has_key?(ask_data, "diagnostic")
  end

  # Retrieval plus a grounded answer. With no model credential configured the
  # answer is composed from the retrieved statements themselves, which is why
  # this passes offline; the shape of the response is identical either way.
  test "POST /api/v1/ask freezes grounded fallback answer contract", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-ask", "/contract/http/ask")

    conn =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/ask", %{
        "scope_path" => "/contract/http/ask",
        "question" => "What kind of release summaries does Avery prefer?"
      })

    assert %{
             "data" => %{
               "profile" => "thorough",
               "profile_version" => "f7-1",
               "answer" => answer,
               # Not abstaining, with at least one citation, is the pair that
               # makes the answer trustworthy: when nothing supports the
               # question the action declines instead of inventing an answer,
               # so `abstained == true` is an ordinary outcome and not a
               # failure a client should retry.
               "abstained" => false,
               "citations" => [_ | _],
               # The model-free path states no probability of its own, so it
               # reports the fixed confidence of a statement concatenation.
               "answer_confidence" => 40
             }
           } = json_response(conn, 200)

    assert answer =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  # A cited abstention is distinct from the empty fallback above: the evidence
  # supports a qualified inference, but does not establish a conclusion. This
  # is a public response-shape contract because clients must not assume that an
  # abstained response always has an empty citation list.
  test "POST /api/v1/ask preserves a grounded inconclusive answer", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-ask-inconclusive", "/contract/http/ask-inconclusive")
    GroundedAnswerProvider.start!(:grounded_abstention)
    Application.put_env(:memhouse, :model_provider, GroundedAnswerProvider)

    conn =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/ask", %{
        "scope_path" => "/contract/http/ask-inconclusive",
        "question" =>
          "Does the record establish that Avery prefers concise weekly release summaries?",
        "profile" => "balanced"
      })

    assert %{
             "data" => %{
               "answer" =>
                 "The recorded statements do not establish this, but they support a preference for concise weekly release summaries.",
               "abstained" => true,
               "citations" => [_ | _],
               "answer_confidence" => 30
             }
           } = json_response(conn, 200)

    assert_trace_id(conn)
  end

  # Context assembly is a projection read, never an inference. No generation
  # model is called on this path, which is what keeps it cheap and repeatable;
  # introducing a model call here would turn a lookup into an inference and
  # break that guarantee.
  test "POST /api/v1/context freezes reasoning-free context contract", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-context", "/contract/http/context")

    conn =
      conn
      |> with_identity(token)
      |> post(~p"/api/v1/context", %{"scope_path" => "/contract/http/context"})

    assert %{
             "data" => %{
               "profile_version" => "f7-1",
               # Absent because nothing has built a projection for this
               # brand-new scope yet. Summaries, scope cards, and peer profiles
               # are derived views over governed knowledge, so before their
               # background rebuild runs they are missing rather than wrong.
               "session_summary" => nil,
               "scope_cards" => [],
               "entity_cards" => [],
               "peer_profile" => [],
               # Reports that the projection was missing and the fastest
               # retrieval profile filled the gap live. Callers need to tell a
               # cached assembly from an improvised one; the improvised path
               # still calls no reasoning model.
               "fast_fallback" => true,
               "knowledge" => [%{"statement" => statement} | _]
             }
           } = json_response(conn, 200)

    assert statement =~ "concise weekly release summaries"
    assert_trace_id(conn)
  end

  # A read-only listing. There is deliberately no POST counterpart; see the
  # route-absence test further down, which enforces that.
  test "GET /api/v1/knowledge freezes structured knowledge reads", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    seed_memory!(actor, "http-knowledge", "/contract/http/knowledge")

    conn =
      conn
      |> with_identity(token)
      |> get(~p"/api/v1/knowledge?scope_path=/contract/http/knowledge")

    assert %{
             "data" => [
               %{
                 "statement" => "Avery prefers concise weekly release summaries.",
                 # Not "active": a freshly extracted item is gated, never
                 # auto-promoted. "provisional" means it is usable by the peer
                 # who supplied it while it waits for a decision, and invisible
                 # to everyone else. It appears in this default listing only
                 # because the default view also includes the caller's own
                 # provisional items — asserting "active" here would mean
                 # extraction had started publishing without a gate.
                 "state" => "provisional",
                 # Each row is annotated with the scope it actually lives at,
                 # because a listing spans the requested scope plus every
                 # ancestor it inherits from, and the caller needs to know
                 # which of those a given statement came from.
                 "scope_path" => "/contract/http/knowledge"
               }
               | _
             ]
           } = json_response(conn, 200)

    assert_trace_id(conn)
  end

  # Cross-account isolation is absolute, and it rests on the Account being
  # derived from the verified credential rather than named by the request. This
  # sends both historical ways of naming one — the deprecated header and a body
  # field — with values that match no existing Account. An old client must fail
  # closed into its own Account instead of reaching into, or conjuring,
  # another.
  test "authenticated identity overrides deprecated header and body Account data", %{
    conn: conn,
    token: token
  } do
    conn =
      conn
      |> put_req_header("x-memhouse-account-key", "header-selected-account")
      |> with_identity(token)
      |> post(
        ~p"/api/v1/ingest",
        ingest_attrs("account-session", "/contract/http/account")
        |> Map.put("account_key", "body-selected-account")
      )

    # The request still succeeds; the extra fields are accepted and ignored
    # rather than rejected, so an outdated client keeps working safely.
    assert %{"data" => %{"message_id" => _, "status" => "accepted"}} =
             json_response(conn, 202)

    # Raw SQL on purpose. An Ash read would be filtered to the caller's own
    # Account, which is precisely the filter under test — it could not see a
    # stray Account row even if one had been created. Querying the table
    # directly is the only way to prove that neither supplied key created or
    # selected anything: "local" is the single bootstrapped community Account,
    # and it is the only row that comes back.
    assert %{rows: [["local"]]} =
             Ecto.Adapters.SQL.query!(
               MemHouse.Repo,
               """
               SELECT account.key
               FROM accounts AS account
               WHERE account.key IN ('local', 'header-selected-account', 'body-selected-account')
               ORDER BY account.key
               """
             )
  end

  # The load-bearing absence. An agent may submit observations and read
  # governed memory, but it must never be able to declare something true: the
  # extraction pipeline is the only writer of knowledge, and what it writes
  # still has to clear a governance decision. Without this test, "no one has
  # added a write route yet" and "adding a write route is forbidden" look
  # identical to anyone reading the router.
  test "agents have no direct knowledge-write route", %{conn: conn, token: token} do
    # Inspecting the compiled route table catches the mistake at its source: a
    # route added here would fail this half even before anyone wrote a handler
    # that persists anything.
    refute Enum.any?(MemHouseWeb.Router.__routes__(), fn route ->
             route.verb == :post and route.path == "/api/v1/knowledge"
           end)

    conn =
      conn
      |> with_identity(token)
      |> post("/api/v1/knowledge", %{
        "statement" => "An agent tried to write this as knowledge.",
        "state" => "active"
      })

    # Authenticated and still 404: the credential is valid, so the refusal is
    # the missing route, not a rejected identity.
    assert json_response(conn, 404)

    # The second half, and the one that actually matters. A 404 alone would not
    # rule out some other path having persisted the statement. Reading the
    # table directly, unfiltered by tenancy, proves nothing was written
    # anywhere.
    assert %{rows: []} =
             Ecto.Adapters.SQL.query!(
               MemHouse.Repo,
               """
               SELECT id
               FROM knowledge_items
               WHERE statement = 'An agent tried to write this as knowledge.'
               """
             )
  end

  # Seeds one observation through the domain rather than over HTTP. The write
  # path is the same one the ingest route uses, so the seeded knowledge is
  # governed exactly like anything a client submits; going direct simply keeps
  # the retrieval tests from also depending on the ingest route passing.
  defp seed_memory!(actor, key, scope_path) do
    assert {:ok, message} =
             Memory.ingest_message(ingest_attrs("#{key}-session", scope_path), actor)

    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], actor.account_id)
  end

  # One shared observation for every test. Each test uses its own scope path so
  # the cases stay isolated, while the identical sentence keeps the expected
  # statement, answer, and citation text the same everywhere.
  defp ingest_attrs(session_id, scope_path) do
    %{
      "session_id" => session_id,
      "scope_path" => scope_path,
      "peer_key" => "agent-1",
      "role" => "user",
      "content" => "Avery prefers concise weekly release summaries."
    }
  end

  # Presents the bearer token. Everything except the probes is rejected with
  # 401 before the controller runs when this is omitted, and the Account and
  # the acting peer are both derived from the credential it carries.
  defp with_identity(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp extractor_usage_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT count(*) FROM usage_events WHERE account_id = $1 AND model_role = 'ingest_extractor'",
        [Ecto.UUID.dump!(account_id)]
      )

    count
  end

  # Asserted on every route: an operator must be able to lift a correlation id
  # off any response and find the matching log lines. 32 lowercase hex
  # characters is the standard 128-bit trace-id width.
  defp assert_trace_id(conn) do
    assert [trace_id] = get_resp_header(conn, "x-trace-id")
    assert trace_id =~ ~r/\A[0-9a-f]{32}\z/
  end
end
