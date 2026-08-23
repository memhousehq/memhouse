# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.SchemaExtractionBatchTest do
  @moduledoc """
  Pins per-anchor attribution and deterministic extraction admission.

  These tests stay below the provider seam. They prove that one batch cannot
  cite an id outside an anchor's own evidence window, that repair exhaustion
  isolates a poison envelope, and that admission uses a pinned pre-call
  identity rather than provider-reported usage.
  """

  use ExUnit.Case, async: false

  alias MemHouse.Model.Schema.ExtractionBatch
  alias MemHouse.Pipeline.ExtractionAdmission
  alias MemHouse.Pipeline.ExtractionBatcher

  setup do
    original = Application.fetch_env!(:memhouse, :extraction_batching)
    on_exit(fn -> Application.put_env(:memhouse, :extraction_batching, original) end)
  end

  test "validates each envelope against its own supplied source ids" do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    contexts = contexts(first_id, second_id)

    response = %{
      "anchors" => [
        envelope(first_id, "Avery owns the release checklist.", "avery", first_id),
        envelope(second_id, "Blair prefers concise reports.", "blair", second_id)
      ]
    }

    assert {:ok,
            [
              %{anchor_id: ^first_id, status: :ok, items: [first]},
              %{anchor_id: ^second_id, status: :ok, items: [second]}
            ]} = ExtractionBatch.cast(response, %{anchor_contexts: contexts})

    assert first.source_message_ids == [first_id]
    assert second.source_message_ids == [second_id]

    crossed =
      put_in(response, ["anchors", Access.at(0), "items", Access.at(0), "source_message_ids"], [
        second_id
      ])

    assert {:error, errors} = ExtractionBatch.cast(crossed, %{anchor_contexts: contexts})
    assert Enum.any?(errors, &String.contains?(&1, "ids from the supplied observation window"))
  end

  test "advertises the configured anchor bound in the provider schema" do
    Application.put_env(:memhouse, :extraction_batching,
      target_tokens: 1_024,
      max_anchors: 4,
      context_limit_tokens: 16_384,
      reserved_output_tokens: 1_024,
      safety_margin_tokens: 512,
      claim_timeout_seconds: 300
    )

    anchors = get_in(ExtractionBatch.json_schema(), ["properties", "anchors"])
    assert anchors["minItems"] == 1
    assert anchors["maxItems"] == 4
  end

  test "repair exhaustion retains a valid sibling and terminally isolates poison" do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    contexts = contexts(first_id, second_id)

    response = %{
      "anchors" => [
        envelope(first_id, "Avery owns the release checklist.", "avery", first_id),
        %{"anchor_id" => second_id, "items" => [%{"statement" => "invalid"}]}
      ]
    }

    assert {:ok, results} =
             ExtractionBatch.recover_after_repairs(response, %{anchor_contexts: contexts})

    assert %{status: :ok, items: [_]} = Enum.find(results, &(&1.anchor_id == first_id))

    assert %{status: :terminal, reason_class: "structured_validation_exhausted"} =
             Enum.find(results, &(&1.anchor_id == second_id))
  end

  test "pins target variants and rejects an oversized request before a provider call" do
    assert ExtractionAdmission.allowed_targets() == [128, 1_024, 4_096, 16_384]
    assert ExtractionAdmission.tokenizer() == "utf8-bytes-v1"

    Application.put_env(:memhouse, :extraction_batching,
      target_tokens: 128,
      max_anchors: 4,
      context_limit_tokens: 64,
      reserved_output_tokens: 16,
      safety_margin_tokens: 8,
      claim_timeout_seconds: 300
    )

    assert {:error, %{reason_class: "oversized", identity: identity}} =
             ExtractionAdmission.admit(
               [%{role: "user", content: String.duplicate("x", 100)}],
               %{"type" => "object"}
             )

    assert identity =~ "utf8-bytes-v1:target=128:context=64:output=16:margin=8"
  end

  test "classifies deterministic provider output failures for operator repair" do
    for reason <- [
          :provider_output_truncated,
          :provider_content_filtered,
          :missing_structured_object
        ] do
      assert {:repairable, class} = ExtractionBatcher.failure_class(reason)
      assert class == Atom.to_string(reason)
    end

    assert ExtractionBatcher.failure_class(:provider_unavailable) ==
             {:retryable, "provider_transient"}

    assert ExtractionBatcher.failure_class(%MemHouse.Model.ProviderCircuit.OpenError{}) ==
             {:retryable, "provider_circuit_open"}

    assert ExtractionBatcher.failure_class({:structured_validation_failed, ["shape"]}) ==
             {:terminal, "structured_validation_exhausted"}

    assert ExtractionBatcher.failure_class(%ReqLLM.Error.Invalid.Parameter{parameter: :model}) ==
             {:repairable, "configuration"}

    assert ExtractionBatcher.failure_class(%ReqLLM.Error.Validation.Error{
             tag: :model,
             reason: "invalid",
             context: []
           }) == {:repairable, "configuration"}
  end

  defp contexts(first_id, second_id) do
    account_id = Ecto.UUID.generate()
    scope_id = Ecto.UUID.generate()
    occurred_at = ~U[2026-08-17 08:00:00Z]

    %{
      first_id =>
        context(
          account_id,
          scope_id,
          occurred_at,
          first_id,
          "avery",
          "Avery owns the release checklist."
        ),
      second_id =>
        context(
          account_id,
          scope_id,
          occurred_at,
          second_id,
          "blair",
          "Blair prefers concise reports."
        )
    }
  end

  defp context(account_id, scope_id, occurred_at, message_id, peer_key, content) do
    %{
      account_id: account_id,
      scope_id: scope_id,
      scope_path: "/batch",
      source_peer_id: Ecto.UUID.generate(),
      source_peer_key: peer_key,
      message_id: message_id,
      occurred_at: occurred_at,
      known_peer_keys: [peer_key],
      forbidden_subject_terms: [],
      grounding_mode: :ingest,
      window_message_ids: [message_id],
      window_messages: [
        %{
          "id" => message_id,
          "peer_key" => peer_key,
          "occurred_at" => occurred_at,
          "content" => content
        }
      ]
    }
  end

  defp envelope(anchor_id, statement, subject_ref, source_id) do
    %{
      "anchor_id" => anchor_id,
      "items" => [
        %{
          "supporting_span" => statement,
          "statement" => statement,
          "confidence_level" => "stated_explicitly",
          "kind" => "fact",
          "subject_type" => "peer",
          "subject_ref" => subject_ref,
          "sensitivity" => "internal",
          "target_level" => "peer",
          "source_message_ids" => [source_id],
          "relevant_from" => nil,
          "relevant_until" => nil
        }
      ]
    }
  end
end
