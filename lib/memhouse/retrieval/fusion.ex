# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Fusion do
  @moduledoc """
  Merges strategy candidate lists by normalized score and rank, and measures disagreement.

  Each strategy's returned score range is normalized independently. Fusion combines that
  comparable value with a small reciprocal-rank tie-break. Agreement accumulates naturally.
  Disagreement must be measured before fusion destroys the separate lists.
  """

  alias MemHouse.Retrieval.Candidate

  @doc """
  Fuses per-strategy candidate lists into one ranked list of at most `limit`
  candidates.

  `lists` is a list of `{strategy_name, candidates}` pairs; `weights` maps a
  strategy name to its multiplier, defaulting to 1.0 for anything unlisted.

  The fused score is the weighted mean of each strategy's contribution. A contribution is 95%
  normalized local score and 5% normalized reciprocal rank, using 1-based rank and `k`.

  Returns at most `limit` fused candidates with dense 1-based ranks and contributing strategies.
  For duplicates, the highest local-score copy is retained deterministically.

  `k` must be positive.
  """
  def score_aware([], _weights, _k, _limit), do: []

  def score_aware(lists, weights, k, limit) when is_number(k) and k > 0 do
    weighted_lists = normalized_lists(lists, weights, k)
    total_weight = total_weight!(lists, weights)

    weighted_lists
    |> Enum.flat_map(fn {_strategy, candidates} -> candidates end)
    |> Enum.group_by(fn {candidate, _contribution} -> candidate.id end)
    |> Enum.map(fn {_id, rows} ->
      candidates = Enum.map(rows, &elem(&1, 0))
      score = Enum.sum(for {_candidate, contribution} <- rows, do: contribution) / total_weight

      strategies = candidates |> Enum.map(& &1.strategy) |> Enum.uniq()

      %Candidate{} =
        representative =
        Enum.max_by(candidates, &{&1.score, Atom.to_string(&1.strategy)})

      %Candidate{
        representative
        | score: score,
          rank: 0,
          strategy: :fusion,
          evidence: %{"strategies" => strategies}
      }
    end)
    |> Enum.sort_by(&{-&1.score, &1.id})
    |> Enum.take(limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {candidate, rank} -> %{candidate | rank: rank} end)
  end

  @doc "Returns each candidate's score-aware contribution for diagnostic output."
  def contributions([], _weights, _k), do: %{}

  def contributions(lists, weights, k) when is_number(k) and k > 0 do
    total_weight = total_weight!(lists, weights)

    for {strategy, candidates} <- normalized_lists(lists, weights, k),
        {candidate, contribution} <- candidates,
        into: %{} do
      {{candidate.id, strategy}, contribution / total_weight}
    end
  end

  @doc """
  Summarises how much the strategies disagreed, from their pre-fusion lists.

  Accepts the original strategy lists; a fused list has already lost this
  information. `query_dependent` names the strategies of this request's profile
  that read the query text.

  Returns a map with:

  * `"strategy_count"` — how many strategies returned anything at all.
  * `"disjoint"` — true when non-empty strategies share no candidate.
  * `"low_score"` — true when every strategy's best local score is below 0.2. This is a
    per-strategy hint, not a cross-strategy comparison or filter.
  * `"query_dependent_empty"` — true when no strategy that reads the query text
    produced a candidate, so what survives ranked the scope rather than the
    question. Also true, vacuously, when the profile runs no such strategy at
    all: in both cases the result is query-independent.

  With no non-empty lists, `"disjoint"` is false and `"low_score"` is true,
  because a vacuous `Enum.all?/2` holds.

  The first three measure the strategies that returned something and therefore
  cannot see one that returned nothing; `"query_dependent_empty"` is the only
  member that can express that absence.
  """
  def disagreement(lists, query_dependent) do
    non_empty =
      for {strategy, candidates} <- lists, candidates != [] do
        {strategy, MapSet.new(candidates, & &1.id), Enum.max_by(candidates, & &1.score).score}
      end

    # Visit each unordered strategy pair once.
    overlaps =
      for {left, left_ids, _} <- non_empty,
          {right, right_ids, _} <- non_empty,
          left < right do
        MapSet.intersection(left_ids, right_ids) |> MapSet.size()
      end

    contributing = MapSet.new(non_empty, fn {strategy, _ids, _score} -> strategy end)

    %{
      "strategy_count" => length(non_empty),
      "disjoint" => non_empty != [] and Enum.all?(overlaps, &(&1 == 0)),
      # 0.2 is a fixed per-strategy hint, never a filter.
      "low_score" => Enum.all?(non_empty, fn {_strategy, _ids, score} -> score < 0.2 end),
      "query_dependent_empty" => not Enum.any?(query_dependent, &MapSet.member?(contributing, &1))
    }
  end

  defp normalized_lists(lists, weights, k) do
    Enum.map(lists, fn {strategy, candidates} ->
      scores = Enum.map(candidates, & &1.score)
      {minimum, maximum} = score_range(scores)

      normalized =
        Enum.map(candidates, fn candidate ->
          local_score = normalize(candidate.score, minimum, maximum)
          rank_score = (k + 1) / (k + candidate.rank)
          contribution = weight(weights, strategy) * (0.95 * local_score + 0.05 * rank_score)
          {candidate, contribution}
        end)

      {strategy, normalized}
    end)
  end

  defp score_range([]), do: {0.0, 0.0}
  defp score_range(scores), do: Enum.min_max(scores)

  # A singleton or tied list has no observed tail. Keep it fully relevant and let rank break ties.
  defp normalize(_score, minimum, maximum) when minimum == maximum, do: 1.0
  defp normalize(score, minimum, maximum), do: (score - minimum) / (maximum - minimum)

  defp weight(weights, strategy), do: Map.get(weights, strategy, 1.0) * 1.0

  defp total_weight!(lists, weights) do
    total = Enum.sum(for {strategy, _candidates} <- lists, do: weight(weights, strategy))

    if total > 0 do
      total
    else
      raise ArgumentError, "fusion requires a positive total strategy weight"
    end
  end
end
