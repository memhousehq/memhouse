# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ScorerTest do
  @moduledoc """
  Pins deterministic, model-free correctness, citation, and lexical grounding
  scores.

  Abstention replaces text matching for unanswerable questions. Citation
  recall remains independent of answer correctness. Summaries preserve overall,
  category, and context-length buckets so degradation remains visible. Model
  judging may supplement but never replace these offline release metrics.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Eval.Scorer

  test "scores expected answer overlap and citation recall" do
    question = %{
      expected: ["concise status updates"],
      evidence_refs: ["D1:1", "D2:4"],
      evidence_granularity: "turn",
      abstention_expected: false
    }

    result = %{"answer" => "Alice prefers concise status updates.", "abstained" => false}

    # The system cited one of two labelled evidence turns.
    score = Scorer.score_question(question, result, ["D2:4"])

    # Full-sentence correctness comes from expected-phrase containment.
    assert score["correct"]
    assert score["contains_expected"]

    # Recall divides by labelled references: one of two is 0.5.
    assert score["citation_hit"]
    assert score["citation_recall"] == 0.5

    assert is_number(score["groundedness"])
    assert is_number(score["context_relevance"])
    assert is_number(score["answer_relevance"])

    # Every scored row is stamped with the method that produced its triad
    # numbers, so a reader can never mistake lexical proxies for model-judged
    # ones. The embedded "f11-1" is the identity of the evaluation report
    # schema; changing this string is a report-schema transition that obliges a
    # changelog entry and refreshed report provenance, not a free rename.
    assert score["rag_triad_method"] == "deterministic-lexical-f11-1"
  end

  test "ranks evidence independently from answer citations" do
    question = %{evidence_refs: ["D1:1", "D2:4"]}

    score =
      Scorer.retrieval_score(
        question,
        [["D9:9"], ["D2:4"], ["D1:1"]],
        [1, 2, 10]
      )

    assert score["expected_evidence_refs"] |> Enum.sort() == ["D1:1", "D2:4"]
    assert score["first_supporting_rank"] == 2
    assert score["recall_at_k"] == %{"1" => 0.0, "2" => 0.5, "10" => 1.0}
    refute score["evidence_absent"]

    # A retrieved item can be ranked correctly even when generation cites nothing.
    assert Scorer.retrieval_score(question, [["D1:1"]], [10])["first_supporting_rank"] == 1

    summary = Scorer.summarize([score])
    assert summary["retrieval"]["mean_first_supporting_rank"] == 2.0
    assert summary["retrieval"]["recall_at_k"]["2"] == 0.5
  end

  test "summarizes content-free isolation checks independently from answer quality" do
    summary =
      Scorer.summarize([
        %{"isolation_candidates_checked" => 3, "isolation_leaks" => 0},
        %{"isolation_candidates_checked" => 2, "isolation_leaks" => 1}
      ])

    assert summary["isolation"] == %{
             "candidates_checked" => 5,
             "leaks" => 1,
             "passed" => false,
             "method" => "source-membership-v1"
           }
  end

  # Declining is the correct behaviour for an unanswerable question, so it has
  # to score as correct. Note the two independent routes to `abstained`: the
  # runner can set the flag explicitly, and a reply that reads as a
  # "not known" phrase is also treated as an abstention, which stops a system
  # from failing the check merely because it phrased its refusal in prose.
  test "scores expected abstention" do
    question = %{
      expected: ["No information available."],
      evidence_refs: [],
      abstention_expected: true
    }

    score =
      Scorer.score_question(
        question,
        %{"answer" => "not known", "abstained" => true},
        []
      )

    # Correct despite "not known" having almost no token overlap with the
    # expected string: the abstention expectation replaces the text check
    # rather than being combined with it.
    assert score["correct"]
    assert score["abstained"]
  end

  # The answering path reports its own certainty, and the report carries it so a
  # threshold can be tuned against measured calibration rather than guessed. A
  # replayed result from before the field existed reports nil, which keeps it
  # out of the mean instead of dragging it toward zero.
  test "reports answer confidence and averages only the answers that state one" do
    question = %{expected: ["weekly"], evidence_refs: [], abstention_expected: false}

    confident =
      Scorer.score_question(
        question,
        %{"answer" => "weekly", "abstained" => false, "answer_confidence" => 80},
        []
      )

    unstated = Scorer.score_question(question, %{"answer" => "weekly"}, [])

    out_of_range =
      Scorer.score_question(
        question,
        %{"answer" => "weekly", "answer_confidence" => 140},
        []
      )

    assert confident["answer_confidence"] == 80
    assert unstated["answer_confidence"] == nil
    assert out_of_range["answer_confidence"] == nil

    assert Scorer.summarize([confident, unstated])["overall"]["mean_answer_confidence"] == 80.0
    assert Scorer.summarize([unstated])["overall"]["mean_answer_confidence"] == nil
  end

  test "scores cited inconclusive prose by text when an answer is expected" do
    question = %{
      expected: ["concise weekly release summaries"],
      evidence_refs: ["D1:2"],
      evidence_granularity: "turn",
      abstention_expected: false
    }

    result = %{
      "answer" =>
        "The recorded statements do not establish this, but they support concise weekly release summaries.",
      "abstained" => true
    }

    score = Scorer.score_question(question, result, ["D1:2"])

    # The flag records inconclusiveness, but answerable cases continue to use
    # answer text for correctness. This lets a qualified, useful inference earn
    # credit without pretending the evidence established it.
    assert score["abstained"]
    assert score["correct"]
    assert score["contains_expected"]
    assert score["citation_hit"]
    assert score["citation_recall"] == 1.0
  end

  # Two identical questions answered at different context lengths: right at
  # 128K, wrong at 1M. That is exactly the shape the degradation curve exists
  # to expose, so the fixture is built to make the buckets differ.
  test "summarizes by category and BEAM scale" do
    results = [
      %{
        "benchmark" => "beam",
        "category" => "Temporal Reasoning",
        "scale" => "128K",
        "correct" => true,
        "contains_expected" => true,
        "token_f1" => 1.0,
        "citation_hit" => true,
        "citation_recall" => 1.0,
        "latency_ms" => 10
      },
      %{
        "benchmark" => "beam",
        "category" => "Temporal Reasoning",
        "scale" => "1M",
        "correct" => false,
        "contains_expected" => false,
        "token_f1" => 0.0,
        "citation_hit" => false,
        "citation_recall" => 0.0,
        "latency_ms" => 30
      }
    ]

    summary = Scorer.summarize(results)

    # One of two correct.
    assert summary["overall"]["accuracy"] == 0.5

    # Category grouping ignores scale, so both rows land in one bucket.
    assert summary["by_category"]["Temporal Reasoning"]["questions"] == 2

    # The degradation curve splits the same rows the other way, by context
    # length, and it counts only rows whose benchmark is "beam". An averaged
    # single figure would hide the collapse between these two buckets, which is
    # the one thing this curve exists to make visible.
    assert summary["beam_degradation_curve"]["128K"]["accuracy"] == 1.0
    assert summary["beam_degradation_curve"]["1M"]["accuracy"] == 0.0
  end
end
