# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ExtractionEvidenceControllerTest do
  use MemHouseWeb.ConnCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Identity
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Model.Gateway
  alias MemHouse.Model.ProviderCircuit
  alias MemHouse.Model.Providers.Deterministic
  alias MemHouse.Operations.ExtractionBudget
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline.ExtractionBatcher
  alias MemHouse.Pipeline.Extractor

  require Ash.Query

  defmodule CountingProvider do
    def structured(config, messages, schema, opts) do
      send(Application.fetch_env!(:memhouse, :extraction_budget_test_pid), :provider_called)
      Deterministic.structured(config, messages, schema, opts)
    end
  end

  defmodule SlowProvider do
    def structured(config, messages, schema, opts) do
      Process.sleep(5_000)
      Deterministic.structured(config, messages, schema, opts)
    end
  end

  defmodule KillingProvider do
    def structured(_config, _messages, _schema, _opts) do
      Process.exit(self(), :kill)
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

    prompt_version = Extractor.prompt_version()

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
                     "prompt_version" => ^prompt_version,
                     "pipeline_version" => "f5-1",
                     "attempts" => 1
                   }
                 ]
               },
               "statements" => %{
                 "count" => 1,
                 "distributions" => %{
                   "kind" => %{"preference" => 1},
                   "prompt_version" => %{^prompt_version => 1}
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

  test "statement evidence includes only outputs attributed to selected extraction runs", %{
    conn: conn,
    actor: actor,
    peer: peer,
    token: token
  } do
    scope_root = "/bench/locomo/corpus-run-attribution"
    message = ingest_and_extract!(actor, peer.key, "#{scope_root}/case-1", "run-attribution")

    DataLayer.in_account_transaction(actor.account_id, fn ->
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(actor.account_id)
      |> Ash.Changeset.for_create(:create_from_pipeline, %{
        scope_id: message["scope_id"],
        subject_scope_id: message["scope_id"],
        statement: "This unrelated derived row must not enter extraction evidence.",
        kind: "skill",
        confidence: 1.0,
        evidence_level: "indirect",
        sensitivity: "internal",
        state: "proposed",
        target_level: "scope",
        verification: "pending",
        source_message_ids: [message["id"]],
        extracting_model: "system:dream-time",
        prompt_version: "dream-time-test",
        pipeline_version: "f5-1"
      })
      |> Ash.create!(actor: pipeline_actor(actor))
    end)

    response =
      conn
      |> with_identity(token)
      |> get("/api/v1/operations/extraction-evidence", %{"scope_root" => scope_root})

    assert %{
             "data" => %{
               "statements" => %{
                 "count" => 1,
                 "distributions" => %{"kind" => %{"preference" => 1}}
               }
             }
           } = json_response(response, 200)
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

    build_sha = Application.fetch_env!(:memhouse, :build_sha)
    prompt_version = Extractor.prompt_version()

    assert %{
             "data" => %{
               "scope_root" => ^scope_root,
               "requests_reserved" => 0,
               "tokens_reserved" => 0,
               "usd_micros_reserved" => 0,
               "extraction_identity" => %{
                 "build_sha" => ^build_sha,
                 "prompt_version" => ^prompt_version,
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
      actor: pipeline_actor(actor)
    }

    assert {:ok, remaining_ms} =
             ExtractionBudget.reserve(
               context,
               [%{role: "user", content: "content-safe test prompt"}],
               %{"type" => "object"}
             )

    assert remaining_ms > 0

    assert {:error, %ExtractionBudget.Exceeded{}} =
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

    context = %{
      account_id: actor.account_id,
      scope_path: "#{scope_root}/case-1",
      actor: pipeline_actor(actor)
    }

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

    assert {:error, %ExtractionBudget.Exceeded{}, 0} =
             Gateway.structured_once_with_usage_and_attempt(
               :ingest_extractor,
               messages,
               schema,
               context,
               task: :extraction
             )

    refute_receive :provider_called
  end

  test "gateway requires a system pipeline actor before reserving extraction budget", %{
    actor: actor
  } do
    previous_provider = Application.get_env(:memhouse, :model_provider)
    Application.put_env(:memhouse, :model_provider, CountingProvider)
    Application.put_env(:memhouse, :extraction_budget_test_pid, self())

    on_exit(fn ->
      Application.put_env(:memhouse, :model_provider, previous_provider)
      Application.delete_env(:memhouse, :extraction_budget_test_pid)
    end)

    scope_root = "/bench/locomo/corpus-reserve-authorization"
    assert {:ok, _budget} = ExtractionBudget.register(actor, budget_attrs(scope_root, 1))

    assert {:error, :unauthorized, 0} =
             Gateway.structured_once_with_usage_and_attempt(
               :ingest_extractor,
               [%{role: "user", content: "request-derived actor must not reserve"}],
               %{"type" => "object"},
               %{
                 account_id: actor.account_id,
                 scope_path: "#{scope_root}/case-1",
                 actor: actor
               },
               task: :extraction
             )

    refute_receive :provider_called

    assert {:ok, %{requests_reserved: 0}} =
             ExtractionBudget.register(actor, budget_attrs(scope_root, 1))
  end

  test "an open provider circuit does not consume extraction budget", %{actor: actor} do
    previous_circuit = Application.fetch_env!(:memhouse, :ingest_provider_circuit)

    Application.put_env(
      :memhouse,
      :ingest_provider_circuit,
      previous_circuit
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:failure_threshold, 1)
      |> Keyword.put(:open_ms, 60_000)
    )

    ProviderCircuit.reset()

    on_exit(fn ->
      ProviderCircuit.reset()
      Application.put_env(:memhouse, :ingest_provider_circuit, previous_circuit)
    end)

    scope_root = "/bench/locomo/corpus-open-circuit"

    context = %{
      account_id: actor.account_id,
      scope_path: "#{scope_root}/case-1",
      actor: pipeline_actor(actor)
    }

    config = MemHouse.Model.role_config(:ingest_extractor, context)

    assert {:ok, permit} = ProviderCircuit.checkout(config, context)
    assert :ok = ProviderCircuit.complete(permit, {:error, :provider_upstream_error})
    assert {:ok, _budget} = ExtractionBudget.register(actor, budget_attrs(scope_root, 1))

    assert {:error, %ProviderCircuit.OpenError{}, 0} =
             Gateway.structured_once_with_usage_and_attempt(
               :ingest_extractor,
               [%{role: "user", content: "circuit refusal"}],
               %{"type" => "object"},
               context,
               task: :extraction
             )

    assert {:ok, %{requests_reserved: 0}} =
             ExtractionBudget.register(actor, budget_attrs(scope_root, 1))
  end

  test "a hard-budget wall timeout does not open the provider circuit", %{actor: actor} do
    previous_provider = Application.get_env(:memhouse, :model_provider)
    previous_circuit = Application.fetch_env!(:memhouse, :ingest_provider_circuit)
    Application.put_env(:memhouse, :model_provider, SlowProvider)

    Application.put_env(
      :memhouse,
      :ingest_provider_circuit,
      previous_circuit
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:failure_threshold, 1)
      |> Keyword.put(:open_ms, 60_000)
    )

    ProviderCircuit.reset()

    on_exit(fn ->
      ProviderCircuit.reset()
      Application.put_env(:memhouse, :model_provider, previous_provider)
      Application.put_env(:memhouse, :ingest_provider_circuit, previous_circuit)
    end)

    scope_root = "/bench/locomo/corpus-local-timeout"

    attrs =
      scope_root
      |> budget_attrs(1)
      |> Map.put(
        "deadline_at",
        DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()
      )

    assert {:ok, _budget} = ExtractionBudget.register(actor, attrs)

    context = %{
      account_id: actor.account_id,
      scope_path: "#{scope_root}/case-1",
      actor: pipeline_actor(actor),
      model_provider: SlowProvider
    }

    assert {:error, %ExtractionBudget.Exceeded{reason: "wall-time cap"}, 1} =
             Gateway.structured_once_with_usage_and_attempt(
               :ingest_extractor,
               [%{role: "user", content: "bounded call"}],
               %{"type" => "object"},
               context,
               task: :extraction
             )

    config = MemHouse.Model.role_config(:ingest_extractor, context)
    assert %{state: :closed, consecutive_failures: 0} = ProviderCircuit.status(config, context)
  end

  test "an abnormally exiting timed provider cannot exit the gateway caller", %{actor: actor} do
    previous_provider = Application.get_env(:memhouse, :model_provider)
    Application.put_env(:memhouse, :model_provider, KillingProvider)

    on_exit(fn -> Application.put_env(:memhouse, :model_provider, previous_provider) end)

    scope_root = "/bench/locomo/corpus-provider-exit"
    assert {:ok, _budget} = ExtractionBudget.register(actor, budget_attrs(scope_root, 1))

    assert {:error, {:provider_exit, :killed}, 1} =
             Gateway.structured_once_with_usage_and_attempt(
               :ingest_extractor,
               [%{role: "user", content: "provider exits"}],
               %{"type" => "object"},
               %{
                 account_id: actor.account_id,
                 scope_path: "#{scope_root}/case-1",
                 actor: pipeline_actor(actor),
                 model_provider: KillingProvider
               },
               task: :extraction
             )
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
                 actor: pipeline_actor(actor)
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

  test "root budgets cover descendants and trailing-slash roots are rejected", %{actor: actor} do
    assert {:error, :invalid} =
             ExtractionBudget.register(actor, budget_attrs("/bench/locomo/corpus/", 1))

    assert {:ok, _budget} = ExtractionBudget.register(actor, budget_attrs("/", 1))

    context = %{
      account_id: actor.account_id,
      scope_path: "/bench/locomo/root-covered/case-1",
      actor: pipeline_actor(actor)
    }

    assert {:ok, remaining_ms} =
             ExtractionBudget.reserve(
               context,
               [%{role: "user", content: "root scope"}],
               %{"type" => "object"}
             )

    assert remaining_ms > 0

    assert {:error, %ExtractionBudget.Exceeded{}} =
             ExtractionBudget.reserve(
               context,
               [%{role: "user", content: "root scope exhausted"}],
               %{"type" => "object"}
             )
  end

  test "length-based scope ordering prefers specific guards over root guard", %{actor: actor} do
    specific_scope = "/bench/locomo/root-covered"
    assert {:ok, _root_budget} = ExtractionBudget.register(actor, budget_attrs("/", 2))

    assert {:ok, _specific_budget} =
             ExtractionBudget.register(actor, budget_attrs(specific_scope, 1))

    descendant_context = %{
      account_id: actor.account_id,
      scope_path: "#{specific_scope}/case-1",
      actor: pipeline_actor(actor)
    }

    assert {:ok, remaining_ms} =
             ExtractionBudget.reserve(
               descendant_context,
               [%{role: "user", content: "specific scope first"}],
               %{"type" => "object"}
             )

    assert remaining_ms > 0

    assert {:error, %ExtractionBudget.Exceeded{}} =
             ExtractionBudget.reserve(
               descendant_context,
               [%{role: "user", content: "specific scope exhausted"}],
               %{"type" => "object"}
             )

    assert {:ok, %{requests_reserved: 1}} =
             ExtractionBudget.register(actor, budget_attrs(specific_scope, 1))

    assert {:ok, %{requests_reserved: 0}} =
             ExtractionBudget.register(actor, budget_attrs("/", 2))
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

  defp pipeline_actor(actor), do: %{actor | role: :system, pipeline?: true}

  defp with_identity(conn, token),
    do: put_req_header(conn, "authorization", "Bearer #{token}")
end
