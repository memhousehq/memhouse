# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.ObservabilityOperationTest do
  @moduledoc """
  Verifies that operation aggregates normalize allowlisted counters and discard content.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Observability

  test "emits one normalized operation aggregate and drops content-bearing keys" do
    handler = "operation-aggregate-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn event, measurements, metadata, _config ->
          send(parent, {:operation, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Observability.emit_operation(
               :recall,
               %{
                 calls: 2,
                 batch_requests: 1,
                 provider_attempts: 3,
                 candidates: 5,
                 stale_claims: 1,
                 elapsed_ms: 12,
                 input_tokens: -1
               },
               %{
                 run_id: "run-1",
                 version: "minimal-v1",
                 status: "degraded",
                 profile: "minimal",
                 query: "must never escape",
                 prompt: "must never escape"
               }
             )

    assert_receive {:operation, [:memhouse, :operation, :completed], measurements, metadata}
    assert measurements.calls == 2
    assert measurements.batch_requests == 1
    assert measurements.provider_attempts == 3
    assert measurements.candidates == 5
    assert measurements.stale_claims == 1
    assert measurements.elapsed_ms == 12
    assert measurements.input_tokens == 0
    assert measurements.output_tokens == 0
    assert metadata.operation == "recall"
    assert metadata.run_id == "run-1"
    assert metadata.version == "minimal-v1"
    assert metadata.status == "degraded"
    assert metadata.profile == "minimal"
    refute Map.has_key?(metadata, :query)
    refute Map.has_key?(metadata, :prompt)
  end

  test "normalizes untrusted operation and metadata values before emission" do
    handler = "operation-safety-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :operation, :completed],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:safe_operation, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Observability.emit_operation("credential=do-not-emit", %{}, %{
               version: "secret with spaces",
               status: "message body",
               failure_class: "api_key_value",
               account_id: "not-a-uuid"
             })

    assert_receive {:safe_operation, metadata}
    assert metadata.operation == "unknown"
    assert metadata.version == "unknown"
    assert metadata.status == "unknown"
    assert metadata.failure_class == "unknown_failure"
    refute Map.has_key?(metadata, :account_id)
    refute inspect(metadata) =~ "do-not-emit"
    refute inspect(metadata) =~ "secret with spaces"
    refute inspect(metadata) =~ "api_key_value"
  end
end
