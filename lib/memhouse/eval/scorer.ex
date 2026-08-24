# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Scorer do
  @moduledoc """
  Computes deterministic per-case and aggregate evaluation metrics.

  Scoring uses normalized text and cited source ids without model calls. Metric definitions and
  rounding must remain stable because committed reports and thresholds depend on them.
  """

  # Fixed refusal phrases. Matched as substrings of the normalized answer, so a model that
  # says "I don't know which of them" still counts as an abstention. Keep this list closed
  # and literal: a looser rule would read hedging inside a real answer as a refusal.
  @not_known_markers [
    "not known",
    "unknown",
    "not enough information",
    "no information available",
    "i don't know",
    "cannot answer",
    "no memory statements were retrieved"
  ]

  @doc """
  Scores a single answer and returns every deterministic measure for it.

  Inputs are a normalized question, answer result, benchmark evidence labels, and optional
  full-context token count. Citation labels must already be translated from durable ids.

  Returns string-keyed correctness, citation, relevance, and token-efficiency metrics, plus
  the answer's reported `"answer_confidence"` or `nil` when it stated none. Missing fields
  lower scores through safe defaults; this function does not raise.
  """
  def score_question(question, result, cited_refs, opts \\ []) do
    expected = Map.get(question, :expected, [])
    answer = result |> Map.get("answer", "") |> to_string()
    candidates = Map.get(result, "candidates", [])
    abstention_expected? = Map.get(question, :abstention_expected, false)
    abstained? = Map.get(result, "abstained", false) == true or not_known?(answer)
    answer_confidence = answer_confidence(result)
    token_f1 = best_token_f1(answer, expected)
    contains_expected? = contains_expected?(answer, expected)
    exact_match? = exact_match?(answer, expected)
    evidence_refs = Map.get(question, :evidence_refs, [])
    citation = citation_score(evidence_refs, cited_refs)
    retrieval = Keyword.get(opts, :retrieval, retrieval_score(question, [], [10, 20, 50]))
    triad = rag_triad(Map.get(question, :question, ""), answer, candidates, abstained?)
    efficiency = token_efficiency(answer, candidates, Keyword.get(opts, :full_context_tokens, 0))

    correct? =
      if abstention_expected? do
        abstained?
      else
        exact_match? or contains_expected? or token_f1 >= 0.5
      end

    %{
      "exact_match" => exact_match?,
      "contains_expected" => contains_expected?,
      "token_f1" => token_f1,
      "abstention_expected" => abstention_expected?,
      "abstained" => abstained?,
      "answer_confidence" => answer_confidence,
      "correct" => correct?,
      "citation_hit" => citation.hit?,
      "citation_recall" => citation.recall,
      "groundedness" => triad.groundedness,
      "context_relevance" => triad.context_relevance,
      "answer_relevance" => triad.answer_relevance,
      "rag_triad_method" => "deterministic-lexical-f11-1",
      "context_tokens" => efficiency.context_tokens,
      "answer_tokens" => efficiency.answer_tokens,
      "end_to_end_tokens" => efficiency.end_to_end_tokens,
      "full_context_tokens" => efficiency.full_context_tokens,
      "token_efficiency_ratio" => efficiency.ratio,
      "expected_refs" => evidence_refs,
      "cited_refs" => cited_refs
    }
    |> Map.merge(retrieval)
  end

  @doc """
  Computes deterministic retrieval rank metrics from the ordered candidate evidence.

  `ranked_refs` contains one list of benchmark evidence references per retrieved candidate,
  in retrieval order. This deliberately does not inspect the answer, citations, or judge
  output: generation failure therefore cannot become a retrieval failure. `cutoffs` are the
  configured positive rank cutoffs and are recorded as string-keyed `recall_at_k` values.
  """
  def retrieval_score(question, ranked_refs, cutoffs \\ [10, 20, 50]) do
    expected_refs = question |> Map.get(:evidence_refs, []) |> Enum.uniq()
    expected = MapSet.new(expected_refs)
    ranked_refs = normalize_ranked_refs(ranked_refs)
    cutoffs = cutoffs |> Enum.filter(&(is_integer(&1) and &1 > 0)) |> Enum.uniq() |> Enum.sort()

    %{
      "expected_evidence_refs" => expected_refs,
      "first_supporting_rank" => first_supporting_rank(expected, ranked_refs),
      "recall_at_k" => Map.new(cutoffs, &{to_string(&1), recall_at(expected, ranked_refs, &1)}),
      "evidence_absent" => first_supporting_rank(expected, ranked_refs) == nil,
      "retrieval_metric_method" => "deterministic-rank-f11-2"
    }
  end

  @doc """
  Rolls a flat list of scored questions up into the report's metric block.

  `question_results` are the maps returned by `score_question/4` after the runner has
  merged in the run-level fields it groups on: `"category"`, `"scale"`, `"benchmark"`, and
  `"latency_ms"`.

  Returns `"overall"`, `"retrieval"`, `"isolation"`, `"by_category"`, `"by_scale"`, and
  `"beam_degradation_curve"`. The isolation block contains counts, a pass flag, and its
  method identity; the last block is the by-scale rollup restricted to BEAM cases, which is
  how accuracy loss with growing corpus size is read. Questions with a missing or blank group
  key are collected under `"uncategorized"` rather than dropped, so group counts sum to the
  total.

  Within a group, `"abstention_accuracy"` is `nil` when no question there expected a
  refusal. That distinguishes "there was nothing to abstain from" from "every abstention
  was wrong", which a 0.0 would not. The three `"mean_model_*"` means and
  `"mean_answer_confidence"` are `nil` when no question in the group carries the underlying
  score, and are absent altogether from an empty group.
  `"latency_ms"` is a map of mean, median, 95th percentile, and maximum; the
  remaining aggregates are numbers. An empty input still produces zeroes rather than an
  empty map.
  """
  def summarize(question_results) do
    %{
      "overall" => aggregate(question_results),
      "retrieval" => retrieval_aggregate(question_results),
      "isolation" => isolation_aggregate(question_results),
      "by_category" => group_aggregate(question_results, "category"),
      "by_scale" => group_aggregate(question_results, "scale"),
      "beam_degradation_curve" => beam_degradation_curve(question_results)
    }
  end

  # The runner checks candidate source ids against the source ids ingested for that case.
  # Only counts reach the report: an unexpected id may belong to another scope or Account and
  # must not become a second leak through evaluation evidence.
  defp isolation_aggregate(results) do
    candidates = Enum.sum(Enum.map(results, &Map.get(&1, "isolation_candidates_checked", 0)))
    leaks = Enum.sum(Enum.map(results, &Map.get(&1, "isolation_leaks", 0)))

    %{
      "candidates_checked" => candidates,
      "leaks" => leaks,
      "passed" => candidates > 0 and leaks == 0,
      "method" => "source-membership-v2"
    }
  end

  # Retrieval evidence is its own block. Answer correctness, generation failures, and judge
  # outcomes never enter these calculations, so the report can say where evidence ranked even
  # when no usable answer was produced.
  defp retrieval_aggregate(results) do
    %{
      "mean_first_supporting_rank" => mean(results, &Map.get(&1, "first_supporting_rank")),
      "recall_at_k" =>
        results
        |> Enum.flat_map(&(Map.get(&1, "recall_at_k", %{}) |> Map.keys()))
        |> Enum.uniq()
        |> Map.new(fn cutoff ->
          {cutoff, mean(results, &get_in(&1, ["recall_at_k", cutoff]))}
        end),
      "evidence_absent_rate" =>
        if(results == [], do: 0.0, else: ratio(results, &Map.get(&1, "evidence_absent", false))),
      "method" => "deterministic-rank-f11-2"
    }
  end

  defp group_aggregate(results, key) do
    results
    |> Enum.group_by(fn result -> result |> Map.get(key) |> blank_to("uncategorized") end)
    |> Map.new(fn {group, group_results} -> {group, aggregate(group_results)} end)
  end

  # Only BEAM fixtures label a comparable corpus size, so the degradation curve is filtered
  # to them; mixing other benchmarks' scale labels in would group unrelated runs together.
  defp beam_degradation_curve(results) do
    results
    |> Enum.filter(&(Map.get(&1, "benchmark") == "beam"))
    |> group_aggregate("scale")
  end

  # Zeroed shape for an empty group, so a report always has the same numeric keys to read.
  # The optional model-judge means are absent here rather than nil: with no results there
  # is nothing to say about whether a model judge ran.
  defp aggregate([]) do
    %{
      "questions" => 0,
      "accuracy" => 0.0,
      "mean_token_f1" => 0.0,
      "contains_rate" => 0.0,
      "abstention_accuracy" => nil,
      "citation_hit_rate" => 0.0,
      "mean_citation_recall" => 0.0,
      "mean_groundedness" => 0.0,
      "mean_context_relevance" => 0.0,
      "mean_answer_relevance" => 0.0,
      "mean_end_to_end_tokens" => 0.0,
      "mean_full_context_tokens" => 0.0,
      "mean_token_efficiency_ratio" => 0.0,
      "latency_ms" => latency_summary([])
    }
  end

  defp aggregate(results) do
    abstention_results = Enum.filter(results, &Map.get(&1, "abstention_expected"))

    %{
      "questions" => length(results),
      "accuracy" => ratio(results, &Map.get(&1, "correct")),
      "mean_token_f1" => mean(results, &Map.get(&1, "token_f1")),
      "contains_rate" => ratio(results, &Map.get(&1, "contains_expected")),
      "abstention_accuracy" =>
        if(abstention_results == [],
          do: nil,
          else: ratio(abstention_results, &Map.get(&1, "correct"))
        ),
      "citation_hit_rate" => ratio(results, &Map.get(&1, "citation_hit")),
      "mean_citation_recall" => mean(results, &Map.get(&1, "citation_recall")),
      "mean_groundedness" => mean(results, &Map.get(&1, "groundedness")),
      "mean_context_relevance" => mean(results, &Map.get(&1, "context_relevance")),
      "mean_answer_relevance" => mean(results, &Map.get(&1, "answer_relevance")),
      "mean_end_to_end_tokens" => mean(results, &Map.get(&1, "end_to_end_tokens")),
      "mean_full_context_tokens" => mean(results, &Map.get(&1, "full_context_tokens")),
      "mean_token_efficiency_ratio" => mean(results, &Map.get(&1, "token_efficiency_ratio")),
      "mean_answer_confidence" => optional_mean(results, "answer_confidence"),
      "mean_model_groundedness" => optional_mean(results, "model_groundedness"),
      "mean_model_context_relevance" => optional_mean(results, "model_context_relevance"),
      "mean_model_answer_relevance" => optional_mean(results, "model_answer_relevance"),
      "latency_ms" => results |> Enum.map(&Map.get(&1, "latency_ms", 0)) |> latency_summary()
    }
  end

  # Abstained answers get fixed values instead of a lexical comparison: a refusal asserts
  # nothing, so it cannot be ungrounded, and it is a valid response to its question, but it
  # used no retrieved context. Running the overlap formulas on a refusal would instead
  # penalise the run for correctly declining to answer.
  defp rag_triad(_question, _answer, _candidates, true) do
    %{groundedness: 1.0, context_relevance: 0.0, answer_relevance: 1.0}
  end

  # Token-overlap approximation of the three relevance checks a model judge would perform.
  # Candidates expose their text under either key depending on whether the candidate is a
  # knowledge statement or a document chunk.
  defp rag_triad(question, answer, candidates, false) do
    context =
      candidates
      |> Enum.map_join(" ", fn candidate ->
        Map.get(candidate, "statement") || Map.get(candidate, "content") || ""
      end)

    %{
      groundedness: lexical_f1(answer, context),
      context_relevance: lexical_f1(question, context),
      answer_relevance: lexical_f1(question, answer)
    }
  end

  # What retrieval-backed answering cost, against what stuffing the whole conversation into
  # a prompt would have cost. A ratio well below 1.0 is the point of the memory system; a
  # ratio of 0.0 means the caller gave no full-context size, not perfect efficiency.
  defp token_efficiency(answer, candidates, full_context_tokens) do
    context_tokens =
      candidates
      |> Enum.map(fn candidate ->
        candidate
        |> then(&(Map.get(&1, "statement") || Map.get(&1, "content") || ""))
        |> token_count()
      end)
      |> Enum.sum()

    answer_tokens = token_count(answer)
    end_to_end_tokens = context_tokens + answer_tokens

    %{
      context_tokens: context_tokens,
      answer_tokens: answer_tokens,
      end_to_end_tokens: end_to_end_tokens,
      full_context_tokens: full_context_tokens,
      ratio:
        if(full_context_tokens > 0,
          do: end_to_end_tokens / full_context_tokens,
          else: 0.0
        )
    }
  end

  defp lexical_f1(left, right), do: token_f1(token_counts(left), token_counts(right))

  defp token_count(value) do
    value
    |> token_counts()
    |> Map.values()
    |> Enum.sum()
  end

  # A question with no labelled evidence cannot earn citation credit, on purpose: crediting
  # it would let an unlabelled fixture inflate the citation rate a release threshold reads.
  defp citation_score([], _cited_refs), do: %{hit?: false, recall: 0.0}

  defp citation_score(evidence_refs, cited_refs) do
    expected = MapSet.new(evidence_refs)
    cited = MapSet.new(cited_refs)
    overlap = expected |> MapSet.intersection(cited) |> MapSet.size()

    %{hit?: overlap > 0, recall: overlap / max(MapSet.size(expected), 1)}
  end

  defp normalize_ranked_refs(refs) do
    Enum.map(refs, fn
      refs when is_list(refs) -> refs
      ref -> [ref]
    end)
  end

  defp first_supporting_rank(expected, ranked_refs) do
    if MapSet.size(expected) == 0 do
      nil
    else
      ranked_refs
      |> Enum.find_index(fn refs ->
        not MapSet.disjoint?(expected, MapSet.new(refs))
      end)
      |> case do
        nil -> nil
        index -> index + 1
      end
    end
  end

  defp recall_at(expected, ranked_refs, cutoff) do
    if MapSet.size(expected) == 0 do
      0.0
    else
      found =
        ranked_refs
        |> Enum.take(cutoff)
        |> List.flatten()
        |> MapSet.new()
        |> MapSet.intersection(expected)
        |> MapSet.size()

      found / MapSet.size(expected)
    end
  end

  defp exact_match?(_answer, []), do: false

  defp exact_match?(answer, expected) do
    normalized_answer = normalize_text(answer)
    Enum.any?(expected, &(normalize_text(&1) == normalized_answer))
  end

  defp contains_expected?(_answer, []), do: false

  defp contains_expected?(answer, expected) do
    normalized_answer = normalize_text(answer)

    Enum.any?(expected, fn expected ->
      normalized_expected = normalize_text(expected)
      normalized_expected != "" and String.contains?(normalized_answer, normalized_expected)
    end)
  end

  # Fixtures list several acceptable phrasings of one gold answer, so the score is the best
  # match across them, not an average: matching any accepted variant is a correct answer.
  defp best_token_f1(_answer, []), do: 0.0

  defp best_token_f1(answer, expected) do
    answer_tokens = token_counts(answer)

    expected
    |> Enum.map(fn expected -> token_f1(answer_tokens, token_counts(expected)) end)
    |> Enum.max(fn -> 0.0 end)
  end

  # Token-multiset F1: overlap counts each token at most as often as both sides contain it,
  # so repeating a gold word cannot inflate the score.
  defp token_f1(_answer_tokens, expected_tokens) when map_size(expected_tokens) == 0, do: 0.0
  defp token_f1(answer_tokens, _expected_tokens) when map_size(answer_tokens) == 0, do: 0.0

  defp token_f1(answer_tokens, expected_tokens) do
    overlap =
      expected_tokens
      |> Enum.reduce(0, fn {token, expected_count}, count ->
        count + min(expected_count, Map.get(answer_tokens, token, 0))
      end)

    if overlap == 0 do
      0.0
    else
      precision = overlap / Enum.sum(Map.values(answer_tokens))
      recall = overlap / Enum.sum(Map.values(expected_tokens))
      2 * precision * recall / (precision + recall)
    end
  end

  defp token_counts(value) do
    value
    |> normalize_text()
    |> String.split(" ", trim: true)
    |> Enum.frequencies()
  end

  # The single normalization every comparison in this module goes through. Changing it
  # changes every historical score, so it is versioned along with the scoring method
  # identity rather than tuned in place.
  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^[:alnum:]\s]+/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # A 0-100 integer the answering model stated about itself. Anything else, including a
  # replayed result from before the field existed, scores as nil rather than zero: no
  # probability was reported, which is not the same as a probability of none.
  defp answer_confidence(result) do
    case Map.get(result, "answer_confidence") do
      value when is_integer(value) and value >= 0 and value <= 100 -> value
      _value -> nil
    end
  end

  defp not_known?(answer) do
    normalized = normalize_text(answer)
    Enum.any?(@not_known_markers, &String.contains?(normalized, normalize_text(&1)))
  end

  defp ratio(values, fun) do
    values
    |> Enum.count(fun)
    |> Kernel./(length(values))
  end

  # Missing values are excluded from the average rather than counted as zero, so a metric
  # that only some questions carry is not diluted by the ones that do not.
  defp mean(values, fun) do
    values
    |> Enum.map(fun)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0.0
      numbers -> Enum.sum(numbers) / length(numbers)
    end
  end

  # Returns nil when no result carries the key at all, which distinguishes "the model judge
  # did not run" from "the model judge scored zero".
  defp optional_mean(values, key) do
    case Enum.filter(values, &is_number(Map.get(&1, key))) do
      [] -> nil
      scored -> mean(scored, &Map.get(&1, key))
    end
  end

  defp latency_summary([]), do: %{"mean" => 0.0, "p50" => 0, "p95" => 0, "max" => 0}

  defp latency_summary(latencies) do
    sorted = Enum.sort(latencies)

    %{
      "mean" => Enum.sum(sorted) / length(sorted),
      "p50" => percentile(sorted, 0.50),
      "p95" => percentile(sorted, 0.95),
      "max" => List.last(sorted)
    }
  end

  # Nearest-rank percentile: take the ceiling of q times the sample count and read that
  # position, so the result is always a latency that was actually measured. Interpolating
  # would invent values, which is misleading on the small runs this harness usually does.
  defp percentile(sorted, q) do
    index =
      sorted
      |> length()
      |> Kernel.*(q)
      |> Float.ceil()
      |> trunc()
      |> Kernel.-(1)
      |> max(0)

    Enum.at(sorted, index)
  end

  defp blank_to(nil, default), do: default
  defp blank_to("", default), do: default
  defp blank_to(value, _default), do: value
end
