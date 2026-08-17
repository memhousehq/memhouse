# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.SchemaCompactExtractionTest do
  @moduledoc """
  Pins the experimental explicit-fact extraction seam.

  The model supplies only claim text and source-grounded identity/time evidence.
  Trusted code supplies every policy-bearing field before delegating to the
  ordinary extraction validator, so this experiment cannot bypass its safety
  boundary.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Model.Schema.CompactExtraction
  alias MemHouse.Model.Schema.CompactExtractionBatch

  @account_id Ecto.UUID.generate()
  @scope_id Ecto.UUID.generate()
  @message_id Ecto.UUID.generate()

  defp context(content \\ "Avery prefers weekly release summaries.") do
    %{
      account_id: @account_id,
      scope_id: @scope_id,
      scope_path: "/team",
      known_peer_keys: ["avery", "blair"],
      source_peer_key: "avery",
      grounding_mode: :ingest,
      occurred_at: ~U[2026-08-17 14:30:00Z],
      window_message_ids: [@message_id],
      window_messages: [
        %{"id" => @message_id, "peer_key" => "avery", "content" => content}
      ],
      forbidden_subject_terms: ["relay-agent"]
    }
  end

  defp item(overrides \\ %{}) do
    Map.merge(
      %{
        "supporting_span" => "Avery prefers weekly release summaries.",
        "statement" => "Avery prefers weekly release summaries.",
        "subject_ref" => "avery",
        "source_message_ids" => [@message_id],
        "relevant_from_evidence" => nil,
        "relevant_until_evidence" => nil
      },
      overrides
    )
  end

  test "advertises only explicit claim, attribution, and valid-time evidence" do
    candidate = get_in(CompactExtraction.json_schema(), ["properties", "items", "items"])

    assert candidate["additionalProperties"] == false

    assert candidate["required"] == [
             "supporting_span",
             "statement",
             "subject_ref",
             "source_message_ids",
             "relevant_from_evidence",
             "relevant_until_evidence"
           ]

    assert Map.keys(candidate["properties"]) |> Enum.sort() ==
             Enum.sort(candidate["required"])

    for omitted <-
          ~w(kind confidence confidence_level evidence_level sensitivity target_level subject_type reasoning) do
      refute Map.has_key?(candidate["properties"], omitted)
    end
  end

  test "derives the most restrictive policy defaults and direct confidence" do
    assert {:ok, [candidate]} = CompactExtraction.cast(%{"items" => [item()]}, context())

    assert candidate.kind == "fact"
    assert candidate.sensitivity == "restricted"
    assert candidate.target_level == "peer"
    assert candidate.subject_type == "peer"
    assert candidate.subject_ref == "avery"
    assert candidate.evidence_level == "direct"
    assert candidate.confidence == 1.0
  end

  test "derives indirect evidence and the existing third-party discount" do
    candidate =
      item(%{
        "supporting_span" => "Avery reports that Blair owns the release checklist.",
        "statement" => "Blair owns the release checklist.",
        "subject_ref" => "blair"
      })

    assert {:ok, [casted]} =
             CompactExtraction.cast(
               %{"items" => [candidate]},
               context("Avery reports that Blair owns the release checklist.")
             )

    assert casted.evidence_level == "indirect"
    assert casted.confidence == 0.75
    assert casted.sensitivity == "restricted"
    assert casted.target_level == "peer"
  end

  test "derives scope identity and never widens it beyond the current scope" do
    candidate =
      item(%{
        "supporting_span" => "The team deploys on Tuesdays.",
        "statement" => "The team deploys on Tuesdays.",
        "subject_ref" => "/team"
      })

    assert {:ok, [casted]} =
             CompactExtraction.cast(
               %{"items" => [candidate]},
               context("The team deploys on Tuesdays.")
             )

    assert casted.subject_type == "scope"
    assert casted.target_level == "scope"
    assert casted.sensitivity == "restricted"

    assert {:error, errors} =
             CompactExtraction.cast(
               %{"items" => [Map.put(candidate, "subject_ref", "/other")]},
               context("The team deploys on Tuesdays.")
             )

    assert Enum.any?(errors, &String.contains?(&1, "subject_ref must name a known peer"))
  end

  test "resolves exact relative valid-time evidence in trusted code" do
    source = "Avery starts the migration tomorrow and completes it two days from now."

    candidate =
      item(%{
        "supporting_span" => source,
        "statement" => "Avery performs the migration.",
        "relevant_from_evidence" => "tomorrow",
        "relevant_until_evidence" => "two days from now"
      })

    assert {:ok, [casted]} = CompactExtraction.cast(%{"items" => [candidate]}, context(source))
    assert casted.relevant_from == ~U[2026-08-18 00:00:00Z]
    assert casted.relevant_until == ~U[2026-08-19 00:00:00Z]
  end

  test "rejects temporal evidence that is absent, ambiguous, or reverses the window" do
    source = "Avery starts the migration tomorrow."

    absent = item(%{"supporting_span" => source, "relevant_from_evidence" => "next week"})

    assert {:error, errors} = CompactExtraction.cast(%{"items" => [absent]}, context(source))
    assert Enum.any?(errors, &String.contains?(&1, "valid-time evidence must be exact"))

    ambiguous =
      item(%{"supporting_span" => source, "relevant_from_evidence" => "the migration"})

    assert {:error, errors} =
             CompactExtraction.cast(%{"items" => [ambiguous]}, context(source))

    assert Enum.any?(errors, &String.contains?(&1, "valid-time evidence is unsupported"))

    reversed_source = "Avery worked yesterday and finishes today."

    reversed =
      item(%{
        "supporting_span" => reversed_source,
        "relevant_from_evidence" => "today",
        "relevant_until_evidence" => "yesterday"
      })

    assert {:error, errors} =
             CompactExtraction.cast(%{"items" => [reversed]}, context(reversed_source))

    assert Enum.any?(errors, &String.contains?(&1, "relevant_from must be before relevant_until"))
  end

  test "retains first-person, hostile subject, exact span, and unknown-field guards" do
    first_person = "I increased quarterly revenue by closing three enterprise contracts."

    assert {:ok, [casted]} =
             CompactExtraction.cast(
               %{
                 "items" => [
                   item(%{
                     "supporting_span" => first_person,
                     "statement" =>
                       "Avery increased quarterly revenue by closing three enterprise contracts.",
                     "subject_ref" => "blair"
                   })
                 ]
               },
               context(first_person)
             )

    assert casted.subject_ref == "avery"

    assert {:error, errors} =
             CompactExtraction.cast(
               %{"items" => [item(%{"subject_ref" => "unknown"})]},
               context()
             )

    assert Enum.any?(errors, &String.contains?(&1, "subject_ref must name a known peer"))

    assert {:error, errors} =
             CompactExtraction.cast(
               %{"items" => [item(%{"supporting_span" => "invented"})]},
               context()
             )

    assert Enum.any?(errors, &String.contains?(&1, "supporting_span must be exact"))

    assert {:error, errors} =
             CompactExtraction.cast(
               %{"items" => [Map.put(item(), "sensitivity", "public")]},
               context()
             )

    assert Enum.any?(errors, &String.contains?(&1, "candidate contains unsupported fields"))
  end

  test "keeps compact candidates inside their batch anchor's evidence window" do
    other_id = Ecto.UUID.generate()
    first_context = context()

    second_context = %{
      context("Blair owns the incident rota.")
      | source_peer_key: "blair",
        window_message_ids: [other_id],
        window_messages: [
          %{
            "id" => other_id,
            "peer_key" => "blair",
            "content" => "Blair owns the incident rota."
          }
        ]
    }

    object = %{
      "anchors" => [
        %{"anchor_id" => @message_id, "items" => [item()]},
        %{
          "anchor_id" => other_id,
          "items" => [
            item(%{
              "supporting_span" => "Blair owns the incident rota.",
              "statement" => "Blair owns the incident rota.",
              "subject_ref" => "blair",
              "source_message_ids" => [other_id]
            })
          ]
        }
      ]
    }

    assert {:ok, [%{status: :ok}, %{status: :ok}]} =
             CompactExtractionBatch.cast(object, %{
               anchor_contexts: %{@message_id => first_context, other_id => second_context}
             })

    crossed =
      put_in(object, ["anchors", Access.at(0), "items", Access.at(0), "source_message_ids"], [
        other_id
      ])

    assert {:error, errors} =
             CompactExtractionBatch.cast(crossed, %{
               anchor_contexts: %{@message_id => first_context, other_id => second_context}
             })

    assert Enum.any?(errors, &String.contains?(&1, "ids from the supplied observation window"))
  end
end
