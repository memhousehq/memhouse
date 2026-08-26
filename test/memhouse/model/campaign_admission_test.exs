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

defmodule MemHouse.Model.CampaignAdmissionTest do
  use ExUnit.Case, async: false

  alias MemHouse.Model.CampaignAdmission
  alias MemHouse.Model.CampaignAdmissionTest.Provider
  alias MemHouse.Model.Gateway
  alias MemHouse.Model.StructuredGenerator

  @target_revision "ed3f3600fdab9b09abdb40e7ee3492e334f6df72"

  setup do
    unless Process.whereis(CampaignAdmission), do: start_supervised!(CampaignAdmission)

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
    previous_build_sha = Application.fetch_env!(:memhouse, :build_sha)

    Application.put_env(:memhouse, :ingest_provider_circuit, enabled: false)
    Application.put_env(:memhouse, :build_sha, @target_revision)

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
          "base_url" => "https://openrouter.ai/api/v1",
          "max_tokens" => 8,
          "upstream_route" => "openai"
        }
      })
    )

    on_exit(fn ->
      Application.put_env(:memhouse, :model_roles, previous_roles)
      Application.put_env(:memhouse, :ingest_provider_circuit, previous_circuit)
      Application.put_env(:memhouse, :build_sha, previous_build_sha)
    end)

    :ok
  end

  test "the public gateway refuses a second paid request after the campaign cap is reserved" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))

    assert {:ok, identity} =
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)

    context = %{model_provider: Provider}
    opts = [campaign_identity: identity]

    assert {:ok, %{}, _config} =
             Gateway.structured_once(:ingest_extractor, [], %{}, context, opts)

    assert {:error, %CampaignAdmission.Refused{reason: :request_ceiling}} =
             Gateway.structured_once(:ingest_extractor, [], %{}, context, opts)

    assert Provider.calls() == 1
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

  test "a missing, changed, or unapproved packet cannot activate spend" do
    missing =
      Path.join(System.tmp_dir!(), "missing-campaign-#{System.unique_integer([:positive])}")

    digest = String.duplicate("0", 64)

    assert {:error, %CampaignAdmission.Refused{reason: :missing_admission}} =
             CampaignAdmission.activate(missing, digest, target_revision: @target_revision)

    {path, actual_digest} = write_packet!(packet(requests: 1))

    assert {:error, %CampaignAdmission.Refused{reason: :dirty_admission}} =
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)

    unapproved = packet(requests: 1) |> Map.put("admitted", false)
    {unapproved_path, unapproved_digest} = write_packet!(unapproved)

    assert {:error, %CampaignAdmission.Refused{reason: :unapproved_admission}} =
             CampaignAdmission.activate(unapproved_path, unapproved_digest,
               target_revision: @target_revision
             )

    refute actual_digest == digest
    assert Provider.calls() == 0
  end

  test "identity and provider routing mismatches are rejected before the callback" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:ok, identity} =
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)

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

  test "the wall ceiling is checked before the provider callback" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:ok, identity} =
             CampaignAdmission.activate(path, digest,
               target_revision: @target_revision,
               now_ms: 0
             )

    assert {:error, %CampaignAdmission.Refused{reason: :wall_ceiling}} =
             Gateway.structured_once(
               :ingest_extractor,
               [],
               %{},
               %{model_provider: Provider},
               campaign_identity: identity,
               campaign_now_ms: 60_000
             )

    assert Provider.calls() == 0
  end

  test "input token exhaustion is rejected before content reaches the provider" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 1))

    assert {:ok, identity} =
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)

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
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)

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
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)
  end

  test "structured repairs reserve again and stop before an unapproved second callback" do
    {path, digest} = write_packet!(packet(requests: 1, input_tokens: 10_000))

    assert {:ok, identity} =
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)

    assert {:error, %CampaignAdmission.Refused{reason: :request_ceiling}} =
             StructuredGenerator.generate(
               :ingest_extractor,
               [],
               MemHouse.Model.CampaignAdmissionTest.RepairSchema,
               %{model_provider: Provider},
               campaign_identity: identity,
               max_repairs: 2
             )

    assert Provider.calls() == 1
  end

  test "hosted roles outside the approved paid-role set are unpriceable" do
    {path, digest} = write_packet!(packet(requests: 1))

    assert {:ok, identity} =
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)

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
             CampaignAdmission.activate(path, digest, target_revision: @target_revision)

    roles = Application.fetch_env!(:memhouse, :model_roles)

    roles =
      roles
      |> Keyword.put(:dream_reasoner, hosted_role(:dream_reasoner, "openai/gpt-oss-120b"))
      |> Keyword.put(:dialectic_agent, hosted_role(:dialectic_agent, "openai/gpt-oss-120b"))
      |> Keyword.put(:reranker, hosted_role(:reranker, "voyageai/rerank-2.5"))

    Application.put_env(:memhouse, :model_roles, roles)
    context = %{model_provider: Provider}
    opts = [campaign_identity: identity]

    assert {:ok, %{}, _config} =
             Gateway.structured_once(:ingest_extractor, [], %{}, context, opts)

    assert {:ok, %{}, _config} = Gateway.structured_once(:dream_reasoner, [], %{}, context, opts)
    assert {:ok, "answer", _provenance} = Gateway.chat(:dialectic_agent, [], context, opts)
    assert {:ok, [], _provenance} = Gateway.rerank("query", ["document"], context, opts)

    roles =
      roles
      |> Keyword.put(
        :dream_reasoner,
        hosted_role(:dream_reasoner, "openai/gpt-oss-120b-independent")
      )

    Application.put_env(:memhouse, :model_roles, roles)

    assert {:ok, %{}, _config} =
             Gateway.structured_once(:dream_reasoner, [], %{}, context,
               campaign_identity: identity,
               campaign_role: "harness.judge"
             )

    assert {:ok, "answer", _provenance} =
             Gateway.chat(:dialectic_agent, [], context,
               campaign_identity: identity,
               campaign_role: "harness.answerer"
             )

    assert Provider.calls() == 6
    assert CampaignAdmission.status().reserved.requests == 6
  end

  defp packet(overrides) do
    extractor =
      %{"requests" => 1, "input_tokens" => 10_000, "output_tokens" => 8, "usd" => 1.0}
      |> Map.merge(Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end))

    zero = %{"requests" => 0, "input_tokens" => 0, "output_tokens" => 0, "usd" => 0.0}

    %{
      "schema_version" => "membench-campaign-admission-1",
      "definition_id" => "issue-287-test-v1",
      "issue" => "memhousehq/memhouse#287",
      "admitted" => true,
      "provider_calls_permitted" => true,
      "blockers" => [],
      "execution" => %{
        "provider" => "openrouter",
        "endpoint" => "https://openrouter.ai/api/v1",
        "upstream_route" => "openai"
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

  defp hosted_role(role, model) do
    %{
      provider: "openrouter",
      model: model,
      model_version: "campaign-v1",
      prompt_version: "campaign-v1",
      pipeline_version: "f5-1",
      options: %{
        "base_url" => "https://openrouter.ai/api/v1",
        "max_tokens" => 8,
        "upstream_route" => "openai"
      },
      role: role
    }
    |> Map.delete(:role)
  end

  defp write_packet!(packet) do
    path =
      Path.join(
        System.tmp_dir!(),
        "campaign-admission-#{System.unique_integer([:positive])}.json"
      )

    bytes = Jason.encode!(packet)
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    {path, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
  end
end
