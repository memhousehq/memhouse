# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.AdapterTest do
  @moduledoc """
  Pins normalization of LoCoMo, LongMemEval, ConvoMem, BEAM, and MemHouse
  fixtures into one cases/messages/questions shape.

  The suite preserves upstream evidence ids and granularity, abstention flags,
  category labels, and context-length buckets. Drift changes citation scores or
  published benchmark groupings without changing the scorer.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Eval.Adapter

  test "normalizes LoCoMo sessions and turn-level QA evidence" do
    dataset =
      Adapter.normalize(
        [
          %{
            "sample_id" => "locomo_1",
            "conversation" => %{
              "speaker_a" => "Alice",
              "speaker_b" => "Bob",
              "session_1_date_time" => "10:00 am on 1 January, 2024",
              "session_1" => [
                %{"speaker" => "Alice", "dia_id" => "D1:1", "text" => "I prefer short notes."},
                %{"speaker" => "Bob", "dia_id" => "D1:2", "text" => "I will remember that."}
              ]
            },
            "qa" => [
              %{
                "question" => "What does Alice prefer?",
                "answer" => "short notes",
                "evidence" => ["D1:1"],
                "category" => 1
              }
            ]
          }
        ],
        benchmark: "locomo"
      )

    [case] = dataset.cases
    assert dataset.benchmark == "locomo"

    # Evidence references upstream `dia_id` values verbatim.
    assert Enum.map(case.messages, & &1.id) == ["D1:1", "D1:2"]
    assert hd(case.questions).evidence_refs == ["D1:1"]

    # String categories keep summary bucket keys uniform.
    assert hd(case.questions).category == "1"
  end

  # Each LongMemEval question owns its haystack; cases must not share corpora.
  test "normalizes LongMemEval as one isolated case per question" do
    dataset =
      Adapter.normalize(
        [
          %{
            "question_id" => "q1_abs",
            "question_type" => "single-session-user",
            "question" => "What is missing?",
            "answer" => "No information available.",
            "haystack_session_ids" => ["s1"],
            "haystack_dates" => ["2024-01-01T00:00:00Z"],
            "haystack_sessions" => [[%{"role" => "user", "content" => "Alice likes tea."}]],
            "answer_session_ids" => ["s1"]
          }
        ],
        benchmark: "longmemeval"
      )

    [case] = dataset.cases
    [question] = case.questions

    assert dataset.benchmark == "longmemeval"

    # Upstream turns are unlabelled, so a stable id is composed from the
    # session id and the 1-based turn position within that session.
    assert hd(case.messages).id == "s1:1"

    # The dataset marks its unanswerable questions only by a "_abs" suffix on
    # the question id. That convention is decoded once, here, into an explicit
    # category and flag; the scorer then judges these questions on whether the
    # system abstained rather than on answer text overlap.
    assert question.category == "abstention"
    assert question.abstention_expected

    # This benchmark labels the answer *session*, never the answer turn, so
    # citation credit has to be evaluated at session granularity. Claiming
    # "turn" here would fail every citation for correct retrieval.
    assert question.evidence_granularity == "session"
  end

  test "normalizes BEAM-style conversations and probing questions" do
    dataset =
      Adapter.normalize(
        %{
          "chats" => [
            %{
              "chat_id" => "beam-a",
              "chat_size" => "128K",
              "messages" => [
                %{"turn_id" => "t1", "role" => "user", "content" => "Use metric units."}
              ],
              "probing_questions" => [
                %{
                  "question_id" => "pq1",
                  "question" => "Which units should be used?",
                  "answer" => "metric units",
                  "ability" => "Instruction Following",
                  "evidence_turns" => ["t1"]
                }
              ]
            }
          ]
        },
        benchmark: "beam"
      )

    [case] = dataset.cases

    # `scale` is the declared context length of the chat. It is the bucket key
    # for the degradation curve, which is how quality loss at longer context is
    # tracked, so it must survive normalization as the upstream label.
    assert case.scale == "128K"
    assert hd(case.messages).id == "t1"

    # This benchmark calls its question class an "ability"; it is mapped onto
    # the same `category` field the other benchmarks use so one summary
    # grouping works across all of them.
    assert hd(case.questions).category == "Instruction Following"
  end

  # The only case that goes through `load!/2` rather than `normalize/2`, so it
  # also covers reading the file from disk and digesting its bytes.
  test "normalizes ConvoMem conversations, categories, evidence, and abstention" do
    dataset =
      Adapter.load!("test/fixtures/eval/convomem-minimal.json", benchmark: "convomem")

    [preference, abstention] = dataset.cases

    assert dataset.benchmark == "convomem"
    assert dataset.source_format == "convomem"

    # 64 characters is a SHA-256 digest in lowercase hex. Every dataset carries
    # one so that a published result names the exact bytes it was measured
    # over: editing a fixture changes the digest and makes the difference
    # visible instead of silently re-baselining a score.
    assert byte_size(dataset.dataset_sha256) == 64

    assert hd(preference.messages).id == "cm-pref-1"
    assert hd(preference.questions).evidence_refs == ["cm-pref-1"]

    # The second fixture row asks something its conversation never mentions.
    # Either signal marks it: an "abstention" category or an explicit flag on
    # the row. Correctness for it means declining to answer.
    assert hd(abstention.questions).abstention_expected
  end
end
