# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.CampaignAdmissionTest.Provider do
  @moduledoc "Records provider callbacks without contacting a model."

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result

  def start_link, do: Agent.start_link(fn -> 0 end, name: __MODULE__)
  def calls, do: Agent.get(__MODULE__, & &1)

  @impl true
  def structured(_config, _messages, _schema, _opts) do
    Agent.update(__MODULE__, &(&1 + 1))
    {:ok, %Result{value: %{}, usage: %{input_tokens: 1, output_tokens: 1}}}
  end

  @impl true
  def chat(_config, _messages, _opts) do
    Agent.update(__MODULE__, &(&1 + 1))
    {:ok, %Result{value: "answer", usage: %{input_tokens: 1, output_tokens: 1}}}
  end

  @impl true
  def embed(_config, _texts, _opts) do
    Agent.update(__MODULE__, &(&1 + 1))
    {:ok, %Result{value: [[1.0]], usage: %{embedding_tokens: 1}}}
  end

  @impl true
  def rerank(_config, _query, _documents, _opts) do
    Agent.update(__MODULE__, &(&1 + 1))
    {:ok, %Result{value: [], usage: %{input_tokens: 1, output_tokens: 0}}}
  end
end

defmodule MemHouse.Model.CampaignAdmissionTest.RepairSchema do
  @moduledoc false

  def json_schema, do: %{"type" => "object"}
  def cast(_object, _context), do: {:error, ["invalid shape"]}
end

defmodule MemHouse.Model.CampaignAdmissionTest.StubPlug do
  @moduledoc false
  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    send(Keyword.fetch!(opts, :test_pid), :campaign_http_call)
    if delay = Keyword.get(opts, :delay), do: Process.sleep(delay)

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(Keyword.get(opts, :status, 200), Jason.encode!(opts[:body] || %{}))
  end
end

defmodule MemHouse.Model.CampaignAdmissionTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint MemHouseWeb.Endpoint

  alias MemHouse.Model.CampaignAdmission
  alias MemHouse.Model.CampaignAdmissionTest.Provider
  alias MemHouse.Model.CampaignAdmissionTest.StubPlug
  alias MemHouse.Model.CampaignBuild
  alias MemHouse.Model.Config
  alias MemHouse.Model.Gateway
  alias MemHouse.Model.Providers.ReqLLM
  alias MemHouse.Model.StructuredGenerator

  @target_revision "ed3f3600fdab9b09abdb40e7ee3492e334f6df72"
  @run_id "issue-287-pg0-run-1"
  @backend %{"engine" => "postgres", "mode" => "pg0", "sqlite" => "unsupported"}

  setup do
    Application.ensure_all_started(:bandit)
    Application.ensure_all_started(:req_llm)
    unless Process.whereis(CampaignAdmission), do: start_supervised!(CampaignAdmission)

    unless Process.whereis(MemHouse.Model.ProviderTaskSupervisor) do
      start_supervised!({Task.Supervisor, name: MemHouse.Model.ProviderTaskSupervisor})
    end

    System.put_env("MEMHOUSE_CAMPAIGN_TEST_KEY", "local-test-key")

    on_exit(fn ->
      if Process.whereis(MemHouse.Supervisor) do
        :ok = Supervisor.terminate_child(MemHouse.Supervisor, CampaignAdmission)
        {:ok, _pid} = Supervisor.restart_child(MemHouse.Supervisor, CampaignAdmission)
      end
    end)

    {:ok, provider} = Provider.start_link()
    on_exit(fn -> if Process.alive?(provider), do: Agent.stop(provider) end)

    previous_roles = Application.fetch_env!(:memhouse, :model_roles)
    previous_circuit = Application.fetch_env!(:memhouse, :ingest_provider_circuit)
    Application.put_env(:memhouse, :ingest_provider_circuit, enabled: false)

    Application.put_env(
      :memhouse,
      :model_roles,
      Keyword.put(previous_roles, :ingest_extractor, %{
        provider: "openrouter",
        model: "openai/gpt-oss-120b",
        model_version: "campaign-v1",
        prompt_version: "extract-14",
        pipeline_version: "f5-1",
        options: %{
          "api_key_ref" => "env:MEMHOUSE_CAMPAIGN_TEST_KEY",
          "base_url" => "https://openrouter.ai/api/v1",
          "max_tokens" => 8,
          "upstream_route" => "openai"
        }
      })
    )

    on_exit(fn ->
      System.delete_env("MEMHOUSE_CAMPAIGN_TEST_KEY")
      Application.put_env(:memhouse, :model_roles, previous_roles)
      Application.put_env(:memhouse, :ingest_provider_circuit, previous_circuit)
    end)

    :ok
  end

  test "public health reports content-safe inactive campaign admission" do
    response = get(build_conn(), "/api/health") |> json_response(200)

    assert response["campaign_admission"] == %{"active" => false, "status" => "inactive"}
    refute inspect(response) =~ "account_id"
    refute inspect(response) =~ "credential"
  end

  test "public health stays non-blocking while campaign admission is unavailable" do
    admission = Process.whereis(CampaignAdmission)
    :ok = :sys.suspend(admission)

    on_exit(fn ->
      if Process.alive?(admission), do: :sys.resume(admission)
    end)

    response = Task.async(fn -> health_admission() end) |> Task.await(100)
    assert response["status"] in ["inactive", "recovering"]
  end

  test "public health reports every admitted role with exact caps and zero durable usage" do
    {path, digest} =
      write_packet!(packet(requests: 0, input_tokens: 0, output_tokens: 0, usd: 0.0))

    assert {:ok, identity} = activate(path, digest)

    admission =
      get(build_conn(), "/api/health")
      |> json_response(200)
      |> Map.fetch!("campaign_admission")

    assert admission["active"] == true
    assert admission["identity"] == identity
    assert admission["digest"] == digest
    assert Map.keys(admission["role_reserved"]) |> Enum.sort() == paid_role_names()
    assert Map.keys(admission["role_usage"]) |> Enum.sort() == paid_role_names()

    assert admission["role_reserved"]["target.ingest_extractor"] == %{
             "requests" => 0,
             "input_tokens" => 0,
             "output_tokens" => 0,
             "reranker_input_tokens" => 0,
             "usd_micros" => 0
           }

    assert admission["role_usage"]["target.ingest_extractor"] == %{
             "attempts" => 0,
             "errors" => 0,
             "unmetered_attempts" => 0,
             "pending_attempts" => 0,
             "in_flight" => 0,
             "input_tokens" => 0,
             "output_tokens" => 0,
             "first_occurred_at" => nil,
             "last_occurred_at" => nil
           }
  end

  test "public health durably accounts a successful real gateway dispatch" do
    endpoint = start_http_stub(body: completion(%{}))
    configure_extractor_endpoint(endpoint)

    campaign =
      packet(requests: 1, input_tokens: 10_000)
      |> put_in(["execution", "routes", "target.ingest_extractor", "endpoint"], endpoint)

    {path, digest} = write_packet!(campaign)
    assert {:ok, identity} = activate(path, digest)

    assert {:ok, %{}, _config} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{},
               campaign_identity: identity
             )

    assert_receive :campaign_http_call

    first = health_admission()
    second = health_admission()
    assert first == second

    assert first["role_reserved"]["target.ingest_extractor"] == %{
             "requests" => 1,
             "input_tokens" => 10_000,
             "output_tokens" => 8,
             "reranker_input_tokens" => 0,
             "usd_micros" => 1_000_000
           }

    assert first["role_usage"]["target.ingest_extractor"] == %{
             "attempts" => 1,
             "errors" => 0,
             "unmetered_attempts" => 0,
             "pending_attempts" => 0,
             "in_flight" => 0,
             "input_tokens" => 1,
             "output_tokens" => 1,
             "first_occurred_at" =>
               first["role_usage"]["target.ingest_extractor"]["first_occurred_at"],
             "last_occurred_at" =>
               first["role_usage"]["target.ingest_extractor"]["last_occurred_at"]
           }

    assert is_binary(first["role_usage"]["target.ingest_extractor"]["first_occurred_at"])
    refute Map.has_key?(first, "provider_totals")
  end

  test "public role_reserved remains the admitted cap after a smaller reservation" do
    {path, digest} = write_packet!(packet(requests: 3, input_tokens: 100))
    assert {:ok, identity} = activate(path, digest)

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:ingest_extractor, %{}),
               :structured,
               1,
               8,
               ReqLLM,
               campaign_identity: identity
             )

    assert health_admission()["role_reserved"]["target.ingest_extractor"]["requests"] == 3
    assert health_admission()["role_reserved"]["target.ingest_extractor"]["input_tokens"] == 100
    assert CampaignAdmission.status().role_reserved["target.ingest_extractor"].requests == 1
  end

  test "public health reconciles a returned provider error as unmetered" do
    endpoint = start_http_stub(status: 500)
    configure_extractor_endpoint(endpoint)

    campaign =
      packet(requests: 1, input_tokens: 10_000)
      |> put_in(["execution", "routes", "target.ingest_extractor", "endpoint"], endpoint)

    {path, digest} = write_packet!(campaign)
    assert {:ok, identity} = activate(path, digest)

    assert {:error, _reason} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{},
               campaign_identity: identity
             )

    assert_receive :campaign_http_call

    assert health_admission()["role_usage"]["target.ingest_extractor"]
           |> Map.take([
             "attempts",
             "errors",
             "unmetered_attempts",
             "pending_attempts",
             "in_flight"
           ]) ==
             %{
               "attempts" => 1,
               "errors" => 1,
               "unmetered_attempts" => 1,
               "pending_attempts" => 0,
               "in_flight" => 0
             }
  end

  test "public health reconciles a successful response without provider usage" do
    endpoint = start_http_stub(body: completion(%{}) |> Map.delete("usage"))
    configure_extractor_endpoint(endpoint)

    campaign =
      packet(requests: 1, input_tokens: 10_000)
      |> put_in(["execution", "routes", "target.ingest_extractor", "endpoint"], endpoint)

    {path, digest} = write_packet!(campaign)
    assert {:ok, identity} = activate(path, digest)

    assert {:ok, %{}, _config} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{},
               campaign_identity: identity
             )

    usage = health_admission()["role_usage"]["target.ingest_extractor"]
    assert usage["attempts"] == 1
    assert usage["errors"] == 0
    assert usage["unmetered_attempts"] == 1
    assert usage["input_tokens"] == 0
    assert usage["output_tokens"] == 0
  end

  test "startup recovery preserves completed usage without reopening campaign spend" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))
    opts = activation_opts(path)
    assert {:ok, identity} = CampaignAdmission.activate(path, digest, opts)

    assert {:ok, reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:ingest_extractor, %{}),
               :structured,
               1,
               1,
               ReqLLM,
               campaign_identity: identity
             )

    assert :ok = CampaignAdmission.dispatch(reservation)

    assert :ok =
             CampaignAdmission.complete(
               reservation,
               {:ok,
                %MemHouse.Model.Provider.Result{
                  value: %{},
                  usage: %{input_tokens: 1, output_tokens: 1}
                }}
             )

    assert :ok =
             CampaignAdmission.complete(
               reservation,
               {:ok,
                %MemHouse.Model.Provider.Result{
                  value: %{},
                  usage: %{input_tokens: 1, output_tokens: 1}
                }}
             )

    before_restart = health_admission()
    assert before_restart["role_usage"]["target.ingest_extractor"]["attempts"] == 1
    assert before_restart["role_usage"]["target.ingest_extractor"]["input_tokens"] == 1
    restore_campaign_after_test(path, digest, opts)
    restart_campaign_admission!()

    assert health_admission() == before_restart

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_already_consumed}} =
             CampaignAdmission.reserve(
               Config.resolve(:ingest_extractor, %{}),
               :structured,
               1,
               1,
               ReqLLM,
               campaign_identity: identity
             )
  end

  test "startup recovery accepts a caller cancelled before provider dispatch" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))
    opts = activation_opts(path)
    assert {:ok, identity} = CampaignAdmission.activate(path, digest, opts)
    parent = self()

    caller =
      spawn(fn ->
        result =
          CampaignAdmission.reserve(
            Config.resolve(:ingest_extractor, %{}),
            :structured,
            1,
            1,
            ReqLLM,
            campaign_identity: identity
          )

        send(parent, {:reserved_before_dispatch, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:reserved_before_dispatch, ^caller, {:ok, _reservation}}
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

    usage = await_usage_finalization(50)
    assert usage["attempts"] == 0
    assert usage["errors"] == 0
    assert usage["unmetered_attempts"] == 0

    before_restart = health_admission()
    restore_campaign_after_test(path, digest, opts)
    restart_campaign_admission!()

    assert health_admission() == before_restart
  end

  test "an owner can durably cancel before dispatch while remaining alive" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))
    assert {:ok, identity} = activate(path, digest)
    admission = Process.whereis(CampaignAdmission)
    {:monitors, monitors_before} = Process.info(admission, :monitors)

    assert {:ok, reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:ingest_extractor, %{}),
               :structured,
               1,
               1,
               ReqLLM,
               campaign_identity: identity
             )

    assert :ok = CampaignAdmission.cancel(reservation)
    assert Process.alive?(self())
    assert Process.info(admission, :monitors) == {:monitors, monitors_before}

    usage = health_admission()["role_usage"]["target.ingest_extractor"]
    assert usage["attempts"] == 0
    assert usage["pending_attempts"] == 0
    assert usage["in_flight"] == 0

    first = health_admission()
    Process.sleep(10)
    assert health_admission() == first
    assert CampaignAdmission.status().role_reserved["target.ingest_extractor"].requests == 1
  end

  test "a monitored caller ledger failure preserves the process and old snapshot" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))
    opts = activation_opts(path)
    ledger_dir = Keyword.fetch!(opts, :ledger_dir)
    saved_ledger_dir = ledger_dir <> ".saved"
    assert {:ok, identity} = CampaignAdmission.activate(path, digest, opts)
    parent = self()

    caller =
      spawn(fn ->
        result =
          CampaignAdmission.reserve(
            Config.resolve(:ingest_extractor, %{}),
            :structured,
            1,
            1,
            ReqLLM,
            campaign_identity: identity
          )

        send(parent, {:ledger_failure_reservation, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:ledger_failure_reservation, ^caller, {:ok, _reservation}}
    before_failure = health_admission()
    File.rename!(ledger_dir, saved_ledger_dir)
    File.write!(ledger_dir, "blocks ledger directory")

    on_exit(fn ->
      File.rm(ledger_dir)
      File.rename(saved_ledger_dir, ledger_dir)
    end)

    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    Process.sleep(20)

    assert Process.alive?(Process.whereis(CampaignAdmission))
    assert health_admission() == before_failure
  end

  test "startup recovery reconciles an interrupted pending reservation" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))
    opts = activation_opts(path)
    assert {:ok, identity} = CampaignAdmission.activate(path, digest, opts)

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:ingest_extractor, %{}),
               :structured,
               1,
               1,
               ReqLLM,
               campaign_identity: identity
             )

    restore_campaign_after_test(path, digest, opts)
    restart_campaign_admission!()

    first = health_admission()
    second = health_admission()
    assert first == second

    assert first["role_usage"]["target.ingest_extractor"]
           |> Map.take([
             "attempts",
             "errors",
             "unmetered_attempts",
             "pending_attempts",
             "in_flight"
           ]) ==
             %{
               "attempts" => 0,
               "errors" => 0,
               "unmetered_attempts" => 0,
               "pending_attempts" => 0,
               "in_flight" => 0
             }
  end

  test "startup recovery kills and reconciles an interrupted provider dispatch" do
    endpoint = start_http_stub(delay: 4_000, body: completion(%{}))
    configure_extractor_endpoint(endpoint)

    campaign =
      packet(requests: 1, input_tokens: 10_000)
      |> put_in(["execution", "routes", "target.ingest_extractor", "endpoint"], endpoint)

    {path, digest} = write_packet!(campaign)
    opts = activation_opts(path)
    assert {:ok, identity} = CampaignAdmission.activate(path, digest, opts)
    restore_campaign_after_test(path, digest, opts)
    parent = self()

    caller =
      spawn(fn ->
        result =
          Gateway.structured_once(
            :ingest_extractor,
            [],
            %{},
            %{},
            campaign_identity: identity
          )

        send(parent, {:interrupted_gateway_result, result})
      end)

    monitor = Process.monitor(caller)
    assert_receive :campaign_http_call, 3_000
    restart_campaign_admission!()

    assert Task.Supervisor.children(MemHouse.Model.CampaignProviderTaskSupervisor) == []

    if Process.alive?(caller), do: Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, _reason}
    refute_receive {:interrupted_gateway_result, {:ok, _value, _config}}

    first = health_admission()
    Process.sleep(10)
    second = health_admission()
    assert first == second

    assert first["role_usage"]["target.ingest_extractor"]
           |> Map.take([
             "attempts",
             "errors",
             "unmetered_attempts",
             "pending_attempts",
             "in_flight"
           ]) ==
             %{
               "attempts" => 1,
               "errors" => 1,
               "unmetered_attempts" => 1,
               "pending_attempts" => 0,
               "in_flight" => 0
             }
  end

  test "a persisted accounting transition syncs the ledger directory" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))
    assert {:ok, identity} = activate(path, digest)
    admission = Process.whereis(CampaignAdmission)

    :erlang.trace(admission, true, [:call])
    :erlang.trace_pattern({:file, :sync, 1}, true, [:local])

    on_exit(fn ->
      :erlang.trace(admission, false, [:call])
      :erlang.trace_pattern({:file, :sync, 1}, false, [:local])
    end)

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:ingest_extractor, %{}),
               :structured,
               1,
               8,
               ReqLLM,
               campaign_identity: identity
             )

    assert_receive {:trace, ^admission, :call, {:file, :sync, [_directory_descriptor]}}
  end

  test "the public gateway refuses a second paid request after the campaign cap is reserved" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))

    assert {:ok, identity} =
             activate(path, digest)

    context = %{model_provider: Provider}
    opts = [campaign_identity: identity]
    config = Config.resolve(:ingest_extractor, %{})

    assert {:ok, %{role: "target.ingest_extractor"}} =
             CampaignAdmission.reserve(config, :structured, 100, 8, ReqLLM, opts)

    assert {:error, %CampaignAdmission.Refused{reason: :request_ceiling}} =
             Gateway.structured_once(:ingest_extractor, [], %{}, context, opts)

    assert Provider.calls() == 0
  end

  test "an executable provider override cannot bypass the approved route" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))

    assert {:ok, identity} =
             activate(path, digest)

    assert {:error, %CampaignAdmission.Refused{reason: :provider_override}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity
             )

    assert Provider.calls() == 0
  end

  test "an expected campaign identity fails closed when no admission is active" do
    assert {:error, %CampaignAdmission.Refused{reason: :missing_admission}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: "issue-287:approved-digest"
             )

    assert Provider.calls() == 0
  end

  test "a named campaign role fails closed when no admission is active" do
    assert {:error, %CampaignAdmission.Refused{reason: :missing_admission}} =
             Gateway.structured_once(
               :dream_reasoner,
               [],
               %{},
               %{model_provider: Provider},
               campaign_role: "harness.judge"
             )

    assert Provider.calls() == 0
  end

  test "an activated packet is permanently consumed across process restart" do
    {path, digest} = write_packet!(packet(requests: 1))
    ledger_dir = path <> ".ledger"

    assert {:ok, _identity} =
             activate(path, digest, ledger_dir: ledger_dir)

    assert File.exists?(Path.join(ledger_dir, digest <> ".memhouse-started"))

    previous = Process.whereis(CampaignAdmission)
    :ok = GenServer.stop(CampaignAdmission)
    assert is_pid(await_campaign_restart(previous, 50))

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_already_consumed}} =
             activate(path, digest, ledger_dir: ledger_dir)
  end

  test "renaming an approved packet cannot replay its digest" do
    {path, digest} = write_packet!(packet(requests: 1))
    ledger_dir = path <> ".ledger"
    copy = path <> ".copy"
    File.cp!(path, copy)
    on_exit(fn -> File.rm(copy) end)

    assert {:ok, _identity} = activate(path, digest, ledger_dir: ledger_dir)

    previous = Process.whereis(CampaignAdmission)
    :ok = GenServer.stop(CampaignAdmission)
    assert is_pid(await_campaign_restart(previous, 50))

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_already_consumed}} =
             activate(copy, digest, ledger_dir: ledger_dir)
  end

  test "campaign definition and arm identity are mandatory activation inputs" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:error, %CampaignAdmission.Refused{reason: :missing_campaign_identity}} =
             activate(path, digest, definition_id: nil)

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_arm_mismatch}} =
             activate(path, digest, arm_id: nil)
  end

  test "public campaign identity fields reject unbounded or unsafe packet text" do
    invalid_definition =
      packet(requests: 1)
      |> Map.put("definition_id", String.duplicate("a", 129))

    {path, digest} = write_packet!(invalid_definition)

    assert {:error, %CampaignAdmission.Refused{reason: :invalid_campaign_identity}} =
             activate(path, digest, definition_id: String.duplicate("a", 129))

    invalid_prompt =
      packet(requests: 1)
      |> put_in(["arms", Access.at(0), "prompt_version"], "unsafe prompt text")

    {path, digest} = write_packet!(invalid_prompt)

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_arm_mismatch}} =
             activate(path, digest)
  end

  test "activation binds the immutable run and backend identity" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_run_mismatch}} =
             activate(path, digest, run_id: "issue-287-external-run-1")

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_backend_mismatch}} =
             activate(path, digest,
               backend: %{"engine" => "postgres", "mode" => "external", "sqlite" => "unsupported"}
             )
  end

  test "activation publishes content-free run, backend, and restart policy identity" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:ok, _identity} = activate(path, digest)

    assert CampaignAdmission.status()
           |> Map.take([:run_id, :backend, :abort_policy, :rerun_policy]) ==
             %{
               run_id: @run_id,
               backend: @backend,
               abort_policy: "consume-packet-no-resume",
               rerun_policy: "new-packet-new-run-id"
             }
  end

  test "activation binds an exact route for every paid role" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:ok, _identity} = activate(path, digest)

    status = CampaignAdmission.status()
    assert Map.keys(status.routes) |> Enum.sort() == paid_role_names()

    assert status.routes["target.ingest_extractor"] == %{
             credential: %{status: :present, variable: "MEMHOUSE_CAMPAIGN_TEST_KEY"},
             endpoint: "https://openrouter.ai/api/v1",
             provider: "openrouter",
             upstream_route: "openai"
           }

    assert status.routes["target.reranker"] == %{
             credential: %{status: :present, variable: "MEMHOUSE_CAMPAIGN_TEST_KEY"},
             endpoint: "https://openrouter.ai/api/v1",
             provider: "openrouter",
             upstream_route: "voyageai"
           }
  end

  test "missing route credentials fail before durable packet consumption" do
    missing_variable = "MEMHOUSE_CAMPAIGN_MISSING_#{System.unique_integer([:positive])}"

    campaign =
      packet(requests: 1)
      |> put_in(
        ["execution", "routes", "target.ingest_extractor", "credential_ref"],
        "env:" <> missing_variable
      )

    {path, digest} = write_packet!(campaign)
    ledger_dir = path <> ".ledger"

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_credentials_unavailable}} =
             activate(path, digest, ledger_dir: ledger_dir)

    refute File.exists?(ledger_dir)
  end

  test "blank credentials and unbound route fields fail before durable consumption" do
    System.put_env("MEMHOUSE_CAMPAIGN_BLANK_KEY", "   ")
    on_exit(fn -> System.delete_env("MEMHOUSE_CAMPAIGN_BLANK_KEY") end)

    blank =
      packet(requests: 1)
      |> put_in(
        ["execution", "routes", "target.ingest_extractor", "credential_ref"],
        "env:MEMHOUSE_CAMPAIGN_BLANK_KEY"
      )

    {blank_path, blank_digest} = write_packet!(blank)

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_credentials_unavailable}} =
             activate(blank_path, blank_digest)

    unbound =
      packet(requests: 1)
      |> put_in(["execution", "routes", "target.ingest_extractor", "unapproved"], true)

    {unbound_path, unbound_digest} = write_packet!(unbound)

    assert {:error, %CampaignAdmission.Refused{reason: :unpriceable_routing}} =
             activate(unbound_path, unbound_digest)

    refute File.exists?(blank_path <> ".ledger")
    refute File.exists?(unbound_path <> ".ledger")
  end

  test "known-incompatible model routes fail before durable packet consumption" do
    reranker_on_generation =
      packet(requests: 1)
      |> put_in(["execution", "routes", "target.reranker", "upstream_route"], "openai")

    {reranker_path, reranker_digest} = write_packet!(reranker_on_generation)

    assert {:error, %CampaignAdmission.Refused{reason: :unpriceable_routing}} =
             activate(reranker_path, reranker_digest)

    noncanonical_reranker =
      packet(requests: 1)
      |> put_in(["execution", "routes", "target.reranker", "upstream_route"], "voyage")

    {noncanonical_path, noncanonical_digest} = write_packet!(noncanonical_reranker)

    assert {:error, %CampaignAdmission.Refused{reason: :unpriceable_routing}} =
             activate(noncanonical_path, noncanonical_digest)

    generation_on_voyage =
      packet(requests: 1)
      |> put_in(["execution", "routes", "target.ingest_extractor", "upstream_route"], "voyageai")

    {generation_path, generation_digest} = write_packet!(generation_on_voyage)

    assert {:error, %CampaignAdmission.Refused{reason: :unpriceable_routing}} =
             activate(generation_path, generation_digest)

    refute File.exists?(reranker_path <> ".ledger")
    refute File.exists?(noncanonical_path <> ".ledger")
    refute File.exists?(generation_path <> ".ledger")
  end

  test "public activation options cannot override the running build revision" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:error, %CampaignAdmission.Refused{reason: :target_revision_mismatch}} =
             activate(path, digest,
               target_revision: String.duplicate("a", 40),
               actual_revision: @target_revision
             )
  end

  test "the campaign build revision cannot be changed through runtime application config" do
    previous = Application.fetch_env!(:memhouse, :campaign_build_sha)

    try do
      Application.put_env(:memhouse, :campaign_build_sha, String.duplicate("a", 40))
      assert CampaignBuild.revision() == @target_revision
    after
      Application.put_env(:memhouse, :campaign_build_sha, previous)
    end
  end

  test "a missing, changed, or unapproved packet cannot activate spend" do
    missing =
      Path.join(System.tmp_dir!(), "missing-campaign-#{System.unique_integer([:positive])}")

    digest = String.duplicate("0", 64)

    assert {:error, %CampaignAdmission.Refused{reason: :missing_admission}} =
             activate(missing, digest)

    {path, actual_digest} = write_packet!(packet(requests: 1))

    assert {:error, %CampaignAdmission.Refused{reason: :dirty_admission}} =
             activate(path, digest)

    unapproved = packet(requests: 1) |> Map.put("admitted", false)
    {unapproved_path, unapproved_digest} = write_packet!(unapproved)

    assert {:error, %CampaignAdmission.Refused{reason: :unapproved_admission}} =
             activate(unapproved_path, unapproved_digest)

    refute actual_digest == digest
    assert Provider.calls() == 0
  end

  test "a legacy single-route admission schema fails closed" do
    legacy = packet(requests: 1) |> Map.put("schema_version", "membench-campaign-admission-1")
    {path, digest} = write_packet!(legacy)

    assert {:error, %CampaignAdmission.Refused{reason: :unapproved_admission}} =
             activate(path, digest)
  end

  test "identity and provider routing mismatches are rejected before the callback" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:ok, identity} =
             activate(path, digest)

    assert {:error, %CampaignAdmission.Refused{reason: :campaign_identity_mismatch}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity <> "-changed"
             )

    roles = Application.fetch_env!(:memhouse, :model_roles)

    Application.put_env(
      :memhouse,
      :model_roles,
      update_in(roles[:ingest_extractor][:options], &Map.put(&1, "upstream_route", "other"))
    )

    assert {:error, %CampaignAdmission.Refused{reason: :routing_mismatch}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity
             )

    assert Provider.calls() == 0
  end

  test "credential reference drift is rejected before the callback" do
    {path, digest} = write_packet!(packet(requests: 1))
    assert {:ok, identity} = activate(path, digest)

    roles = Application.fetch_env!(:memhouse, :model_roles)

    Application.put_env(
      :memhouse,
      :model_roles,
      put_in(roles[:ingest_extractor][:options]["api_key_ref"], "env:OTHER_KEY")
    )

    assert {:error, %CampaignAdmission.Refused{reason: :routing_mismatch}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity
             )

    assert Provider.calls() == 0
  end

  test "a paid campaign role cannot switch to a local provider mid-campaign" do
    {path, digest} = write_packet!(packet(requests: 1))
    assert {:ok, identity} = activate(path, digest)

    roles = Application.fetch_env!(:memhouse, :model_roles)

    Application.put_env(
      :memhouse,
      :model_roles,
      put_in(roles[:ingest_extractor][:provider], "deterministic")
    )

    assert {:error, %CampaignAdmission.Refused{reason: :routing_mismatch}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity
             )

    assert Provider.calls() == 0
  end

  test "the wall ceiling is checked before the provider callback" do
    campaign = packet(requests: 1) |> put_in(["volume", "hard_caps", "wall_seconds"], 1)
    {path, digest} = write_packet!(campaign)

    assert {:ok, identity} = activate(path, digest)
    Process.sleep(1_050)

    assert {:error, %CampaignAdmission.Refused{reason: :wall_ceiling}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity
             )

    assert Provider.calls() == 0
  end

  test "an admitted callback receives only the remaining hard wall budget" do
    campaign = packet(requests: 1) |> put_in(["volume", "hard_caps", "wall_seconds"], 1)
    {path, digest} = write_packet!(campaign)

    assert {:ok, identity} = activate(path, digest)

    assert {:ok, %{remaining_wall_ms: remaining_wall_ms}} =
             CampaignAdmission.reserve(
               Config.resolve(:ingest_extractor, %{}),
               :structured,
               1,
               8,
               ReqLLM,
               campaign_identity: identity
             )

    assert remaining_wall_ms in 1..1_000
  end

  test "the exact ReqLLM adapter is killed at the remaining campaign wall" do
    warm_endpoint = start_http_stub(body: completion(%{}))
    configure_extractor_endpoint(warm_endpoint)

    assert {:ok, _result} =
             ReqLLM.structured(Config.resolve(:ingest_extractor, %{}), [], %{}, [])

    assert_receive :campaign_http_call

    endpoint = start_http_stub(delay: 4_000, body: completion(%{}))
    configure_extractor_endpoint(endpoint)

    campaign =
      packet(requests: 1, input_tokens: 10_000)
      |> put_in(["execution", "routes", "target.ingest_extractor", "endpoint"], endpoint)
      |> put_in(["volume", "hard_caps", "wall_seconds"], 1)

    {path, digest} = write_packet!(campaign)

    assert {:ok, identity} = activate(path, digest)
    Process.sleep(100)

    assert {:error, %MemHouse.Operations.ExtractionBudget.Exceeded{reason: "wall-time cap"}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{},
               campaign_identity: identity
             )

    assert_receive :campaign_http_call, 1_000

    usage = health_admission()["role_usage"]["target.ingest_extractor"]
    assert usage["attempts"] == 1
    assert usage["errors"] == 1
    assert usage["unmetered_attempts"] == 1
    assert usage["pending_attempts"] == 0
    assert usage["in_flight"] == 0
  end

  test "a cancelled gateway caller durably finalizes its in-flight attempt" do
    endpoint = start_http_stub(delay: 4_000, body: completion(%{}))
    configure_extractor_endpoint(endpoint)

    campaign =
      packet(requests: 1, input_tokens: 10_000)
      |> put_in(["execution", "routes", "target.ingest_extractor", "endpoint"], endpoint)

    {path, digest} = write_packet!(campaign)
    assert {:ok, identity} = activate(path, digest)
    parent = self()

    caller =
      spawn(fn ->
        result =
          Gateway.structured_once(
            :ingest_extractor,
            [],
            %{},
            %{},
            campaign_identity: identity
          )

        send(parent, {:unexpected_gateway_result, result})
      end)

    monitor = Process.monitor(caller)
    assert_receive :campaign_http_call, 3_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    refute_receive {:unexpected_gateway_result, _result}

    usage = await_usage_finalization(50)
    assert usage["attempts"] == 1
    assert usage["errors"] == 1
    assert usage["unmetered_attempts"] == 1
    assert usage["pending_attempts"] == 0
    assert usage["in_flight"] == 0
    assert Task.Supervisor.children(MemHouse.Model.CampaignProviderTaskSupervisor) == []

    first = health_admission()
    Process.sleep(10)
    assert health_admission() == first
  end

  test "the admitted ReqLLM adapter makes no hidden transport retry" do
    endpoint = start_http_stub(status: 500)
    configure_extractor_endpoint(endpoint)

    campaign =
      packet(requests: 3, input_tokens: 30_000)
      |> put_in(["execution", "routes", "target.ingest_extractor", "endpoint"], endpoint)

    {path, digest} = write_packet!(campaign)

    assert {:ok, identity} =
             activate(path, digest)

    assert {:error, _error} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{},
               campaign_identity: identity
             )

    assert_receive :campaign_http_call
    refute_receive :campaign_http_call, 50
    assert CampaignAdmission.status().reserved.requests == 1
  end

  test "input token exhaustion is rejected before content reaches the provider" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 1))

    assert {:ok, identity} =
             activate(path, digest)

    assert {:error, %CampaignAdmission.Refused{reason: :input_token_ceiling} = error} =
             Gateway.structured_once(
               :ingest_extractor,
               [%{role: "user", content: "private campaign content"}],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity
             )

    refute Exception.message(error) =~ "private campaign content"
    assert Provider.calls() == 0
  end

  test "output token exhaustion fails closed" do
    output_limited =
      packet(requests: 1)
      |> put_in(["paid_roles", "target.ingest_extractor", "output_tokens"], 0)

    output_limited = put_in(output_limited, ["volume", "hard_caps", "output_tokens"], 0)
    {path, digest} = write_packet!(output_limited)

    assert {:ok, identity} =
             activate(path, digest)

    assert {:error, %CampaignAdmission.Refused{reason: :output_token_ceiling}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity
             )

    assert Provider.calls() == 0
  end

  test "missing model pricing cannot activate spend" do
    unpriced = packet(requests: 1) |> Map.put("pricing_usd_per_million", %{})
    {path, digest} = write_packet!(unpriced)

    assert {:error, %CampaignAdmission.Refused{reason: :unpriceable_models}} =
             activate(path, digest)
  end

  test "structured repairs reserve again and stop before an unapproved second callback" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))

    assert {:ok, identity} =
             activate(path, digest)

    config = Config.resolve(:ingest_extractor, %{})

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               config,
               :structured,
               100,
               8,
               ReqLLM,
               campaign_identity: identity
             )

    assert {:error, %CampaignAdmission.Refused{reason: :request_ceiling}} =
             StructuredGenerator.generate(
               :ingest_extractor,
               [],
               MemHouse.Model.CampaignAdmissionTest.RepairSchema,
               %{model_provider: Provider},
               campaign_identity: identity,
               max_repairs: 2
             )

    assert Provider.calls() == 0
  end

  test "hosted roles outside the approved paid-role set are unpriceable" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:ok, identity} =
             activate(path, digest)

    roles = Application.fetch_env!(:memhouse, :model_roles)

    hosted_embedder = %{
      provider: "openrouter",
      model: "openai/text-embedding-3-small",
      model_version: "v1",
      prompt_version: "none",
      pipeline_version: "f5-1",
      embedding_dimensions: 1,
      options: %{
        "base_url" => "https://openrouter.ai/api/v1",
        "upstream_route" => "openai"
      }
    }

    Application.put_env(:memhouse, :model_roles, Keyword.put(roles, :embedder, hosted_embedder))

    assert {:error, %CampaignAdmission.Refused{reason: :unknown_paid_role}} =
             Gateway.embed(["content"], %{model_provider: Provider}, campaign_identity: identity)

    assert Provider.calls() == 0
  end

  test "extractor, dream, dialectic, harness, and reranker roles share one hard campaign" do
    generation_cap = %{
      "requests" => 1,
      "input_tokens" => 10_000,
      "output_tokens" => 8,
      "usd" => 1.0
    }

    reranker_cap = Map.put(generation_cap, "output_tokens", 0)

    role_caps = %{
      "target.ingest_extractor" => generation_cap,
      "target.dialectic_agent" => generation_cap,
      "target.dream_reasoner" => generation_cap,
      "target.reranker" => reranker_cap,
      "harness.answerer" => generation_cap,
      "harness.judge" => generation_cap
    }

    campaign = packet(requests: 1) |> put_role_caps(role_caps)
    {path, digest} = write_packet!(campaign)

    assert {:ok, identity} =
             activate(path, digest)

    roles = Application.fetch_env!(:memhouse, :model_roles)

    roles =
      roles
      |> Keyword.put(:dream_reasoner, hosted_role(:dream_reasoner, "openai/gpt-oss-120b"))
      |> Keyword.put(:dialectic_agent, hosted_role(:dialectic_agent, "openai/gpt-oss-120b"))
      |> Keyword.put(:reranker, hosted_role(:reranker, "voyageai/rerank-2.5"))

    Application.put_env(:memhouse, :model_roles, roles)
    opts = [campaign_identity: identity]

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:ingest_extractor, %{}),
               :structured,
               1,
               8,
               ReqLLM,
               opts
             )

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:dream_reasoner, %{}),
               :structured,
               1,
               8,
               ReqLLM,
               opts
             )

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:dialectic_agent, %{}),
               :chat,
               1,
               8,
               ReqLLM,
               opts
             )

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:reranker, %{}),
               :rerank,
               1,
               0,
               ReqLLM,
               opts
             )

    roles =
      roles
      |> Keyword.put(
        :dream_reasoner,
        hosted_role(:dream_reasoner, "openai/gpt-oss-120b-independent")
      )

    Application.put_env(:memhouse, :model_roles, roles)

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:dream_reasoner, %{}),
               :structured,
               1,
               8,
               ReqLLM,
               campaign_identity: identity,
               campaign_role: "harness.judge"
             )

    assert {:ok, _reservation} =
             CampaignAdmission.reserve(
               Config.resolve(:dialectic_agent, %{}),
               :chat,
               1,
               8,
               ReqLLM,
               campaign_identity: identity,
               campaign_role: "harness.answerer"
             )

    assert Provider.calls() == 0
    assert CampaignAdmission.status().reserved.requests == 6
  end

  defp activate(path, digest, opts \\ []) do
    CampaignAdmission.activate(path, digest, Keyword.merge(activation_opts(path), opts))
  end

  defp activation_opts(path) do
    [
      target_revision: @target_revision,
      definition_id: "issue-287-test-v1",
      arm_id: "B",
      run_id: @run_id,
      backend: @backend,
      ledger_dir: path <> ".ledger"
    ]
  end

  defp packet(overrides) do
    extractor =
      %{"requests" => 1, "input_tokens" => 10_000, "output_tokens" => 8, "usd" => 1.0}
      |> Map.merge(Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end))

    zero = %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0}

    %{
      "schema_version" => "membench-campaign-admission-2",
      "definition_id" => "issue-287-test-v1",
      "issue" => "memhousehq/memhouse#287",
      "admitted" => true,
      "provider_calls_permitted" => true,
      "blockers" => [],
      "execution" => %{
        "abort_policy" => "consume-packet-no-resume",
        "backend" => @backend,
        "rerun_policy" => "new-packet-new-run-id",
        "run_id" => @run_id
      },
      "models" => %{
        "answerer" => "openai/gpt-oss-120b",
        "judge" => "openai/gpt-oss-120b-independent",
        "reranker" => "voyageai/rerank-2.5"
      },
      "arms" => [
        %{
          "id" => "B",
          "target_ref" => @target_revision,
          "prompt_version" => "extract-14",
          "batching" => false,
          "runtime_prompt_available" => true
        }
      ],
      "pricing_usd_per_million" => %{
        "openai/gpt-oss-120b" => %{"input" => 0.35, "output" => 0.95},
        "openai/gpt-oss-120b-independent" => %{"input" => 0.35, "output" => 0.95},
        "voyageai/rerank-2.5" => %{"input" => 0.05, "output" => 0.0}
      },
      "paid_roles" => %{
        "target.ingest_extractor" => extractor,
        "target.dialectic_agent" => zero,
        "target.dream_reasoner" => zero,
        "target.reranker" => zero,
        "harness.answerer" => zero,
        "harness.judge" => zero
      },
      "volume" => %{
        "hard_caps" => %{
          "paid_requests" => extractor["requests"],
          "input_tokens" => extractor["input_tokens"],
          "output_tokens" => extractor["output_tokens"],
          "reranker_input_tokens" => 0,
          "usd" => extractor["usd"],
          "wall_seconds" => 60
        }
      }
    }
    |> per_role_route_packet()
  end

  defp per_role_route_packet(packet) do
    routes =
      Map.new(paid_role_names(), fn role ->
        upstream_route = if role == "target.reranker", do: "voyageai", else: "openai"

        {role,
         %{
           "credential_ref" => "env:MEMHOUSE_CAMPAIGN_TEST_KEY",
           "endpoint" => "https://openrouter.ai/api/v1",
           "provider" => "openrouter",
           "upstream_route" => upstream_route
         }}
      end)

    put_in(packet, ["execution", "routes"], routes)
  end

  defp put_role_caps(packet, role_caps) do
    hard_caps =
      Enum.reduce(
        role_caps,
        %{
          "paid_requests" => 0,
          "input_tokens" => 0,
          "output_tokens" => 0,
          "reranker_input_tokens" => 0,
          "usd" => 0.0,
          "wall_seconds" => 60
        },
        fn {role, caps}, acc ->
          acc
          |> Map.update!("paid_requests", &(&1 + caps["requests"]))
          |> Map.update!("input_tokens", &(&1 + caps["input_tokens"]))
          |> Map.update!("output_tokens", &(&1 + caps["output_tokens"]))
          |> Map.update!("usd", &(&1 + caps["usd"]))
          |> Map.update!("reranker_input_tokens", fn value ->
            if role == "target.reranker", do: value + caps["input_tokens"], else: value
          end)
        end
      )

    packet
    |> Map.put("paid_roles", role_caps)
    |> put_in(["volume", "hard_caps"], hard_caps)
  end

  defp paid_role_names do
    ~w(
      harness.answerer
      harness.judge
      target.dialectic_agent
      target.dream_reasoner
      target.ingest_extractor
      target.reranker
    )
  end

  defp hosted_role(role, model) do
    upstream_route = if model == "voyageai/rerank-2.5", do: "voyageai", else: "openai"

    %{
      provider: "openrouter",
      model: model,
      model_version: "campaign-v1",
      prompt_version: "campaign-v1",
      pipeline_version: "f5-1",
      options: %{
        "base_url" => "https://openrouter.ai/api/v1",
        "max_tokens" => 8,
        "api_key_ref" => "env:MEMHOUSE_CAMPAIGN_TEST_KEY",
        "upstream_route" => upstream_route
      },
      role: role
    }
    |> Map.delete(:role)
  end

  defp configure_extractor_endpoint(endpoint) do
    roles = Application.fetch_env!(:memhouse, :model_roles)

    Application.put_env(
      :memhouse,
      :model_roles,
      update_in(roles[:ingest_extractor][:options], fn options ->
        Map.merge(options, %{
          "api_key_ref" => "env:MEMHOUSE_CAMPAIGN_TEST_KEY",
          "base_url" => endpoint
        })
      end)
    )
  end

  defp start_http_stub(opts) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {StubPlug, Keyword.put(opts, :test_pid, self())},
         port: 0,
         scheme: :http,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  defp completion(value) do
    %{
      "id" => "campaign-stub",
      "object" => "chat.completion",
      "created" => 1_700_000_000,
      "model" => "openai/gpt-oss-120b",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => Jason.encode!(value)}
        }
      ],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }
  end

  defp health_admission do
    get(build_conn(), "/api/health")
    |> json_response(200)
    |> Map.fetch!("campaign_admission")
  end

  defp await_usage_finalization(attempts) when attempts > 0 do
    usage = health_admission()["role_usage"]["target.ingest_extractor"]

    if usage["pending_attempts"] == 0 and usage["in_flight"] == 0 do
      usage
    else
      Process.sleep(2)
      await_usage_finalization(attempts - 1)
    end
  end

  defp await_usage_finalization(0), do: flunk("campaign usage did not reach a terminal state")

  defp restore_campaign_after_test(path, digest, opts) do
    previous_activation = Application.get_env(:memhouse, :campaign_admission)

    on_exit(fn ->
      :ok = Supervisor.terminate_child(MemHouse.Supervisor, CampaignAdmission)

      if previous_activation do
        Application.put_env(:memhouse, :campaign_admission, previous_activation)
      else
        Application.delete_env(:memhouse, :campaign_admission)
      end

      {:ok, _pid} = Supervisor.restart_child(MemHouse.Supervisor, CampaignAdmission)
    end)

    Application.put_env(:memhouse, :campaign_admission, {path, digest, opts})
  end

  defp restart_campaign_admission! do
    :ok = Supervisor.terminate_child(MemHouse.Supervisor, CampaignAdmission)
    {:ok, _pid} = Supervisor.restart_child(MemHouse.Supervisor, CampaignAdmission)
    :ok
  end

  defp write_packet!(packet) do
    nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

    path =
      Path.join(
        System.tmp_dir!(),
        "campaign-admission-#{nonce}.json"
      )

    bytes = Jason.encode!(packet)
    File.write!(path, bytes)

    on_exit(fn ->
      File.rm(path)
      File.rm_rf(path <> ".ledger")
    end)

    {path, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end

  defp await_campaign_restart(previous, attempts) when attempts > 0 do
    case Process.whereis(CampaignAdmission) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _not_restarted ->
        Process.sleep(2)
        await_campaign_restart(previous, attempts - 1)
    end
  end

  defp await_campaign_restart(_previous, 0), do: nil
end
