# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.ProjectionRefreshTelemetryTest.Provider do
  @moduledoc false

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result
  alias MemHouse.Model.Providers.Deterministic

  @impl true
  defdelegate structured(config, messages, schema, opts), to: Deterministic

  @impl true
  defdelegate chat(config, messages, opts), to: Deterministic

  @impl true
  def embed(_config, texts, _opts) do
    vectors =
      Enum.map(texts, fn text ->
        <<seed::unsigned-32, _::binary>> = :crypto.hash(:sha256, text)
        for index <- 0..1023, do: (rem(seed + index * 104_729, 10_000) + 1) / 10_001
      end)

    {:ok, %Result{value: vectors, usage: %{embedding_tokens: 0}, metadata: %{fixture: true}}}
  end

  @impl true
  defdelegate rerank(config, query, documents, opts), to: Deterministic
end

defmodule MemHouse.ProjectionRefreshTelemetryTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MemHouse.DataLayer
  alias MemHouse.Memory
  alias MemHouse.Model.ProviderCircuit
  alias MemHouse.Repo
  alias MemHouse.TestSupport.AccountCleanup

  setup do
    :ok = Supervisor.terminate_child(MemHouseWeb.Telemetry, :telemetry_poller)

    on_exit(fn ->
      {:ok, _poller} = Supervisor.restart_child(MemHouseWeb.Telemetry, :telemetry_poller)
    end)

    :ok = Sandbox.checkout(Repo, sandbox: false)
    on_exit(fn -> Sandbox.checkin(Repo) end)
  end

  test "the production projection job reports the persisted scope snapshot" do
    account_key = "projection-telemetry-#{System.unique_integer([:positive])}"
    original = runtime_config()
    handler = attach_projection_refresh_telemetry()

    try do
      install_provider!(original)

      assert {:ok, message} =
               Memory.ingest_message(%{
                 "account_key" => account_key,
                 "session_id" => "telemetry-session",
                 "scope_path" => "/projection/telemetry",
                 "peer_key" => "avery",
                 "role" => "user",
                 "content" => "Avery prefers concise weekly release summaries."
               })

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :ingest)

      assert %{success: 1, failure: 0, cancelled: 0, discard: 0} =
               Oban.drain_queue(queue: :projection, with_scheduled: true)

      assert_receive {^handler, measurements, metadata}, 5_000

      {account_id, persisted} =
        DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                     _actor ->
          {account.id,
           MemHouse.Retrieval.Coverage.scope(account.id, message["scope_id"], nil, true)}
        end)

      assert persisted.statement_count == 1
      assert persisted.embedded_count == 1
      assert measurements.indexed == 1
      assert measurements.statements == persisted.statement_count
      assert measurements.embedded == persisted.embedded_count
      assert measurements.mentions == persisted.mention_count
      assert measurements.coverage == persisted.coverage
      assert metadata.account_id == account_id
      assert metadata.scope_id == message["scope_id"]
    after
      cleanup_account_jobs(account_key)
      restore_runtime_config(original)
    end
  end

  defp install_provider!(original) do
    roles =
      Keyword.update!(original.roles, :embedder, fn role ->
        role
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "projection-telemetry-fixture")
        |> Map.put(:model_version, "1")
        |> Map.put(:embedding_dimensions, 1024)
      end)

    Application.put_env(:memhouse, :model_provider, __MODULE__.Provider)
    Application.put_env(:memhouse, :model_roles, roles)
    ProviderCircuit.reset()
  end

  defp runtime_config do
    %{
      provider: Application.get_env(:memhouse, :model_provider),
      roles: Application.fetch_env!(:memhouse, :model_roles)
    }
  end

  defp restore_runtime_config(original) do
    if original.provider do
      Application.put_env(:memhouse, :model_provider, original.provider)
    else
      Application.delete_env(:memhouse, :model_provider)
    end

    Application.put_env(:memhouse, :model_roles, original.roles)
    ProviderCircuit.reset()
  end

  defp cleanup_account_jobs(account_key) do
    DataLayer.with_account_key(account_key, [role: :system, pipeline?: true], fn account,
                                                                                 _actor ->
      AccountCleanup.delete!(account.id)
    end)
  end

  defp attach_projection_refresh_telemetry do
    handler = {__MODULE__, self(), :projection_refresh}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :retrieval, :projection_refresh],
        fn _event, measurements, metadata, _config ->
          send(parent, {handler, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end
end
