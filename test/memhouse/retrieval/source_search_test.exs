# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.SourceSearchTest.Provider do
  @moduledoc "Provides deterministic three-dimensional source-search embeddings for tests."
  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Model.Providers.Deterministic

  @impl true
  def structured(config, messages, schema, opts),
    do: Deterministic.structured(config, messages, schema, opts)

  @impl true
  def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

  @impl true
  def embed(_config, texts, _opts) do
    if controller = Application.get_env(:memhouse, :source_index_test_controller) do
      send(controller, {:source_embedding_call, MemHouse.Repo.in_transaction?(), texts})
    end

    vectors =
      Enum.map(texts, fn text ->
        normalized = String.downcase(text)

        [
          if(String.contains?(normalized, "release"), do: 1.0, else: 0.0),
          if(String.contains?(normalized, "garden"), do: 1.0, else: 0.0),
          0.1
        ]
      end)

    vectors =
      if Application.get_env(:memhouse, :source_index_short_vector_list, false),
        do: Enum.drop(vectors, -1),
        else: vectors

    {:ok,
     %Result{
       value: vectors,
       usage: %{embedding_tokens: length(texts)},
       metadata: %{fixture: true}
     }}
  end

  @impl true
  def rerank(config, query, documents, opts),
    do: Deterministic.rerank(config, query, documents, opts)
end

defmodule MemHouse.Retrieval.SourceSearchTest.FailingProvider do
  @moduledoc "Fails source-search embedding while delegating capabilities unused by the test."
  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Providers.Deterministic

  @impl true
  def structured(config, messages, schema, opts),
    do: Deterministic.structured(config, messages, schema, opts)

  @impl true
  def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

  @impl true
  def embed(_config, _texts, _opts), do: {:error, :fixture_unavailable}

  @impl true
  def rerank(config, query, documents, opts),
    do: Deterministic.rerank(config, query, documents, opts)
end

defmodule MemHouse.Retrieval.SourceSearchTest do
  use MemHouse.DataCase, async: false

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine, as: GovernanceEngine
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Observations.Message
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.Reconciler
  alias MemHouse.Retrieval.SourceIndexer
  alias MemHouse.Topology.Scope

  require Ash.Query

  setup do
    original_provider = Application.get_env(:memhouse, :model_provider)
    original_roles = Application.fetch_env!(:memhouse, :model_roles)

    roles =
      Keyword.update!(original_roles, :embedder, fn config ->
        config
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "source-search-fixture")
        |> Map.put(:model_version, "1")
        |> Map.put(:embedding_dimensions, 3)
      end)

    Application.put_env(:memhouse, :model_roles, roles)
    Application.put_env(:memhouse, :model_provider, __MODULE__.Provider)
    Application.delete_env(:memhouse, :source_index_test_controller)
    Application.delete_env(:memhouse, :source_index_short_vector_list)

    on_exit(fn ->
      Application.delete_env(:memhouse, :source_index_test_controller)
      Application.delete_env(:memhouse, :source_index_short_vector_list)
      Application.put_env(:memhouse, :model_roles, original_roles)

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    :ok
  end

  test "zero-fact ingest durably schedules source indexing without an inline provider call" do
    Application.put_env(:memhouse, :source_index_test_controller, self())

    message = ingest!("source-zero-fact", "/source/zero", "Hi?", "zero", 1)
    {account_id, scope_id} = account_and_scope!("source-zero-fact", "/source/zero")

    refute_receive {:source_embedding_call, _in_transaction?, _texts}
    assert {:ok, []} = Memory.extract_message_for_account(message["id"], account_id)
    assert knowledge_count(account_id) == 0

    assert [run] = projection_runs(account_id, scope_id)

    assert run.payload ==
             MemHouse.Retrieval.MaintenancePlan.payload(
               MemHouse.Retrieval.MaintenancePlan.for_profile(:current)
             )

    refute_receive {:source_embedding_call, _in_transaction?, _texts}

    assert {:ok, completed} = execute_run(run)
    assert completed.status == "completed"
    assert_receive {:source_embedding_call, false, ["Hi?"]}
    assert indexed_at!(account_id, message["id"])
  end

  test "minimal-profile writes durably skip entity and context projection maintenance" do
    components = %{
      "extraction_batching" => %{"enabled" => false},
      "idle_dream_scheduling" => %{"enabled" => false},
      "dream_reasoning_operations" => %{"split_enabled" => false},
      "retrieval_profile" => "minimal"
    }

    {account_id, message_id, extraction_run} =
      MemHouse.Eval.VariantRuntime.with_components(components, fn ->
        message =
          ingest!(
            "source-minimal-write",
            "/source/minimal",
            "Avery owns the release checklist.",
            "one",
            1
          )

        {account_id, _scope_id} = account_and_scope!("source-minimal-write", "/source/minimal")
        [extraction_run] = extraction_runs(account_id, message["id"])
        assert extraction_run.payload["maintenance_profile"] == "minimal-v1"
        {account_id, message["id"], extraction_run}
      end)

    # The worker executes after the caller's process-local profile has been restored.
    # Its governed writes must still reuse the minimal plan captured on the durable run.
    assert MemHouse.Retrieval.MaintenancePlan.current().profile == "current"
    assert {:ok, %{status: "completed"}} = execute_run(extraction_run)

    [knowledge] = knowledge_items(account_id)

    MemHouse.Retrieval.MaintenancePlan.with_profile(:minimal, fn ->
      activate_knowledge!(account_id, knowledge.id)
    end)

    runs = projection_runs(account_id, extraction_run.scope_id)

    assert Enum.all?(runs, &(&1.payload["maintenance_profile"] == "minimal-v1"))
    assert Enum.all?(runs, &(&1.payload["stages"]["entities"] == "skipped"))
    assert Enum.all?(runs, &(&1.payload["stages"]["context_projections"] == "skipped"))

    Enum.each(runs, fn run ->
      if run.status != "completed", do: assert({:ok, %{status: "completed"}} = execute_run(run))
    end)

    assert knowledge_count(account_id) >= 1
    assert indexed_at!(account_id, message_id)
    assert derived_cache_counts(account_id) == %{mentions: 0, projections: 0, recall_documents: 1}

    before_reconciliation = projection_runs(account_id, extraction_run.scope_id) |> length()
    assert {:ok, %{scopes: 0}} = Reconciler.run(account_id)

    assert projection_runs(account_id, extraction_run.scope_id) |> length() ==
             before_reconciliation

    assert derived_cache_counts(account_id) == %{mentions: 0, projections: 0, recall_documents: 1}

    current_components = put_in(components, ["retrieval_profile"], "balanced")

    current_run =
      MemHouse.Eval.VariantRuntime.with_components(current_components, fn ->
        message =
          ingest!(
            "source-current-write",
            "/source/current",
            "Avery owns the release checklist.",
            "one",
            1
          )

        {current_account_id, current_scope_id} =
          account_and_scope!("source-current-write", "/source/current")

        assert {:ok, [knowledge]} =
                 Memory.extract_message_for_account(message["id"], current_account_id)

        activate_knowledge!(current_account_id, knowledge["id"])

        [current_run] = projection_runs(current_account_id, current_scope_id)
        current_run
      end)

    assert current_run.payload["maintenance_profile"] == "current-v1"
    assert current_run.payload["stages"]["entities"] == "scheduled"
    assert current_run.payload["stages"]["context_projections"] == "scheduled"

    assert {:ok, %{status: "completed"}} = execute_run(current_run)

    assert %{mentions: mentions, projections: projection_count, recall_documents: 1} =
             derived_cache_counts(current_run.account_id)

    assert mentions > 0
    assert projection_count > 0
  end

  test "duplicate source refresh requests coalesce on the scope bucket and one job" do
    message = ingest!("source-coalesce", "/source/coalesce", "Hello?", "one", 1)
    {account_id, scope_id} = account_and_scope!("source-coalesce", "/source/coalesce")
    stored = read_message!(account_id, message["id"])
    [scheduled] = projection_runs(account_id, scope_id)

    {first, second} =
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn _account, actor ->
          {:ok, first} =
            Pipeline.enqueue_derived_refresh(account_id, scope_id, stored.inserted_at, actor)

          {:ok, second} =
            Pipeline.enqueue_derived_refresh(account_id, scope_id, stored.inserted_at, actor)

          {first, second}
        end
      )

    assert first.id == scheduled.id
    assert second.id == scheduled.id
    assert projection_runs(account_id, scope_id) |> length() == 1
    assert oban_job_count(scheduled.idempotency_key) == 1
  end

  test "current and minimal maintenance plans do not coalesce into one replay identity" do
    _current = ingest!("source-plan-identity", "/source/plan", "current", "one", 1)

    components = %{
      "extraction_batching" => %{"enabled" => false},
      "idle_dream_scheduling" => %{"enabled" => false},
      "dream_reasoning_operations" => %{"split_enabled" => false},
      "retrieval_profile" => "minimal"
    }

    MemHouse.Eval.VariantRuntime.with_components(components, fn ->
      _minimal = ingest!("source-plan-identity", "/source/plan", "minimal", "two", 2)
    end)

    {account_id, scope_id} = account_and_scope!("source-plan-identity", "/source/plan")
    runs = projection_runs(account_id, scope_id)

    assert Enum.map(runs, & &1.payload["maintenance_profile"]) |> Enum.sort() ==
             ["current-v1", "minimal-v1"]

    assert runs |> Enum.map(& &1.idempotency_key) |> Enum.uniq() |> length() == 2
  end

  test "failed source refresh remains replayable and later succeeds" do
    message = ingest!("source-replay", "/source/replay", "release replay", "one", 1)
    {account_id, scope_id} = account_and_scope!("source-replay", "/source/replay")
    [run] = projection_runs(account_id, scope_id)

    Application.put_env(:memhouse, :model_provider, __MODULE__.FailingProvider)
    assert {:error, _workflow_error} = Pipeline.execute(run)
    failed = mark_run_failed!(run, :fixture_unavailable)
    assert failed.status == "failed"

    assert DataLayer.with_account_id(
             account_id,
             [role: :system, pipeline?: true],
             fn _account, actor ->
               Pipeline.projection_refresh_recoverable?(account_id, scope_id, actor)
             end
           )

    Application.put_env(:memhouse, :model_provider, __MODULE__.Provider)
    assert {:ok, completed} = execute_run(failed)
    assert completed.status == "completed"
    assert indexed_at!(account_id, message["id"])
  end

  test "reconciliation repairs an embedding identity change once per scope" do
    message = ingest!("source-identity", "/source/identity", "release identity", "one", 1)
    {account_id, scope_id} = account_and_scope!("source-identity", "/source/identity")
    [initial] = projection_runs(account_id, scope_id)
    assert {:ok, %{status: "completed"}} = execute_run(initial)

    roles = Application.fetch_env!(:memhouse, :model_roles)

    changed_roles =
      Keyword.update!(roles, :embedder, fn config ->
        Map.put(config, :model_version, "2")
      end)

    Application.put_env(:memhouse, :model_roles, changed_roles)

    unavailable =
      Memory.search_sources(%{
        "account_key" => "source-identity",
        "scope_path" => "/source/identity",
        "query" => "release",
        "mode" => "semantic"
      })

    assert unavailable["status"] == "unavailable"
    before = projection_runs(account_id, scope_id) |> length()

    assert {:ok, %{source_scopes: 1}} = Reconciler.run(account_id)
    assert projection_runs(account_id, scope_id) |> length() == before + 1
    assert {:ok, %{source_scopes: 0}} = Reconciler.run(account_id)
    assert projection_runs(account_id, scope_id) |> length() == before + 1

    recovery =
      account_id
      |> projection_runs(scope_id)
      |> Enum.find(&String.starts_with?(&1.payload["watermark"] || "", "sources:"))

    assert {:ok, %{status: "completed"}} = execute_run(recovery)

    ready =
      Memory.search_sources(%{
        "account_key" => "source-identity",
        "scope_path" => "/source/identity",
        "query" => "release",
        "mode" => "semantic"
      })

    assert ready["status"] == "ready"
    assert Enum.map(ready["results"], & &1["id"]) == [message["id"]]
  end

  test "one recoverable scope refresh suppresses both source and mention recovery jobs" do
    message =
      ingest!(
        "source-shared-recovery",
        "/source/shared",
        "Avery owns the release checklist.",
        "one",
        1
      )

    {account_id, scope_id} = account_and_scope!("source-shared-recovery", "/source/shared")
    assert {:ok, [knowledge]} = Memory.extract_message_for_account(message["id"], account_id)

    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        item =
          KnowledgeItem
          |> Ash.Query.filter(id == ^knowledge["id"])
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read_one!(actor: actor)

        GovernanceEngine.transition!(
          item,
          actor,
          %{state: "active", verification: "auto_verified"},
          reason: "source_shared_recovery_fixture",
          channel: "pipeline"
        )
      end
    )

    before = projection_runs(account_id, scope_id) |> length()
    assert before >= 1
    assert {:ok, %{source_scopes: 0, scopes: 0}} = Reconciler.run(account_id)
    assert projection_runs(account_id, scope_id) |> length() == before
  end

  test "source refresh indexes only its Account and scope" do
    target = ingest!("source-boundary-a", "/source/target", "release target", "one", 1)
    sibling = ingest!("source-boundary-a", "/source/sibling", "release sibling", "two", 2)
    other = ingest!("source-boundary-b", "/source/target", "release other", "one", 3)

    {account_id, scope_id} = account_and_scope!("source-boundary-a", "/source/target")

    {other_account_id, _other_scope_id} =
      account_and_scope!("source-boundary-b", "/source/target")

    [run] = projection_runs(account_id, scope_id)

    assert {:ok, %{status: "completed"}} = execute_run(run)
    assert indexed_at!(account_id, target["id"])
    refute indexed_at!(account_id, sibling["id"])
    refute indexed_at!(other_account_id, other["id"])
  end

  test "exact recall returns stable bounded citations in deterministic order" do
    older = ingest!("source-exact", "/source/visible", "release plan alpha", "one", 1)

    newer =
      ingest!(
        "source-exact",
        "/source/visible",
        "release plan beta " <> String.duplicate("detail ", 100),
        "two",
        2
      )

    result =
      Memory.search_sources(%{
        "account_key" => "source-exact",
        "scope_path" => "/source/visible",
        "query" => "release plan",
        "mode" => "exact",
        "limit" => 2,
        "excerpt_chars" => 80
      })

    assert result["status"] == "ready"
    assert result["degraded"] == false
    assert Enum.map(result["results"], & &1["id"]) == [newer["id"], older["id"]]

    assert [first | _] = result["results"]
    assert first["session_id"] == newer["session_id"]
    assert first["scope_id"] == newer["scope_id"]
    assert first["speaker_key"] == "avery"
    assert first["speaker_name"] == "Avery"
    assert first["rank"] == 1
    assert String.length(first["excerpt"]) == 80
    refute Map.has_key?(result, "total")
  end

  test "authorization is applied before source ranking and status" do
    visible = ingest!("source-auth", "/source/visible", "visible launch token", "visible", 1)
    hidden = ingest!("source-auth", "/source/hidden", "hidden launch token", "hidden", 2)

    limited_actor =
      DataLayer.with_account_key("source-auth", fn account, actor ->
        scope = read_scope!(account.id, actor, "/source/visible")
        peer = read_peer!(account.id, actor)

        %{
          actor
          | role: :reader,
            peer_id: peer.id,
            scope_ids: [scope.id],
            identity_kind: :api_key
        }
      end)

    result =
      Memory.search_sources(
        %{
          "scope_path" => "/source/visible",
          "query" => "launch token",
          "mode" => "exact"
        },
        limited_actor
      )

    assert Enum.map(result["results"], & &1["id"]) == [visible["id"]]
    refute hidden["id"] in Enum.map(result["results"], & &1["id"])

    empty =
      Memory.search_sources(
        %{"scope_path" => "/source/visible", "query" => "hidden", "mode" => "exact"},
        limited_actor
      )

    assert empty["results"] == []
    assert empty["status"] == "ready"
  end

  test "semantic index refresh is replay-safe and reports unavailable, ready, and failed" do
    message = ingest!("source-semantic", "/source/semantic", "release checklist", "one", 1)

    unavailable =
      Memory.search_sources(%{
        "account_key" => "source-semantic",
        "scope_path" => "/source/semantic",
        "query" => "release outage",
        "mode" => "semantic"
      })

    assert unavailable["status"] == "unavailable"
    assert unavailable["results"] == []

    {account_id, scope_id} = account_and_scope!("source-semantic", "/source/semantic")

    assert {:ok, %{indexed: 1, embedding_identity: identity}} =
             SourceIndexer.refresh_scope(account_id, scope_id)

    assert identity == %{
             provider: "fixture",
             model: "source-search-fixture",
             version: "1",
             dimensions: 3
           }

    assert {:ok, %{indexed: 0, embedding_identity: ^identity}} =
             SourceIndexer.refresh_scope(account_id, scope_id)

    ready =
      Memory.search_sources(%{
        "account_key" => "source-semantic",
        "scope_path" => "/source/semantic",
        "query" => "release",
        "mode" => "semantic"
      })

    assert ready["status"] == "ready"
    assert [%{"id" => id, "rank" => 1}] = ready["results"]
    assert id == message["id"]

    fallback =
      Memory.search_sources(%{
        "account_key" => "source-semantic",
        "scope_path" => "/source/semantic",
        "query" => "release",
        "mode" => "not-a-mode"
      })

    assert fallback["mode"] == "semantic"
    assert fallback["status"] == "ready"

    Application.put_env(:memhouse, :model_provider, __MODULE__.FailingProvider)
    assert {:error, :fixture_unavailable} = SourceIndexer.rebuild_scope(account_id, scope_id)

    failed =
      Memory.search_sources(%{
        "account_key" => "source-semantic",
        "scope_path" => "/source/semantic",
        "query" => "release after outage",
        "mode" => "semantic"
      })

    assert failed["status"] == "failed"
    assert failed["failure_class"] == "fixture_unavailable"
    assert failed["results"] == []

    # The failed rebuild did not erase the last successful derived vector.
    assert indexed_at!(account_id, message["id"])
  end

  test "source indexing rejects a short provider vector list before writing" do
    first = ingest!("source-cardinality", "/source/cardinality", "release one", "one", 1)
    second = ingest!("source-cardinality", "/source/cardinality", "release two", "two", 2)
    {account_id, scope_id} = account_and_scope!("source-cardinality", "/source/cardinality")

    Application.put_env(:memhouse, :source_index_short_vector_list, true)

    assert {:error, {:embedding_cardinality_mismatch, %{expected: 2, actual: 1}}} =
             SourceIndexer.rebuild_scope(account_id, scope_id)

    refute indexed_at!(account_id, first["id"])
    refute indexed_at!(account_id, second["id"])
  end

  test "erasing the canonical message removes exact and semantic source hits" do
    message = ingest!("source-erase", "/source/erase", "garden schedule", "one", 1)
    {account_id, scope_id} = account_and_scope!("source-erase", "/source/erase")
    assert {:ok, %{indexed: 1}} = SourceIndexer.rebuild_scope(account_id, scope_id)

    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        record =
          Message
          |> Ash.Query.filter(id == ^message["id"])
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read_one!(actor: actor)

        record
        |> Ash.Changeset.for_destroy(:erase)
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.destroy!(actor: actor)
      end
    )

    result =
      Memory.search_sources(%{
        "account_key" => "source-erase",
        "scope_path" => "/source/erase",
        "query" => "garden",
        "mode" => "exact"
      })

    assert result["status"] == "empty"
    assert result["results"] == []
  end

  test "bounded Ask recall does not read source messages without explicit permission" do
    message =
      ingest!("source-planner-denied", "/source/planner", "garden schedule is Friday", "one", 1)

    result =
      Memory.ask(%{
        "account_key" => "source-planner-denied",
        "scope_path" => "/source/planner",
        "question" => "What is the garden schedule?",
        "effort" => "low"
      })

    assert result["recall"]["used"] == true
    assert result["recall"]["source_recall_permitted"] == false

    refute Enum.any?(result["recall_evidence"], fn evidence ->
             evidence["id"] == message["id"] or
               evidence["evidence_type"] == "source_message"
           end)

    refute Enum.any?(result["recall"]["outcomes"], fn outcome ->
             outcome["tool"] in ["source_exact", "source_semantic"]
           end)
  end

  test "bounded Ask recall admits explicitly permitted source evidence without mutating memory" do
    message = ingest!("source-planner", "/source/planner", "garden schedule is Friday", "one", 1)

    before_count = message_count!("source-planner")

    result =
      Memory.ask(%{
        "account_key" => "source-planner",
        "scope_path" => "/source/planner",
        "question" => "What is the garden schedule?",
        "effort" => "low",
        "include_source_recall" => true
      })

    assert result["recall"]["used"] == true
    assert result["recall"]["effort"] == "low"
    assert result["recall"]["source_recall_permitted"] == true
    assert result["recall"]["tool_calls"] <= 3

    assert Enum.any?(result["recall_evidence"], fn evidence ->
             evidence["id"] == message["id"] and
               evidence["evidence_type"] == "source_message" and
               evidence["candidate_type"] == "source_message" and
               evidence["source_message_ids"] == [message["id"]]
           end)

    assert result["recall"]["answer_context_adaptive_items"] == 1

    assert message["id"] in (result["recall_evidence"]
                             |> Enum.take(result["recall"]["answer_context_items"])
                             |> Enum.map(& &1["id"]))

    assert message_count!("source-planner") == before_count
  end

  defp ingest!(account_key, scope_path, content, session_id, second) do
    {:ok, message} =
      Memory.ingest_message(%{
        "account_key" => account_key,
        "scope_path" => scope_path,
        "session_id" => session_id,
        "peer_key" => "avery",
        "peer_name" => "Avery",
        "content" => content,
        "occurred_at" => DateTime.add(~U[2026-01-01 00:00:00Z], second, :second)
      })

    message
  end

  defp account_and_scope!(account_key, scope_path) do
    DataLayer.with_account_key(account_key, fn account, actor ->
      {account.id, read_scope!(account.id, actor, scope_path).id}
    end)
  end

  defp read_scope!(account_id, actor, path) do
    Scope
    |> Ash.Query.filter(path == ^path)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp read_peer!(account_id, actor) do
    MemHouse.Accounts.Peer
    |> Ash.Query.filter(key == "avery")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp projection_runs(account_id, scope_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        PipelineRun
        |> Ash.Query.filter(kind == "projection_refresh" and target_id == ^scope_id)
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor, page: [limit: 100])
        |> Map.fetch!(:results)
      end
    )
  end

  defp extraction_runs(account_id, message_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        PipelineRun
        |> Ash.Query.filter(kind == "extraction" and target_id == ^message_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor, page: [limit: 10])
        |> Map.fetch!(:results)
      end
    )
  end

  defp knowledge_items(account_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        KnowledgeItem
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)
      end
    )
  end

  defp execute_run(run) do
    actor =
      DataLayer.with_account_id(
        run.account_id,
        [role: :system, pipeline?: true],
        fn _account, actor -> actor end
      )

    run
    |> Ash.Changeset.for_update(:execute, %{})
    |> Ash.Changeset.set_tenant(run.account_id)
    |> Ash.update(actor: actor)
  end

  defp mark_run_failed!(run, error) do
    actor =
      DataLayer.with_account_id(
        run.account_id,
        [role: :system, pipeline?: true],
        fn _account, actor -> actor end
      )

    run
    |> Ash.Changeset.for_update(:mark_failed, %{error: error})
    |> Ash.Changeset.set_tenant(run.account_id)
    |> Ash.update!(actor: actor)
  end

  defp read_message!(account_id, message_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        Message
        |> Ash.Query.filter(id == ^message_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read_one!(actor: actor)
      end
    )
  end

  defp knowledge_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        MemHouse.Repo,
        "SELECT count(*) FROM knowledge_items WHERE account_id = $1",
        [Ecto.UUID.dump!(account_id)]
      )

    count
  end

  defp activate_knowledge!(account_id, knowledge_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        item =
          KnowledgeItem
          |> Ash.Query.filter(id == ^knowledge_id)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read_one!(actor: actor)

        GovernanceEngine.transition!(
          item,
          actor,
          %{state: "active", verification: "auto_verified"},
          reason: "minimal_profile_maintenance_fixture",
          channel: "pipeline"
        )
      end
    )
  end

  defp derived_cache_counts(account_id) do
    %{rows: [[mentions, projections, recall_documents]]} =
      Ecto.Adapters.SQL.query!(
        MemHouse.Repo,
        """
        SELECT (SELECT count(*) FROM entity_mentions WHERE account_id = $1),
               (SELECT count(*) FROM projections WHERE account_id = $1),
               (SELECT count(*) FROM recall_documents WHERE account_id = $1)
        """,
        [Ecto.UUID.dump!(account_id)]
      )

    %{mentions: mentions, projections: projections, recall_documents: recall_documents}
  end

  defp oban_job_count(idempotency_key) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        MemHouse.Repo,
        "SELECT count(*) FROM oban_jobs WHERE args->>'idempotency_key' = $1",
        [idempotency_key]
      )

    count
  end

  defp indexed_at!(account_id, message_id) do
    DataLayer.with_account_id(account_id, fn _account, %Actor{} = actor ->
      message =
        Message
        |> Ash.Query.filter(id == ^message_id)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read_one!(actor: %Actor{actor | role: :system, pipeline?: true})

      not is_nil(message.source_indexed_at)
    end)
  end

  defp message_count!(account_key) do
    DataLayer.with_account_key(account_key, fn account, _actor ->
      %{rows: [[count]]} =
        Ecto.Adapters.SQL.query!(
          MemHouse.Repo,
          "SELECT count(*) FROM messages WHERE account_id = $1",
          [Ecto.UUID.dump!(account.id)]
        )

      count
    end)
  end
end
