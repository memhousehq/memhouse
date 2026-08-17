# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.ReasoningOperationContractsTest do
  use ExUnit.Case, async: false

  defmodule Provider do
    @moduledoc false
    @behaviour MemHouse.Model.Provider

    alias MemHouse.Model.Provider.Result
    alias MemHouse.Model.Providers.Deterministic

    @impl true
    def structured(_config, _messages, _schema, _opts) do
      {:ok,
       %Result{
         value: %{"items" => [], "relations" => []},
         usage: %{input_tokens: 7, output_tokens: 3}
       }}
    end

    @impl true
    def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

    @impl true
    def embed(config, texts, opts), do: Deterministic.embed(config, texts, opts)

    @impl true
    def rerank(config, query, documents, opts),
      do: Deterministic.rerank(config, query, documents, opts)
  end

  alias MemHouse.Model.Reasoner
  alias MemHouse.Model.Schema.{ReasoningSynthesis, ReasoningUpdate}

  @account_id Ecto.UUID.generate()
  @scope_id Ecto.UUID.generate()
  @first_id Ecto.UUID.generate()
  @second_id Ecto.UUID.generate()

  setup do
    operations = Application.fetch_env!(:memhouse, :dream_reasoning_operations)
    on_exit(fn -> Application.put_env(:memhouse, :dream_reasoning_operations, operations) end)
    :ok
  end

  test "update contract permits inspectable contradiction edges but no deductions or derived edges" do
    contradiction = relation(@first_id, @second_id, "contradicts")

    assert {:ok, %{items: [], relations: [%{kind: "contradicts"}]}} =
             ReasoningUpdate.cast(%{"items" => [], "relations" => [contradiction]}, context())

    assert {:error, ["update operation cannot create deductions"]} =
             ReasoningUpdate.cast(%{"items" => [deduction()], "relations" => []}, context())

    assert {:error, ["update operation contains an invalid relation kind"]} =
             ReasoningUpdate.cast(
               %{"items" => [], "relations" => [relation(@first_id, @second_id, "derived_from")]},
               context()
             )
  end

  test "synthesis contract requires multiple authorized contributors and excludes contradiction work" do
    assert {:ok, %{items: [%{contributor_ids: ids}], relations: []}} =
             ReasoningSynthesis.cast(%{"items" => [deduction()], "relations" => []}, context())

    assert MapSet.new(ids) == MapSet.new([@first_id, @second_id])
    one_source = put_in(deduction(), ["contributor_ids"], [@first_id])

    assert {:error, [message]} =
             ReasoningSynthesis.cast(%{"items" => [one_source], "relations" => []}, context())

    assert message =~ "at least two unique input ids"

    assert {:error, ["synthesis operation contains an invalid relation kind"]} =
             ReasoningSynthesis.cast(
               %{"items" => [], "relations" => [relation(@first_id, @second_id, "supports")]},
               context()
             )
  end

  test "operation enablement is explicit and keeps synthesis off until ablation approval" do
    assert Reasoner.enabled_operations() == [:update]

    Application.put_env(:memhouse, :dream_reasoning_operations, update: true, synthesis: true)
    assert Reasoner.enabled_operations() == [:update, :synthesis]

    Application.put_env(:memhouse, :dream_reasoning_operations, update: false, synthesis: false)
    assert Reasoner.enabled_operations() == []
  end

  test "enabled reasoning operations emit accepted counts without prompt content" do
    handler = {__MODULE__, self(), :operation}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, measurements, metadata, _config ->
          send(parent, {:reasoning_operation, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _result, _provenance} =
             Reasoner.reason_operations(%{delta: [], working_set: []}, context())

    assert_receive {:reasoning_operation, measurements, metadata}
    assert metadata.operation == "reasoning_update"
    assert metadata.version == "reason-update-1"
    assert metadata.status == "ok"
    assert measurements.calls == 1
    refute inspect({measurements, metadata}) =~ "working_set"
  end

  defp context do
    %{
      account_id: @account_id,
      scope_id: @scope_id,
      known_peer_keys: ["avery"],
      source_peer_key: "avery",
      model_provider: Provider,
      reasoning_inheritance: %{sensitivity: "internal", target_level: "peer"},
      reasoning_inputs: [input(@first_id), input(@second_id)]
    }
  end

  defp input(id) do
    %{
      id: id,
      account_id: @account_id,
      scope_id: @scope_id,
      state: "active",
      sensitivity: "internal",
      target_level: "peer"
    }
  end

  defp relation(source_id, target_id, kind),
    do: %{"source_id" => source_id, "target_id" => target_id, "kind" => kind}

  defp deduction do
    %{
      "reasoning" => "This field is validation-only and is never persisted.",
      "statement" => "Avery prefers weekly release summaries.",
      "kind" => "preference",
      "subject_type" => "peer",
      "subject_ref" => "avery",
      "confidence_level" => "stated_explicitly",
      "sensitivity" => "internal",
      "target_level" => "peer",
      "contributor_ids" => [@first_id, @second_id]
    }
  end
end
