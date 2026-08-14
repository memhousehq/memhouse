# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.SchemaExtractionTest do
  @moduledoc """
  Pins the compact extraction schema and its anchored confidence levels.

  The cast path maps three model choices to stable stored fractions. It does not
  request reasoning, an operation, or a revalidation policy from the model.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Model.Schema.Extraction

  @account_id Ecto.UUID.generate()
  @scope_id Ecto.UUID.generate()
  @message_id Ecto.UUID.generate()
  @other_message_id Ecto.UUID.generate()

  defp context do
    %{
      account_id: @account_id,
      scope_id: @scope_id,
      known_peer_keys: ["avery"],
      source_peer_key: "avery",
      grounding_mode: :ingest,
      window_message_ids: [@message_id, @other_message_id],
      window_messages: [
        %{
          "id" => @message_id,
          "content" => "Avery prefers weekly release summaries."
        },
        %{"id" => @other_message_id, "content" => "Avery sends them on Friday."}
      ]
    }
  end

  defp item(confidence_level) do
    %{
      "supporting_span" => "Avery prefers weekly release summaries.",
      "statement" => "Avery prefers weekly release summaries.",
      "kind" => "preference",
      "subject_type" => "peer",
      "subject_ref" => "avery",
      "source_message_ids" => [@message_id],
      "confidence_level" => confidence_level,
      "sensitivity" => "internal",
      "target_level" => "peer"
    }
  end

  defp cast_confidence(confidence_level) do
    case Extraction.cast(%{"items" => [item(confidence_level)]}, context()) do
      {:ok, [candidate]} -> {:ok, candidate.confidence}
      {:error, errors} -> {:error, errors}
    end
  end

  defp cast_item(item), do: Extraction.cast(%{"items" => [item]}, context())

  test "maps the anchored confidence levels to stored values" do
    assert {:ok, 1.0} = cast_confidence("stated_explicitly")
    assert {:ok, 0.8} = cast_confidence("clearly_implied")
    assert {:ok, 0.6} = cast_confidence("inferred")
  end

  test "repeated casts keep confidence and the gate-side evidence decision stable" do
    response = %{"items" => [item("clearly_implied")]}

    assert {:ok, [first]} = Extraction.cast(response, context())
    assert {:ok, [second]} = Extraction.cast(response, context())
    assert {first.confidence, first.evidence_level} == {0.8, "direct"}
    assert {first.confidence, first.evidence_level} == {second.confidence, second.evidence_level}
  end

  test "advertises ordered properties and described enums" do
    candidate = get_in(Extraction.json_schema(), ["properties", "items", "items"])

    confidence =
      get_in(candidate, ["properties", "confidence_level"])

    assert confidence["enum"] == ~w(stated_explicitly clearly_implied inferred)

    assert ["supporting_span", "statement", "confidence_level" | _] =
             candidate["propertyOrdering"]

    assert candidate["properties"]["supporting_span"]["minLength"] == 1
    assert "supporting_span" in candidate["required"]
    refute Map.has_key?(candidate["properties"], "reasoning")
    refute Map.has_key?(candidate["properties"], "update_operation")
    refute Map.has_key?(candidate["properties"], "revalidate_after")
    refute Map.has_key?(candidate["properties"], "expires_at")
    assert is_binary(candidate["properties"]["kind"]["description"])
    assert is_binary(candidate["properties"]["sensitivity"]["description"])
    assert is_binary(candidate["properties"]["target_level"]["description"])
    assert candidate["properties"]["relevant_from"]["description"] =~ "otherwise null"
    assert candidate["properties"]["relevant_until"]["description"] =~ "otherwise null"
  end

  test "rejects an equal valid-time boundary" do
    timestamp = "2026-08-14T07:00:00Z"

    candidate =
      item("stated_explicitly")
      |> Map.put("relevant_from", timestamp)
      |> Map.put("relevant_until", timestamp)

    assert {:error, ["items[0].relevant_from must be before relevant_until"]} =
             cast_item(candidate)
  end

  test "rejects an invalid confidence level" do
    assert {:error, ["items[0].confidence_level is invalid"]} = cast_confidence("high")
    assert {:error, ["items[0].confidence_level must be a string"]} = cast_confidence(nil)
  end

  test "rejects fields outside the advertised candidate schema" do
    candidate = Map.put(item("stated_explicitly"), "reasoning", "Discarded output")

    assert {:error, ["items[0].candidate contains unsupported fields"]} =
             cast_item(candidate)
  end

  test "derives direct evidence from the resolved source and subject" do
    assert {:ok, [candidate]} = cast_item(item("stated_explicitly"))
    assert candidate.evidence_level == "direct"
    assert candidate.confidence == 1.0
  end

  test "accepts source ids from the supplied conversation window" do
    candidate =
      item("stated_explicitly")
      |> Map.put("source_message_ids", [@message_id, @other_message_id])

    assert {:ok, [casted]} = cast_item(candidate)
    assert casted.source_message_ids == [@message_id, @other_message_id]
  end

  test "rejects a source id outside the supplied conversation window" do
    candidate = item("stated_explicitly") |> Map.put("source_message_ids", [Ecto.UUID.generate()])

    assert {:error,
            [
              "items[0].source_message_ids must be unique ids from the supplied observation window"
            ]} =
             cast_item(candidate)
  end

  test "rejects a supporting span that is not in a cited message" do
    candidate =
      item("stated_explicitly")
      |> Map.put("supporting_span", "Avery has been married for twelve years.")

    assert {:error, ["items[0].supporting_span must be exact text from a cited source"]} =
             cast_item(candidate)
  end

  test "rejects ingest grounding when cited content is unavailable" do
    missing_content = %{context() | window_messages: []}

    assert {:error, ["items[0].cited source content must be available for grounding"]} =
             Extraction.cast(%{"items" => [item("stated_explicitly")]}, missing_content)
  end

  test "rejects an answer supported only by a question" do
    question_context = %{
      context()
      | window_messages: [%{"id" => @message_id, "content" => "What pets does Avery have?"}],
        window_message_ids: [@message_id]
    }

    candidate =
      item("stated_explicitly")
      |> Map.merge(%{
        "supporting_span" => "What pets does Avery have?",
        "statement" => "Avery has a dog."
      })

    assert {:error, ["items[0].supporting_span must assert knowledge, not ask a question"]} =
             Extraction.cast(%{"items" => [candidate]}, question_context)
  end

  test "rejects an invented date even when the candidate quotes a question" do
    context = %{
      context()
      | window_messages: [
          %{"id" => @message_id, "content" => "How long have you been married?"}
        ],
        window_message_ids: [@message_id]
    }

    candidate =
      item("stated_explicitly")
      |> Map.merge(%{
        "supporting_span" => "How long have you been married?",
        "statement" => "Avery was married on 2023-06-09.",
        "source_message_ids" => [@message_id]
      })

    assert {:error, ["items[0].supporting_span must assert knowledge, not ask a question"]} =
             Extraction.cast(%{"items" => [candidate]}, context)
  end

  test "accepts a resolved date when the cited source gives relative time" do
    context =
      context()
      |> Map.merge(%{
        window_messages: [
          %{"id" => @message_id, "content" => "Avery moved home four years ago."}
        ],
        window_message_ids: [@message_id],
        occurred_at: ~U[2026-08-14 12:00:00Z]
      })

    candidate =
      item("stated_explicitly")
      |> Map.merge(%{
        "supporting_span" => "Avery moved home four years ago.",
        "statement" => "Avery moved home in 2022-08-14.",
        "source_message_ids" => [@message_id]
      })

    assert {:ok, [_]} = Extraction.cast(%{"items" => [candidate]}, context)

    mismatched = Map.put(candidate, "statement", "Avery moved home in 2021-08-14.")

    assert {:error, ["items[0].statement must be supported by its cited source text"]} =
             Extraction.cast(%{"items" => [mismatched]}, context)
  end

  test "resolves every advertised relative-date form" do
    for {expression, expected_date} <- [
          {"yesterday", "2026-08-13"},
          {"today", "2026-08-14"},
          {"tonight", "2026-08-14"},
          {"tomorrow", "2026-08-15"},
          {"two days ago", "2026-08-12"},
          {"2 weeks ago", "2026-07-31"},
          {"one month ago", "2026-07-14"},
          {"one year ago", "2025-08-14"},
          {"2 days from now", "2026-08-16"}
        ] do
      source = "Avery scheduled the release #{expression}."

      relative_context =
        context()
        |> Map.merge(%{
          window_messages: [%{"id" => @message_id, "content" => source}],
          window_message_ids: [@message_id],
          occurred_at: ~U[2026-08-14 12:00:00Z]
        })

      candidate =
        item("stated_explicitly")
        |> Map.merge(%{
          "supporting_span" => source,
          "statement" => "Avery scheduled the release for #{expected_date}."
        })

      assert {:ok, [_]} = Extraction.cast(%{"items" => [candidate]}, relative_context)
    end
  end

  test "checks all relative expressions in cited text" do
    source = "Avery reviewed it yesterday and will publish two days from now."

    relative_context =
      context()
      |> Map.merge(%{
        window_messages: [%{"id" => @message_id, "content" => source}],
        window_message_ids: [@message_id],
        occurred_at: ~U[2026-08-14 12:00:00Z]
      })

    candidate =
      item("stated_explicitly")
      |> Map.merge(%{
        "supporting_span" => source,
        "statement" => "Avery will publish on 2026-08-16."
      })

    assert {:ok, [_]} = Extraction.cast(%{"items" => [candidate]}, relative_context)

    mismatched = Map.put(candidate, "statement", "Avery will publish on 2026-08-17.")

    assert {:error, ["items[0].statement must be supported by its cited source text"]} =
             Extraction.cast(%{"items" => [mismatched]}, relative_context)
  end

  test "rejects non-exact relative-date terms" do
    source = "Avery reviewed it todayish and will publish tomorrowish."

    relative_context =
      context()
      |> Map.merge(%{
        window_messages: [%{"id" => @message_id, "content" => source}],
        window_message_ids: [@message_id],
        occurred_at: ~U[2026-08-14 12:00:00Z]
      })

    candidate =
      item("stated_explicitly")
      |> Map.merge(%{
        "supporting_span" => source,
        "statement" => "Avery reviewed it on 2026-08-14."
      })

    assert {:error, ["items[0].statement must be supported by its cited source text"]} =
             Extraction.cast(%{"items" => [candidate]}, relative_context)
  end

  test "derives indirect evidence and its discount from source and subject" do
    indirect =
      item("stated_explicitly")
      |> Map.merge(%{
        "statement" => "Other prefers weekly release summaries.",
        "subject_ref" => "other"
      })

    context = %{context() | known_peer_keys: ["avery", "other"]}

    assert {:ok, [candidate]} = Extraction.cast(%{"items" => [indirect]}, context)
    assert candidate.evidence_level == "indirect"
    assert candidate.confidence == 0.75
  end

  test "rejects a question instead of storing it as knowledge" do
    question =
      item("stated_explicitly")
      |> Map.put("statement", "Does Avery prefer weekly release summaries?")

    assert {:error, ["items[0].statement must assert knowledge, not record a question"]} =
             cast_item(question)
  end

  test "rejects speech-act transcriptions and conversational filler" do
    for statement <- [
          "Avery said that weekly release summaries are best.",
          "Avery said to Melanie: weekly release summaries are best.",
          "Avery told Melanie that weekly release summaries are best.",
          "Avery mentioned to Melanie that weekly release summaries are best.",
          "Avery wrote: \"Weekly release summaries are best.\"",
          "Avery greeted Melanie.",
          "Avery thanked Melanie for the help.",
          "Avery complimented Melanie's bowl.",
          "Avery wished Melanie a great time."
        ] do
      transcription = item("stated_explicitly") |> Map.put("statement", statement)

      assert {:error, ["items[0].statement must assert the fact, not record a speech act"]} =
               cast_item(transcription)
    end
  end

  test "keeps durable actions that use a reporting verb" do
    for statement <- [
          "Avery wrote a book about retrieval systems.",
          "Avery mentioned Melanie in the release notes."
        ] do
      candidate = item("stated_explicitly") |> Map.put("statement", statement)

      assert {:ok, [_]} = cast_item(candidate)
    end
  end

  test "rejects a peer claim that does not name its subject" do
    generic =
      item("stated_explicitly") |> Map.put("statement", "Running can really boost your mood.")

    assert {:error, ["items[0].statement must name its peer subject"]} = cast_item(generic)
  end

  test "keeps a proper name that ends in ing" do
    candidate = item("stated_explicitly") |> Map.put("statement", "Vanishing indexer statement.")

    assert {:ok, [_]} = cast_item(candidate)
  end

  test "rejects a statement about the relaying agent" do
    context = Map.put(context(), :forbidden_subject_terms, ["relay-agent", "the assistant"])

    for statement <- [
          "The assistant is allergic to shellfish.",
          "Relay-agent joined the mentorship programme."
        ] do
      candidate = item("stated_explicitly") |> Map.put("statement", statement)

      assert {:error, ["items[0].statement must be about a person, not about the relaying agent"]} =
               Extraction.cast(%{"items" => [candidate]}, context)
    end
  end

  test "matches a hyphenated agent key whole, and not inside a longer one" do
    context = Map.put(context(), :forbidden_subject_terms, ["membench-agent", "bot"])

    # A key is usually hyphenated, so a boundary rule that treats the hyphen as a separator
    # tears the key apart and never matches the identity it exists to catch.
    rejected =
      item("stated_explicitly")
      |> Map.put("statement", "Membench-agent joined the mentorship programme.")

    assert {:error, ["items[0].statement must be about a person, not about the relaying agent"]} =
             Extraction.cast(%{"items" => [rejected]}, context)

    # The same boundary must still refuse to find a short key inside a longer hyphenated one.
    kept =
      item("stated_explicitly")
      |> Map.put("statement", "Avery deployed the bot-x release on Friday.")

    assert {:ok, [_]} = Extraction.cast(%{"items" => [kept]}, context)
  end

  test "keeps a person whose name merely contains a forbidden term" do
    context = Map.put(context(), :forbidden_subject_terms, ["bot"])

    candidate =
      item("stated_explicitly") |> Map.put("statement", "Avery bottles cider every autumn.")

    # Word edges matter: a substring match would refuse half the language.
    assert {:ok, [_]} = Extraction.cast(%{"items" => [candidate]}, context)
  end
end
