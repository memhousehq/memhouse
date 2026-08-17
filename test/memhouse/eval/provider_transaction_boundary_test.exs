# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ProviderTransactionBoundaryTest.Provider do
  @moduledoc """
  Offline evaluation provider that rejects calls made while the caller owns a
  database transaction.

  The test case checks out an unsandboxed connection so `Repo.in_transaction?/0`
  measures the evaluation helper's boundary rather than ExUnit's rollback
  transaction. Generation delegates to the deterministic provider; embeddings
  are fixed finite vectors whose width follows the resolved role.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Model.Providers.Deterministic
  alias MemHouse.Repo

  @doc "Rejects transactional generation calls, otherwise returns deterministic structured output."
  @impl true
  def structured(config, messages, schema, opts) do
    assert_outside_transaction!(:structured)
    Deterministic.structured(config, messages, schema, opts)
  end

  @doc "Rejects transactional chat calls, otherwise returns deterministic chat output."
  @impl true
  def chat(config, messages, opts) do
    assert_outside_transaction!(:chat)
    Deterministic.chat(config, messages, opts)
  end

  @doc "Rejects transactional embedding calls, otherwise returns fixed vectors of the configured width."
  @impl true
  def embed(config, texts, opts) do
    assert_outside_transaction!({:embed, Keyword.get(opts, :input_type, :passage)})
    dimensions = config.embedding_dimensions || 3
    vectors = Enum.map(texts, fn _text -> List.duplicate(0.25, dimensions) end)

    {:ok,
     %Result{
       value: vectors,
       usage: %{embedding_tokens: length(texts)},
       metadata: %{fixture: true}
     }}
  end

  @doc "Rejects transactional reranking calls, otherwise delegates to the deterministic provider."
  @impl true
  def rerank(config, query, documents, opts) do
    assert_outside_transaction!(:rerank)
    Deterministic.rerank(config, query, documents, opts)
  end

  defp assert_outside_transaction!(operation) do
    in_transaction? = Repo.in_transaction?()

    if controller = Application.get_env(:memhouse, :provider_transaction_boundary_controller) do
      send(controller, {:provider_transaction_boundary, operation, in_transaction?})
    end

    if in_transaction? do
      raise "evaluation provider #{operation} call ran inside a database transaction"
    end
  end
end

defmodule MemHouse.Eval.ProviderTransactionBoundaryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MemHouse.DataLayer
  alias MemHouse.Eval.{Adapter, Ingest, Runner}
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Repo

  require Ash.Query

  setup do
    :ok = Supervisor.terminate_child(MemHouseWeb.Telemetry, :telemetry_poller)

    on_exit(fn ->
      {:ok, _poller} = Supervisor.restart_child(MemHouseWeb.Telemetry, :telemetry_poller)
    end)

    :ok = Sandbox.checkout(Repo, sandbox: false)
    on_exit(fn -> Sandbox.checkin(Repo) end)
  end

  test "batched evaluation commits the run before invoking the extraction provider" do
    account_key = unique_account_key("batch")
    original = runtime_config()

    try do
      install_boundary_provider!(original, batching?: true)
      dataset = dataset("batch-boundary")

      assert [{_source, {:ok, message, knowledge}}] =
               Ingest.run(hd(dataset.cases).messages, account_key, "/eval/batch",
                 extraction_batching: true
               )

      assert knowledge != []

      DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                   actor ->
        run =
          PipelineRun
          |> Ash.Query.filter(target_id == ^message["id"])
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: actor)

        assert run.status == "completed"
      end)
    after
      cleanup_account!(account_key)
      restore_runtime_config(original)
    end

    assert runtime_config() == original
  end

  test "semantic evaluation refresh commits scope lookup before invoking the embedder" do
    account_key = unique_account_key("semantic")
    original = runtime_config()

    try do
      install_boundary_provider!(original, batching?: false)

      report =
        Runner.run(dataset("semantic-boundary"),
          account_key: account_key,
          run_id: "provider-boundary",
          limit_questions: 0,
          refresh_semantic_index: true,
          extraction_batching: false
        )

      assert report["messages_ingested"] == 1

      DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                   actor ->
        indexed =
          KnowledgeItem
          |> Ash.Query.filter(not is_nil(embedding))
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)

        assert length(indexed) == 1
      end)
    after
      cleanup_account!(account_key)
      restore_runtime_config(original)
    end

    assert runtime_config() == original
  end

  test "evaluated semantic retrieval embeds and reranks outside database transactions" do
    account_key = unique_account_key("semantic-question")
    original = runtime_config()

    try do
      install_boundary_provider!(original, batching?: false)

      report =
        Runner.run(dataset("semantic-question-boundary", [question()]),
          account_key: account_key,
          run_id: "provider-question-boundary",
          profile: "thorough",
          strategies: ["semantic"],
          deadline: "disabled",
          refresh_semantic_index: true,
          extraction_batching: false
        )

      assert report["evaluated"] == 1
      assert report["failed"] == 0
      assert report["questions_attempted"] == 1

      assert get_in(report, [
               "cases",
               Access.at(0),
               "questions",
               Access.at(0),
               "contributed_strategies"
             ]) == [
               "semantic"
             ]

      assert_received {:provider_transaction_boundary, {:embed, :query}, false}
      assert_received {:provider_transaction_boundary, :rerank, false}
    after
      cleanup_account!(account_key)
      restore_runtime_config(original)
    end

    assert runtime_config() == original
  end

  defp dataset(id, questions \\ []) do
    Adapter.normalize(
      %{
        "benchmark" => "memhouse",
        "id" => id,
        "messages" => [
          %{
            "id" => "message-1",
            "session_id" => "session-1",
            "peer_key" => "avery",
            "role" => "user",
            "content" => "Avery prefers concise evaluation reports."
          }
        ],
        "questions" => questions
      },
      benchmark: "memhouse"
    )
  end

  defp question do
    %{
      "id" => "question-1",
      "question" => "What kind of reports does Avery prefer?",
      "answer" => "concise evaluation reports",
      "evidence" => ["message-1"]
    }
  end

  defp install_boundary_provider!(original, opts) do
    roles =
      Keyword.update!(original.roles, :embedder, fn config ->
        config
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "provider-boundary-fixture")
        |> Map.put(:model_version, "1")
        |> Map.put(:embedding_dimensions, 3)
      end)

    Application.put_env(:memhouse, :model_provider, __MODULE__.Provider)
    Application.put_env(:memhouse, :model_roles, roles)
    Application.put_env(:memhouse, :provider_transaction_boundary_controller, self())

    Application.put_env(
      :memhouse,
      :extraction_batching,
      Keyword.put(original.batching, :enabled, Keyword.fetch!(opts, :batching?))
    )
  end

  defp runtime_config do
    %{
      provider: Application.get_env(:memhouse, :model_provider),
      boundary_controller:
        Application.get_env(:memhouse, :provider_transaction_boundary_controller),
      roles: Application.fetch_env!(:memhouse, :model_roles),
      batching: Application.fetch_env!(:memhouse, :extraction_batching)
    }
  end

  defp restore_runtime_config(original) do
    if original.provider do
      Application.put_env(:memhouse, :model_provider, original.provider)
    else
      Application.delete_env(:memhouse, :model_provider)
    end

    Application.put_env(:memhouse, :model_roles, original.roles)
    Application.put_env(:memhouse, :extraction_batching, original.batching)

    if original.boundary_controller do
      Application.put_env(
        :memhouse,
        :provider_transaction_boundary_controller,
        original.boundary_controller
      )
    else
      Application.delete_env(:memhouse, :provider_transaction_boundary_controller)
    end
  end

  defp cleanup_account!(account_key) do
    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                 _actor ->
      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM oban_jobs WHERE args ->> 'tenant' = $1",
        [account.id]
      )

      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM accounts WHERE id = $1", [
        Ecto.UUID.dump!(account.id)
      ])
    end)
  end

  defp unique_account_key(suffix),
    do: "eval-provider-boundary-#{suffix}-#{System.unique_integer([:positive])}"
end
