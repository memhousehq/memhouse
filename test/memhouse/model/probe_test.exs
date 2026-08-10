# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.ProbeTest.StubProvider do
  @moduledoc false
  # Returns whatever the test armed under `:probe_stub_response`, so the probe's
  # three outcomes — an object, an object that does not match the schema it was
  # given, and a provider error — can be pinned without a network call.

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result

  @impl true
  def structured(_config, _messages, _schema, _opts) do
    case Application.get_env(:memhouse, :probe_stub_response) do
      {:error, reason} -> {:error, reason}
      value -> {:ok, %Result{value: value, usage: %{}, metadata: %{}}}
    end
  end

  @impl true
  def chat(_config, _messages, _opts), do: {:error, :unsupported}

  @impl true
  def embed(_config, _texts, _opts), do: {:error, :unsupported}

  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :unsupported}
end

defmodule MemHouse.Model.ProbeTest do
  @moduledoc """
  Pins what the probe is for: proving a generative role can still return an
  object, before any work depends on it.

  The usage ledger reports failures that already happened. On a node that has
  made no calls yet it reports nothing, and nothing is indistinguishable from
  healthy. Only asking for an object separates the two, which is why a passing
  error rate is not a substitute for this check.

  The `schema_not_enforced` case is the one that motivated the probe. A model
  given a forced tool call may answer in prose and still return HTTP 200; the
  request succeeds, the object does not arrive, and extraction quietly thins.
  """

  use ExUnit.Case, async: false

  alias MemHouse.Eval.Preflight
  alias MemHouse.Model.Probe
  alias MemHouse.Model.ProbeTest.StubProvider

  @roles [:ingest_extractor, :dream_reasoner, :dialectic_agent]

  setup do
    original_roles = Application.fetch_env!(:memhouse, :model_roles)
    original_provider = Application.get_env(:memhouse, :model_provider)

    on_exit(fn ->
      Application.put_env(:memhouse, :model_roles, original_roles)
      Application.delete_env(:memhouse, :probe_stub_response)

      if original_provider,
        do: Application.put_env(:memhouse, :model_provider, original_provider),
        else: Application.delete_env(:memhouse, :model_provider)
    end)

    :ok
  end

  # Points every generative role at a hosted provider name so the probe treats
  # it as reachable, and serves it with the stub rather than a real endpoint.
  defp arm(response) do
    roles =
      Enum.reduce(@roles, Application.fetch_env!(:memhouse, :model_roles), fn role, roles ->
        Keyword.put(roles, role, %{
          provider: "openrouter",
          model: "openai/gpt-oss-120b",
          model_version: "unversioned",
          prompt_version: "none",
          pipeline_version: "f5-1",
          options: %{}
        })
      end)

    Application.put_env(:memhouse, :model_roles, roles)
    Application.put_env(:memhouse, :probe_stub_response, response)
    Application.put_env(:memhouse, :model_provider, StubProvider)
  end

  test "a role that returns the requested object passes" do
    arm(%{"ok" => true})

    results = Probe.run()

    assert Map.keys(results) |> Enum.sort() == Enum.sort(@roles)
    assert Probe.ok?(results)

    assert %{
             status: "ok",
             provider: "openrouter",
             model: "openai/gpt-oss-120b",
             model_version: "unversioned"
           } = results.ingest_extractor

    assert is_integer(results.ingest_extractor.duration_ms)
  end

  test "a 200 response carrying an object that ignores the schema fails" do
    # What a declined forced tool call degrades into: a successful request that
    # did not return the object it was required to return.
    arm(%{"answer" => "Here is my answer instead."})

    results = Probe.run()

    refute Probe.ok?(results)
    assert %{status: "error", error_class: "schema_not_enforced"} = results.dialectic_agent
  end

  test "a provider failure is reported with the error class the ledger uses" do
    arm({:error, :missing_structured_object})

    results = Probe.run()

    refute Probe.ok?(results)
    assert %{status: "error", error_class: "missing_structured_object"} = results.dream_reasoner
  end

  test "a role on the deterministic stand-in is skipped, and skipped is not a pass" do
    # Nothing to reach, so there is nothing to prove. Reporting this as a pass
    # would let a graded run start against non-intelligent output.
    results = Probe.run()

    assert %{status: "skipped", provider: "deterministic"} = results.ingest_extractor
    refute Probe.ok?(results)
  end

  test "an eval preflight refuses a run whose roles cannot generate" do
    arm({:error, :missing_structured_object})

    assert_raise RuntimeError, ~r/missing_structured_object/, fn ->
      Preflight.assert_generative_roles!()
    end
  end

  test "an eval preflight returns the probe results when every role passes" do
    arm(%{"ok" => true})

    assert %{ingest_extractor: %{status: "ok"}} = Preflight.assert_generative_roles!()
  end
end
