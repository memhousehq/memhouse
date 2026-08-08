# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.SchemaExtractionTest do
  @moduledoc """
  Pins `MemHouse.Model.Schema.Extraction.cast/2` percentage handling.

  Providers receive a strict integer `confidence_percentage` schema from 1
  through 100. The cast path accepts a decorated string defensively, strips
  non-digits, then normalizes the valid percentage to the stored 0.0–1.0
  fraction. It never persists model reasoning.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Model.Schema.Extraction

  @account_id Ecto.UUID.generate()
  @scope_id Ecto.UUID.generate()

  defp context do
    %{
      account_id: @account_id,
      scope_id: @scope_id,
      known_peer_keys: ["avery"],
      source_peer_key: "avery"
    }
  end

  defp item(confidence_percentage) do
    %{
      "reasoning" => "The source says this directly.",
      "statement" => "Avery prefers weekly release summaries.",
      "kind" => "preference",
      "subject_type" => "peer",
      "subject_ref" => "avery",
      "confidence_percentage" => confidence_percentage,
      "sensitivity" => "internal",
      "target_level" => "peer",
      "update_operation" => "add"
    }
  end

  defp cast_confidence(confidence_percentage) do
    case Extraction.cast(%{"items" => [item(confidence_percentage)]}, context()) do
      {:ok, [candidate]} -> {:ok, candidate.confidence}
      {:error, errors} -> {:error, errors}
    end
  end

  defp cast_item(item), do: Extraction.cast(%{"items" => [item]}, context())

  test "accepts a native JSON integer and normalizes it" do
    assert {:ok, 0.9} = cast_confidence(90)
  end

  test "advertises a required 1..100 integer confidence percentage" do
    confidence =
      Extraction.json_schema()
      |> get_in(["properties", "items", "items", "properties", "confidence_percentage"])

    assert confidence["type"] == "integer"
    assert confidence["minimum"] == 1
    assert confidence["maximum"] == 100

    assert ["reasoning", "statement", "confidence_percentage" | _] =
             get_in(Extraction.json_schema(), ["properties", "items", "items", "required"])
  end

  test "strips non-numeric characters before validating a percentage" do
    assert {:ok, 0.93} = cast_confidence("confidence: 93%")
  end

  test "accepts a numeric string after sanitation" do
    assert {:ok, 1.0} = cast_confidence("100")
  end

  test "rejects a percentage above 100" do
    assert {:error, ["items[0].confidence_percentage must be between 1 and 100"]} =
             cast_confidence(101)
  end

  test "rejects a sanitized percentage above 100" do
    assert {:error, ["items[0].confidence_percentage must be between 1 and 100"]} =
             cast_confidence("101%")
  end

  test "rejects a string without digits" do
    assert {:error, ["items[0].confidence_percentage must be between 1 and 100"]} =
             cast_confidence("high")
  end

  test "rejects a missing percentage" do
    assert {:error, ["items[0].confidence_percentage must be between 1 and 100"]} =
             cast_confidence(nil)
  end

  test "derives direct evidence from the resolved source and subject" do
    assert {:ok, [candidate]} = cast_item(item(90))
    assert candidate.evidence_level == "direct"
    assert candidate.confidence == 0.9
  end

  test "derives indirect evidence and its discount from source and subject" do
    indirect =
      item(90)
      |> Map.put("subject_ref", "other")

    context = %{context() | known_peer_keys: ["avery", "other"]}

    assert {:ok, [candidate]} = Extraction.cast(%{"items" => [indirect]}, context)
    assert candidate.evidence_level == "indirect"
    assert candidate.confidence == 0.675
  end
end
