# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Fusion do
  @moduledoc """
  Merges strategy candidate lists by rank and measures their pre-fusion disagreement.

  Strategy scores use incomparable scales, so fusion uses rank only. Each strategy contributes
  `weight / (k + rank)`; agreement accumulates naturally. Disagreement must be measured before
  fusion destroys the separate lists.
  """

  alias MemHouse.Retrieval.Candidate

  @doc """
  Fuses per-strategy candidate lists into one ranked list of at most `limit`
  candidates.

  `lists` is a list of `{strategy_name, candidates}` pairs; `weights` maps a
  strategy name to its multiplier, defaulting to 1.0 for anything unlisted.

  The fused score sums `weight / (k + rank)` for each strategy, using 1-based rank and the
  configured fusion constant.

  Returns at most `limit` fused candidates with dense 1-based ranks and contributing strategies.
  For duplicates, the highest local-score copy is retained deterministically.

  Raises `KeyError` if the fusion constant is missing from configuration.
  """
  def reciprocal_rank(lists, weights, limit) do
    k = retrieval_config(:rrf_k)

    lists
    |> Enum.flat_map(fn {_strategy, candidates} -> candidates end)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, candidates} ->
      # Local scores are intentionally excluded because their scales differ.
      score =
        Enum.reduce(candidates, 0.0, fn candidate, total ->
          weight = Map.get(weights, candidate.strategy, 1.0)
          total + weight / (k + candidate.rank)
        end)

      strategies = candidates |> Enum.map(& &1.strategy) |> Enum.uniq()

      # Pick one duplicate deterministically; fusion does not use its local score.
      %Candidate{} = representative = Enum.max_by(candidates, & &1.score)

      %Candidate{
        representative
        | score: score,
          rank: 0,
          strategy: :fusion,
          evidence: %{"strategies" => strategies}
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {candidate, rank} -> %{candidate | rank: rank} end)
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

  # This setting changes every profile's ranking.
  defp retrieval_config(key) do
    :memhouse
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end
end
