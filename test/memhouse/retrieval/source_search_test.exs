# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.SourceSearchTest.Provider do
  @moduledoc false
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
    vectors =
      Enum.map(texts, fn text ->
        normalized = String.downcase(text)

        [
          if(String.contains?(normalized, "release"), do: 1.0, else: 0.0),
          if(String.contains?(normalized, "garden"), do: 1.0, else: 0.0),
          0.1
        ]
      end)

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
  @moduledoc false
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
  alias MemHouse.Memory
  alias MemHouse.Observations.Message
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

    on_exit(fn ->
      Application.put_env(:memhouse, :model_roles, original_roles)

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    :ok
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
    assert {:ok, %{indexed: 1}} = SourceIndexer.refresh_scope(account_id, scope_id)
    assert {:ok, %{indexed: 0}} = SourceIndexer.refresh_scope(account_id, scope_id)

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
               evidence["candidate_type"] == "source_message"
           end)

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
