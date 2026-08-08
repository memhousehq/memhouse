# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.F9SkillReadinessProceduralMemoryTest do
  @moduledoc """
  Pins skill requirement cards and the readiness gap report that gates helper execution.

  Cards are authored, plain-versioned configuration—not knowledge. Readiness is
  reasoning-free and never writes: elicited answers return through ingest and
  governance.

  This suite pins strict selector validation, immutable audited versions,
  nearest-scope requirement overrides, required blockers, preferred warnings,
  and immediate rejection of stale knowledge. It also keeps the `f9-1` selector
  and gap-report contract aligned across HTTP, machine tools, UI, and helpers.

  Runs `async: false`: it bootstraps real credentials, drives HTTP and LiveView requests,
  and reads the file system for the client helper sources.
  """

  use MemHouseWeb.ConnCase, async: false

  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Identity
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Skills
  alias MemHouse.Skills.Selector
  alias MemHouse.Skills.SkillRequirementCard

  require Ash.Query

  test "authored cards validate f9-1 selectors and inherit nearest requirement overrides" do
    seeded =
      seed_active!("inherit", "/f9/inherit", "Avery prefers concise release summaries.")

    # An unrecognised selector key is a hard error, not something to ignore. A silently
    # dropped selector would leave a requirement that matches everything, so a card meant to
    # gate a skill would wave it through.
    assert {:error, message} =
             Skills.publish(seeded.actor, %{
               scope_path: "/",
               skill_key: "write-copy",
               requirements: [
                 %{
                   key: "invalid",
                   selector: %{unknown: "statement text"},
                   level: "required",
                   source_policy: "from-memory"
                 }
               ]
             })

    assert message =~ "unknown keys"

    # Root card: two requirements that every descendant scope inherits.
    assert {:ok, root_card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/",
               skill_key: "write-copy",
               description: "Base copy requirements",
               requirements: [
                 requirement("voice", "preference", "required", "from-memory"),
                 requirement("background", "fact", "preferred", "either")
               ]
             })

    assert root_card.version == 1
    # Every card records the selector-language version it was authored against, so an old
    # card can still be interpreted after the language changes.
    assert root_card.requirement_schema_version == Selector.schema_version()

    # Child card exercising all three merge behaviours against the inherited set:
    # "voice" is redefined (nearer scope wins), "background" is explicitly disabled
    # (inherited key removed), and "deadline" is new (inherited set extended).
    assert {:ok, child_card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/inherit",
               skill_key: "write-copy",
               description: "Team override",
               requirements: [
                 requirement("voice", "preference", "required", "either"),
                 requirement("background", "fact", "preferred", "either", enabled: false),
                 requirement("deadline", "event", "preferred", "ask-peer")
               ]
             })

    # Versions are per scope and skill, so the child starts at 1 despite the root existing.
    assert child_card.version == 1

    report =
      Skills.check_readiness(seeded.actor, %{
        skill: "write-copy",
        scope_path: "/f9/inherit"
      })

    assert report["ready"]
    # "background" is gone: a disabled key removes the inherited requirement rather than
    # leaving a permanently unsatisfiable one behind.
    assert Enum.map(report["requirements"], & &1["key"]) == ["voice", "deadline"]

    voice = Enum.find(report["requirements"], &(&1["key"] == "voice"))
    assert voice["status"] == "satisfied"
    # The child's definition won, and the report names the scope that supplied it, so an
    # author can tell which card is actually in force at this point in the tree.
    assert voice["source_policy"] == "either"
    assert voice["source_scope_path"] == "/f9/inherit"
    # Reports cite the exact knowledge that satisfied a requirement; "ready" is never an
    # unexplained boolean.
    assert voice["matched_knowledge_ids"] == [seeded.knowledge.id]

    # A missing preferred requirement warns and leaves the skill runnable.
    assert [%{"key" => "deadline", "level" => "preferred", "status" => "missing"}] =
             report["warnings"]

    assert {:ok, version_two} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/inherit",
               skill_key: "write-copy",
               requirements: [
                 requirement("voice", "preference", "required", "either")
               ]
             })

    assert version_two.version == 2

    DataLayer.with_actor(seeded.actor, fn account, actor ->
      scope_id = seeded.scope.id

      cards =
        SkillRequirementCard
        |> Ash.Query.filter(scope_id == ^scope_id and skill_key == "write-copy")
        |> Ash.Query.sort(version: :asc)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor)

      # Republishing appends version 2 and deactivates version 1; it never edits version 1
      # in place. The superseded card stays readable so a past decision can be explained.
      assert Enum.map(cards, &{&1.version, &1.active}) == [{1, false}, {2, true}]
    end)

    # Four audit events: three successful publishes plus the one deactivation the republish
    # performed. The rejected publish wrote nothing at all — a failed validation must not
    # leave a partial card or a stray audit entry behind.
    assert scalar!(
             """
             SELECT count(*) FROM audit_events
             WHERE resource_type = 'skill_requirement_card'
             """,
             []
           ) == 4
  end

  test "required gaps block while preferred gaps only warn and emit elicitation plans" do
    seeded = seed_active!("gaps", "/f9/gaps", "Avery prefers concise release summaries.")

    assert {:ok, _card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/gaps",
               skill_key: "ship-release",
               requirements: [
                 requirement("voice", "preference", "required", "from-memory"),
                 requirement("context", "fact", "preferred", "either")
               ]
             })

    warning_only =
      Skills.check_readiness(seeded.actor, %{
        skill: "ship-release",
        scope_path: "/f9/gaps"
      })

    # The required item is satisfied by the seeded knowledge; only the preferred one is
    # missing, so the skill still runs. Preferred gaps degrade quality, not correctness.
    assert warning_only["ready"]
    refute warning_only["blocked"]
    assert warning_only["blockers"] == []

    # The elicitation descriptor is a *suggestion with a mandatory route*: ask the peer, then
    # submit the answer through ordinary ingest, then check readiness again. It deliberately
    # offers no way to write the answer into knowledge, because an elicited answer must be
    # extracted and approved like any other observation before it can satisfy a requirement.
    assert [
             %{
               "key" => "context",
               "blocking" => false,
               "elicitation" => %{
                 "allowed" => true,
                 "submit_via" => "ingest",
                 "then" => "check_readiness"
               }
             }
           ] = warning_only["warnings"]

    # Republish with an additional *required* requirement that nothing satisfies.
    assert {:ok, _card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/gaps",
               skill_key: "ship-release",
               requirements: [
                 requirement("voice", "preference", "required", "from-memory"),
                 requirement("approval-window", "event", "required", "ask-peer"),
                 requirement("context", "fact", "preferred", "either")
               ]
             })

    blocked =
      Skills.check_readiness(seeded.actor, %{
        skill: "ship-release",
        scope_path: "/f9/gaps"
      })

    refute blocked["ready"]
    assert blocked["blocked"]

    # A required gap is a server-side blocker. Client helpers surface it; they must never
    # override it, because the point is to stop an agent acting on knowledge it lacks.
    assert [
             %{
               "key" => "approval-window",
               "blocking" => true,
               "status" => "missing",
               "elicitation" => %{"allowed" => true}
             }
           ] = blocked["blockers"]

    # Blocking and non-blocking gaps stay in separate lists. Collapsing them would make the
    # preferred gap look fatal, or the required one look optional.
    assert Enum.map(blocked["warnings"], & &1["key"]) == ["context"]
  end

  test "expired, due, and needs_revalidation knowledge never satisfies readiness" do
    # Nominally `active`, but its revalidation date passed one second ago. A background
    # sweeper will eventually reclassify it; readiness must not wait for that. Otherwise the
    # gap between "due" and "swept" is a window where stale knowledge silently passes checks.
    seeded =
      seed_active!(
        "stale",
        "/f9/stale",
        "Avery prefers concise release summaries.",
        revalidate_after: DateTime.add(Clock.utc_now(), -1, :second)
      )

    assert {:ok, _card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/stale",
               skill_key: "write-copy",
               requirements: [
                 requirement("voice", "preference", "required", "from-memory")
               ]
             })

    due =
      Skills.check_readiness(seeded.actor, %{
        skill: "write-copy",
        scope_path: "/f9/stale"
      })

    # Reported as `stale` rather than `missing`, and the offending ids are named: the caller
    # needs to know something exists but can no longer be trusted, so it can be revalidated
    # instead of re-collected from scratch.
    assert [%{"key" => "voice", "status" => "stale"}] = due["blockers"]
    assert hd(due["blockers"])["stale_knowledge_ids"] == [seeded.knowledge.id]

    # Second route to the same verdict: explicitly flagged for revalidation, with no date set.
    transition!(seeded, "needs_revalidation", revalidate_after: nil)

    revalidation =
      Skills.check_readiness(seeded.actor, %{
        skill: "write-copy",
        scope_path: "/f9/stale"
      })

    assert [%{"status" => "stale"}] = revalidation["blockers"]

    # Third route: outright expired. All three must produce the same blocking verdict.
    transition!(seeded, "expired", expires_at: DateTime.add(Clock.utc_now(), -1, :second))

    expired =
      Skills.check_readiness(seeded.actor, %{
        skill: "write-copy",
        scope_path: "/f9/stale"
      })

    assert [%{"status" => "stale"}] = expired["blockers"]
  end

  test "HTTP, MCP metadata, governance UI, and SDK helpers expose the same f9-1 contract", %{
    conn: conn
  } do
    seeded =
      seed_active!("surfaces", "/f9/surfaces", "Avery prefers concise release summaries.")

    assert {:ok, _card} =
             Skills.publish(seeded.actor, %{
               scope_path: "/f9/surfaces",
               skill_key: "write-copy",
               requirements: [
                 requirement("voice", "preference", "required", "ask-peer")
               ]
             })

    # Surface one: HTTP. The account is derived from the bearer credential, never from a
    # request parameter, so a caller cannot ask about another account's readiness.
    response =
      conn
      |> put_req_header("authorization", "Bearer #{seeded.token}")
      |> post("/api/v1/readiness", %{
        "skill" => "write-copy",
        "scope_path" => "/f9/surfaces"
      })

    assert %{
             "data" => %{
               "report_version" => "f9-1",
               "ready" => true,
               "requirements" => [%{"status" => "satisfied"}]
             }
           } = json_response(response, 200)

    # Surface two: the tool interface offered to machine callers. Readiness is a read, so it
    # is exposed there; card *authoring* deliberately is not, because publishing a card is a
    # human decision about what an agent is allowed to assume.
    tool_names =
      MemHouse.Governance
      |> AshAi.Info.tools()
      |> Enum.map(& &1.name)

    assert :check_readiness in tool_names

    # Surface three: the human governance page, reached with a session rather than an API
    # credential, listing the same cards and reporting the same schema identity.
    page =
      build_conn()
      |> init_test_session(governance_token: seeded.token)
      |> get("/governance")
      |> html_response(200)

    assert page =~ "Skill requirement cards"
    assert page =~ "write-copy"
    assert page =~ "f9-1"

    # Surface four: the client helpers. They must raise on a blocking gap rather than return
    # a soft warning a caller can ignore, so the server's blocker survives the trip to the
    # client. These are transport-neutral helper modules, not generated SDK clients.
    assert File.read!("sdk/typescript/src/skill-readiness.ts") =~
             "SkillReadinessBlockedError"

    assert File.read!("sdk/python/memhouse/skill_readiness.py") =~
             "SkillReadinessBlockedError"
  end

  # Builds one isolated world per test: a real human identity with real credentials, one
  # ingested observation, and that observation's knowledge forced to `active` so a
  # requirement can match it.
  #
  # A real bootstrap rather than a synthetic actor matters here, because these tests exercise
  # HTTP and the governance page, which authenticate for themselves. `attrs` is merged into
  # the lifecycle transition, which is how the staleness test sets an already-past
  # revalidation date. The actor is re-authenticated at the end so it carries the role and
  # scope grants that exist *after* seeding, not the narrower ones from before.
  defp seed_active!(suffix, scope_path, content, attrs \\ []) do
    bootstrap =
      Identity.bootstrap_human(%{
        email: "f9-#{suffix}@example.test",
        name: "F9 #{suffix}",
        password: "correct horse battery staple"
      })

    assert {:ok, message} =
             Memory.ingest_message(
               %{
                 "session_id" => "f9-#{suffix}",
                 "scope_path" => scope_path,
                 "role" => "user",
                 "content" => content
               },
               bootstrap.actor
             )

    assert {:ok, [knowledge]} =
             Memory.extract_message_for_account(message["id"], bootstrap.actor.account_id)

    knowledge_id = Map.fetch!(knowledge, "id")

    {scope, knowledge} =
      DataLayer.with_actor(bootstrap.actor, fn account, actor ->
        scope =
          MemHouse.Topology.Scope
          |> Ash.Query.filter(path == ^scope_path)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: pipeline_actor(actor))

        knowledge =
          KnowledgeItem
          |> Ash.Query.filter(id == ^knowledge_id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: pipeline_actor(actor))

        knowledge =
          Engine.transition!(
            knowledge,
            pipeline_actor(actor),
            attrs
            |> Map.new()
            |> Map.put(:state, "active")
            |> Map.put(:verification, "peer_verified"),
            reason: "f9_test_activate",
            channel: "pipeline"
          )

        {scope, knowledge}
      end)

    assert {:ok, refreshed_actor} = Identity.authenticate_bearer(bootstrap.token)

    bootstrap
    |> Map.put(:actor, refreshed_actor)
    |> Map.merge(%{scope: scope, knowledge: knowledge})
  end

  # Moves the seeded item to another lifecycle state through the governance engine rather
  # than by updating the row, so the transition writes the lifecycle and audit records a real
  # transition would and readiness sees a realistically shaped item.
  defp transition!(seeded, state, attrs) do
    DataLayer.with_actor(seeded.actor, fn _account, actor ->
      knowledge =
        KnowledgeItem
        |> Ash.Query.filter(id == ^seeded.knowledge.id)
        |> Ash.Query.set_tenant(actor.account_id)
        |> Ash.read_one!(actor: pipeline_actor(actor))

      Engine.transition!(
        knowledge,
        pipeline_actor(actor),
        attrs |> Map.new() |> Map.put(:state, state),
        reason: "f9_test_#{state}",
        channel: "pipeline"
      )
    end)
  end

  # One requirement in the authored card shape. The selector matches on knowledge *metadata*
  # only — kind and subject here — never on statement text and never through a model, which
  # is what makes a readiness check deterministic and explainable.
  #
  # `source_policy` says where an answer may come from: `from-memory` accepts any governed
  # source, `ask-peer` requires the knowledge to trace back to the target peer having said
  # it, and `either` accepts both.
  defp requirement(key, kind, level, source_policy, opts \\ []) do
    %{
      key: key,
      description: "#{key} requirement",
      selector: %{kind: kind, subject: "peer"},
      level: level,
      source_policy: source_policy,
      prompt: "Please provide #{key}.",
      enabled: Keyword.get(opts, :enabled, true)
    }
  end

  # The internal actor, used only for setup writes that no external caller may perform, such
  # as forcing a lifecycle transition. Never used for the readiness calls under test — those
  # run as the ordinary authenticated actor so authorization is genuinely exercised.
  defp pipeline_actor(%Actor{} = actor),
    do: %{actor | role: :system, pipeline?: true, scope_ids: :all}

  # Raw SQL so the audit-event count is read straight from the table, unmediated by any
  # policy that might hide a row and make a missing audit entry look like a passing test.
  defp scalar!(sql, params) do
    %{rows: [[value]]} = Ecto.Adapters.SQL.query!(MemHouse.Repo, sql, params)
    value
  end
end
