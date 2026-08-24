# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.ReasoningOperationContractsTest do
  @moduledoc """
  Pins independent update/synthesis contracts and their content-free operation telemetry.
  """

  use ExUnit.Case, async: false

  defmodule Provider do
    @moduledoc "Returns empty reasoning results while recording operation-level usage."
    @behaviour MemHouse.Model.Provider

    alias MemHouse.Model.Provider.Result
    alias MemHouse.Model.Providers.Deterministic

    @impl true
    @doc "Returns an empty structured reasoning result with deterministic usage."
    def structured(_config, _messages, _schema, opts) do
      if pid = Application.get_env(:memhouse, :reasoning_operation_test_pid) do
        send(pid, {:reasoning_provider_call, Keyword.fetch!(opts, :task), opts})
      end

      {:ok,
       %Result{
         value: %{"items" => [], "relations" => []},
         usage: %{input_tokens: 7, output_tokens: 3}
       }}
    end

    @impl true
    @doc "Delegates chat calls to the deterministic provider."
    def chat(config, messages, opts), do: Deterministic.chat(config, messages, opts)

    @impl true
    @doc "Delegates embedding calls to the deterministic provider."
    def embed(config, texts, opts), do: Deterministic.embed(config, texts, opts)

    @impl true
    @doc "Delegates reranking calls to the deterministic provider."
    def rerank(config, query, documents, opts),
      do: Deterministic.rerank(config, query, documents, opts)
  end

  defmodule DeadlineClock do
    @moduledoc "Returns deterministic monotonic readings for pass-deadline tests."
    @behaviour MemHouse.Clock

    @impl true
    def utc_now, do: MemHouse.Clock.System.utc_now()

    @impl true
    def monotonic_ms do
      Agent.get_and_update(
        Application.fetch_env!(:memhouse, :reasoning_operation_test_clock),
        fn [reading | rest] -> {reading, rest} end
      )
    end
  end

  alias MemHouse.Model.Reasoner
  alias MemHouse.Model.Schema.{ReasoningSynthesis, ReasoningUpdate}

  @account_id Ecto.UUID.generate()
  @scope_id Ecto.UUID.generate()
  @first_id Ecto.UUID.generate()
  @second_id Ecto.UUID.generate()
  @first_source_id Ecto.UUID.generate()
  @second_source_id Ecto.UUID.generate()

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

  test "synthesis requires two durable observations and keeps rejections content-free" do
    same_source_context =
      context(%{
        reasoning_inputs: [
          input(@first_id, @first_source_id),
          input(@second_id, @first_source_id)
        ]
      })

    assert {:error, [source_error]} =
             ReasoningSynthesis.cast(
               %{"items" => [deduction()], "relations" => []},
               same_source_context
             )

    assert source_error =~ "at least two distinct durable sources"
    refute source_error =~ @first_source_id
    refute source_error =~ "weekly release summaries"

    outside_id = Ecto.UUID.generate()
    outside = put_in(deduction(), ["contributor_ids"], [@first_id, outside_id])

    assert {:error, [authorization_error]} =
             ReasoningSynthesis.cast(
               %{"items" => [outside], "relations" => []},
               context()
             )

    assert authorization_error =~ "active authorized inputs"
    refute authorization_error =~ outside_id

    foreign_account_context =
      context(%{
        reasoning_inputs: [
          input(@first_id, @first_source_id),
          input(@second_id, @second_source_id)
          |> Map.put(:account_id, Ecto.UUID.generate())
        ]
      })

    assert {:error, [foreign_error]} =
             ReasoningSynthesis.cast(
               %{"items" => [deduction()], "relations" => []},
               foreign_account_context
             )

    assert foreign_error =~ "active authorized inputs"
    refute foreign_error =~ @second_source_id
  end

  test "operation enablement is explicit and keeps synthesis off until ablation approval" do
    refute Reasoner.split_enabled?()
    assert Reasoner.enabled_operations() == [:update]

    Application.put_env(:memhouse, :dream_reasoning_operations,
      split_enabled: true,
      update: true,
      synthesis: true
    )

    assert Reasoner.split_enabled?()
    assert Reasoner.enabled_operations() == [:update, :synthesis]

    Application.put_env(:memhouse, :dream_reasoning_operations,
      split_enabled: true,
      update: false,
      synthesis: false
    )

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

  test "elapsed pass budget stops before a second reasoning operation without losing first usage" do
    Application.put_env(:memhouse, :dream_reasoning_operations,
      split_enabled: true,
      update: true,
      synthesis: true
    )

    install_deadline_clock([100, 100, 120])

    handler = {__MODULE__, self(), :deadline_operation}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, measurements, metadata, _config ->
          send(parent, {:deadline_operation, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    result =
      Reasoner.reason_operations(%{delta: [], working_set: []}, context(), request_timeout: 20)

    assert_receive {:reasoning_provider_call, :reasoning_update, opts}
    assert Keyword.fetch!(opts, :request_timeout) == 20

    assert_receive {:deadline_operation, %{input_tokens: 7, output_tokens: 3},
                    %{
                      operation: "reasoning_update",
                      status: "ok"
                    }}

    refute_receive {:reasoning_provider_call, :reasoning_synthesis, _opts}
    refute_receive {:deadline_operation, _measurements, %{operation: "reasoning_synthesis"}}
    assert result == {:error, :request_timeout}
  end

  test "each reasoning operation receives only the pass time that remains" do
    Application.put_env(:memhouse, :dream_reasoning_operations,
      split_enabled: true,
      update: true,
      synthesis: true
    )

    install_deadline_clock([100, 100, 107])

    assert {:ok, _result, _provenance} =
             Reasoner.reason_operations(%{delta: [], working_set: []}, context(),
               request_timeout: 20
             )

    assert_receive {:reasoning_provider_call, :reasoning_update, update_opts}
    assert Keyword.fetch!(update_opts, :request_timeout) == 20

    assert_receive {:reasoning_provider_call, :reasoning_synthesis, synthesis_opts}
    assert Keyword.fetch!(synthesis_opts, :request_timeout) == 13
  end

  defp install_deadline_clock(readings) do
    previous_clock = Application.get_env(:memhouse, :clock)
    clock = start_supervised!({Agent, fn -> readings end})
    Application.put_env(:memhouse, :clock, DeadlineClock)
    Application.put_env(:memhouse, :reasoning_operation_test_clock, clock)
    Application.put_env(:memhouse, :reasoning_operation_test_pid, self())

    on_exit(fn ->
      if previous_clock,
        do: Application.put_env(:memhouse, :clock, previous_clock),
        else: Application.delete_env(:memhouse, :clock)

      Application.delete_env(:memhouse, :reasoning_operation_test_clock)
      Application.delete_env(:memhouse, :reasoning_operation_test_pid)
    end)
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        account_id: @account_id,
        scope_id: @scope_id,
        known_peer_keys: ["avery"],
        source_peer_key: "avery",
        model_provider: Provider,
        reasoning_inheritance: %{sensitivity: "internal", target_level: "peer"},
        reasoning_inputs: [
          input(@first_id, @first_source_id),
          input(@second_id, @second_source_id)
        ]
      },
      overrides
    )
  end

  defp input(id, source_id) do
    %{
      id: id,
      account_id: @account_id,
      scope_id: @scope_id,
      state: "active",
      sensitivity: "internal",
      target_level: "peer",
      source_observations: [
        %{source_type: "message", source_id: source_id}
      ]
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
