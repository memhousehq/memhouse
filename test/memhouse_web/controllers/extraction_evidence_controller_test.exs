# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ExtractionEvidenceControllerTest do
  use MemHouseWeb.ConnCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Identity
  alias MemHouse.Memory
  alias MemHouse.Model.Gateway
  alias MemHouse.Model.Providers.Deterministic
  alias MemHouse.Operations.ExtractionBudget
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline.ExtractionBatcher

  require Ash.Query

  defmodule CountingProvider do
    def structured(config, messages, schema, opts) do
      send(Application.fetch_env!(:memhouse, :extraction_budget_test_pid), :provider_called)
      Deterministic.structured(config, messages, schema, opts)
    end
  end

  setup do
    bootstrap =
      Identity.bootstrap_human(%{
        email: "evidence-admin@example.test",
        name: "Evidence Admin",
        password: "correct horse battery staple"
      })

    {:ok, actor: bootstrap.actor, peer: bootstrap.peer, token: bootstrap.token}
  end

  test "exports content-safe extraction evidence for one corpus scope", %{
    conn: conn,
    actor: actor,
    peer: peer,
    token: token
  } do
    scope_root = "/bench/locomo/corpus-a"
    message = ingest_and_extract!(actor, peer.key, "#{scope_root}/case-1", "case-a")

    ingest_and_extract!(
      actor,
      peer.key,
      "/bench/locomo/other-corpus/case-1",
      "other-case"
    )

    response =
      conn
      |> with_identity(token)
      |> get("/api/v1/operations/extraction-evidence", %{"scope_root" => scope_root})

    assert %{
             "data" => %{
               "schema_version" => "memhouse-extraction-evidence-1",
               "scope_root" => ^scope_root,
               "scopes" => %{"count" => 2},
               "extraction" => %{
                 "anchors" => 1,
                 "status_counts" => %{"completed" => 1},
                 "job_attempts" => 1,
                 "terminal_anchors" => 0,
                 "candidate_yield" => %{"zero" => 0, "one" => 1, "multiple" => 0},
                 "batches" => %{
                   "count" => 1,
                   "anchor_count" => %{"1" => 1},
                   "provider_attempts" => %{"1" => 1}
                 }
               },
               "usage" => %{
                 "provider_attempts" => 1,
                 "errors" => 0,
                 "unmetered_attempts" => 0,
                 "input_tokens" => input_tokens,
                 "output_tokens" => output_tokens,
                 "total_tokens" => total_tokens,
                 "duration_ms" => duration_ms,
                 "provenance" => [
                   %{
                     "provider" => "deterministic",
                     "prompt_version" => "extract-14",
                     "pipeline_version" => "f5-1",
                     "attempts" => 1
                   }
                 ]
               },
               "statements" => %{
                 "count" => 1,
                 "distributions" => %{
                   "kind" => %{"preference" => 1},
                   "prompt_version" => %{"extract-14" => 1}
                 }
               },
               "accounting" => %{"complete" => true, "reasons" => []}
             }
           } = json_response(response, 200)

    assert input_tokens >= 0
    assert output_tokens >= 0
    assert total_tokens == input_tokens + output_tokens
    assert duration_ms >= 0
    assert is_binary(message["id"])

    payload = json_response(response, 200)
    refute inspect(payload) =~ "Avery prefers concise weekly release summaries."
    refute inspect(payload) =~ "other-corpus"
  end

  test "fails closed for a missing scope and a non-admin caller", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    missing =
      conn
      |> with_identity(token)
      |> get("/api/v1/operations/extraction-evidence", %{"scope_root" => "/missing"})

    assert %{"error" => "Not found"} = json_response(missing, 404)

    member =
      Identity.provision_agent(actor, %{
        "key" => "evidence-member",
        "scope_path" => "/",
        "role" => "member"
      })

    denied =
      missing
      |> recycle()
      |> with_identity(member.api_key)
      |> get("/api/v1/operations/extraction-evidence", %{"scope_root" => "/"})

    assert %{"error" => "Forbidden"} = json_response(denied, 403)
  end

  test "marks unsettled and missing provider accounting incomplete", %{
    conn: conn,
    actor: actor,
    peer: peer,
    token: token
  } do
    scope_root = "/bench/locomo/corpus-unsettled"

    assert {:ok, _message} =
             Memory.ingest_message(
               %{
                 "session_id" => "unsettled",
                 "scope_path" => "#{scope_root}/case-1",
                 "content" => "Avery prefers concise weekly release summaries.",
                 "peer_key" => peer.key,
                 "role" => "user"
               },
               actor
             )

    response =
      conn
      |> with_identity(token)
      |> get("/api/v1/operations/extraction-evidence", %{"scope_root" => scope_root})

    assert %{
             "data" => %{
               "extraction" => %{"anchors" => 1},
               "usage" => %{"provider_attempts" => 0},
               "accounting" => %{
                 "complete" => false,
                 "settled" => false,
                 "requests_complete" => false,
                 "tokens_complete" => false,
                 "cost_complete" => false,
                 "reasons" => reasons
               }
             }
           } = json_response(response, 200)

    assert "extraction runs are not settled" in reasons
  end

  test "one batch can safely report heterogeneous per-anchor candidate yield", %{
    conn: conn,
    actor: actor,
    peer: peer,
    token: token
  } do
    previous = Application.fetch_env!(:memhouse, :extraction_batching)
    Application.put_env(:memhouse, :extraction_batching, Keyword.put(previous, :enabled, true))
    on_exit(fn -> Application.put_env(:memhouse, :extraction_batching, previous) end)

    scope_root = "/bench/locomo/corpus-batched"

    assert {:ok, first} =
             Memory.ingest_message(
               %{
                 "session_id" => "shared-session",
                 "scope_path" => "#{scope_root}/case-1",
                 "content" => "Avery prefers concise weekly release summaries.",
                 "peer_key" => peer.key,
                 "role" => "user"
               },
               actor
             )

    assert {:ok, _second} =
             Memory.ingest_message(
               %{
                 "session_id" => "shared-session",
                 "scope_path" => "#{scope_root}/case-1",
                 "content" => "Hello there.",
                 "peer_key" => peer.key,
                 "role" => "user"
               },
               actor
             )

    run = extraction_run!(actor.account_id, first["id"])
    assert {:ok, %{status: "processed"}} = ExtractionBatcher.run(run)

    response =
      conn
      |> with_identity(token)
      |> get("/api/v1/operations/extraction-evidence", %{"scope_root" => scope_root})

    assert %{
             "data" => %{
               "extraction" => %{
                 "anchors" => 2,
                 "candidate_yield" => %{"zero" => 1, "one" => 1, "multiple" => 0},
                 "batches" => %{"count" => 1, "anchor_count" => %{"2" => 1}}
               },
               "accounting" => %{"complete" => true}
             }
           } = json_response(response, 200)
  end

  test "hard budget reserves worst-case spend before a provider attempt", %{
    conn: conn,
    actor: actor,
    token: token
  } do
    scope_root = "/bench/locomo/corpus-budget"
    deadline = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()

    response =
      conn
      |> with_identity(token)
      |> put("/api/v1/operations/extraction-budget", %{
        "scope_root" => scope_root,
        "request_cap" => 1,
        "token_cap" => 20_000,
        "usd_micros_cap" => 10_000,
        "deadline_at" => deadline,
        "input_usd_micros_per_million" => 50_000,
        "output_usd_micros_per_million" => 250_000
      })

    assert %{
             "data" => %{
               "scope_root" => ^scope_root,
               "requests_reserved" => 0,
               "tokens_reserved" => 0,
               "usd_micros_reserved" => 0,
               "extraction_identity" => %{
                 "build_sha" => "unknown",
                 "prompt_version" => "extract-14",
                 "pipeline_version" => "f5-1",
                 "batching_enabled" => false,
                 "batching_identity" =>
                   "utf8-bytes-v1:target=4096:context=131072:output=8192:margin=2048"
               }
             }
           } = json_response(response, 200)

    context = %{
      account_id: actor.account_id,
      scope_path: "#{scope_root}/case-1",
      actor: actor
    }

    assert {:ok, remaining_ms} =
             ExtractionBudget.reserve(
               context,
               [%{role: "user", content: "content-safe test prompt"}],
               %{"type" => "object"}
             )

    assert remaining_ms > 0

    assert {:error, %ExtractionBudget.ExceededError{}} =
             ExtractionBudget.reserve(
               context,
               [%{role: "user", content: "second attempt"}],
               %{"type" => "object"}
             )
  end

  test "gateway refuses an extractor provider callback after hard-budget exhaustion", %{
    actor: actor
  } do
    previous_provider = Application.get_env(:memhouse, :model_provider)
    Application.put_env(:memhouse, :model_provider, CountingProvider)
    Application.put_env(:memhouse, :extraction_budget_test_pid, self())

    on_exit(fn ->
      Application.put_env(:memhouse, :model_provider, previous_provider)
      Application.delete_env(:memhouse, :extraction_budget_test_pid)
    end)

    scope_root = "/bench/locomo/corpus-gateway-budget"
    assert {:ok, _budget} = ExtractionBudget.register(actor, budget_attrs(scope_root, 1))

    context = %{account_id: actor.account_id, scope_path: "#{scope_root}/case-1", actor: actor}
    messages = [%{role: "user", content: "Avery prefers concise summaries."}]
    schema = %{"type" => "object"}

    assert {:ok, _value, _config, _usage, 1} =
             Gateway.structured_once_with_usage_and_attempt(
               :ingest_extractor,
               messages,
               schema,
               context,
               task: :extraction
             )

    assert_receive :provider_called

    assert {:error, %ExtractionBudget.ExceededError{}, 0} =
             Gateway.structured_once_with_usage_and_attempt(
               :ingest_extractor,
               messages,
               schema,
               context,
               task: :extraction
             )

    refute_receive :provider_called
  end

  test "literal corpus scope matching and Account isolation preserve reservations", %{
    actor: actor
  } do
    second_actor =
      DataLayer.with_account_key("evidence-budget-isolated", fn _account, isolated_actor ->
        isolated_actor
      end)

    literal_scope = "/bench/locomo/corpus_a%"
    lookalike_scope = "/bench/locomo/corpusXab"

    assert {:ok, _} = ExtractionBudget.register(actor, budget_attrs(literal_scope, 1))
    assert {:ok, _} = ExtractionBudget.register(actor, budget_attrs(lookalike_scope, 2))
    assert {:ok, _} = ExtractionBudget.register(second_actor, budget_attrs(literal_scope, 2))

    assert {:ok, _remaining} =
             ExtractionBudget.reserve(
               %{
                 account_id: actor.account_id,
                 scope_path: "#{literal_scope}/case-1",
                 actor: actor
               },
               [%{role: "user", content: "literal scope"}],
               %{"type" => "object"}
             )

    assert {:ok, %{requests_reserved: 1}} =
             ExtractionBudget.register(actor, budget_attrs(literal_scope, 1))

    assert {:ok, %{requests_reserved: 0}} =
             ExtractionBudget.register(actor, budget_attrs(lookalike_scope, 2))

    assert {:ok, %{requests_reserved: 0}} =
             ExtractionBudget.register(second_actor, budget_attrs(literal_scope, 2))
  end

  defp ingest_and_extract!(actor, peer_key, scope_path, session_id) do
    assert {:ok, message} =
             Memory.ingest_message(
               %{
                 "session_id" => session_id,
                 "scope_path" => scope_path,
                 "content" => "Avery prefers concise weekly release summaries.",
                 "peer_key" => peer_key,
                 "role" => "user"
               },
               actor
             )

    run = extraction_run!(actor.account_id, message["id"])
    assert {:ok, %{status: "processed"}} = ExtractionBatcher.run(run)

    message
  end

  defp extraction_run!(account_id, message_id) do
    MemHouse.DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn account, pipeline_actor ->
        PipelineRun
        |> Ash.Query.filter(
          kind == "extraction" and target_type == "message" and target_id == ^message_id
        )
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: pipeline_actor)
      end
    )
  end

  defp budget_attrs(scope_root, request_cap) do
    %{
      "scope_root" => scope_root,
      "request_cap" => request_cap,
      "token_cap" => 20_000,
      "usd_micros_cap" => 10_000,
      "deadline_at" => DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601(),
      "input_usd_micros_per_million" => 50_000,
      "output_usd_micros_per_million" => 250_000
    }
  end

  defp with_identity(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")
end
