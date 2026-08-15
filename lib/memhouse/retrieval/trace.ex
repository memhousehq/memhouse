# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Trace do
  @moduledoc """
  Builds an ephemeral, authorized explanation of one retrieval ranking.

  The trace contains only ids already present in the caller's result and the
  strategy-local values that ordered them. It is for the administrator console,
  never persistence, telemetry, audit data, or jobs. Local scores are shown
  beside their strategy and must not be compared across strategies.
  """

  alias MemHouse.Retrieval.Candidate

  @doc """
  Returns rank and contribution details for the candidates that reached the final result.

  `lists` are the authorized strategy outputs, `fused` is their pre-rerank
  ordering, and `ranked` is the final ordering. Candidates outside the rerank
  head and candidates whose rerank could not complete are labelled separately.
  """
  def build(lists, fused, ranked, weights, rrf_k, rerank_head, rerank_outcome) do
    local_candidates =
      lists
      |> Enum.flat_map(fn {_strategy, candidates} -> candidates end)
      |> Enum.group_by(& &1.id)

    fused_ranks = Map.new(fused, &{&1.id, &1.rank})
    contributions = MemHouse.Retrieval.Fusion.contributions(lists, weights, rrf_k)
    rerank_status = rerank_status(rerank_outcome)

    %{
      "candidates" =>
        Enum.map(ranked, fn candidate ->
          local = Map.get(local_candidates, candidate.id, [])
          fused_rank = Map.fetch!(fused_ranks, candidate.id)

          %{
            "id" => candidate.id,
            "fused_rank" => fused_rank,
            "final_rank" => candidate.rank,
            "fusion_score" => candidate.score,
            "rrf_score" => candidate.score,
            "rerank_status" => candidate_rerank_status(fused_rank, rerank_head, rerank_status),
            "strategies" => strategy_rows(local, contributions)
          }
        end)
    }
  end

  defp strategy_rows(candidates, contributions) do
    candidates
    |> Enum.sort_by(&Atom.to_string(&1.strategy))
    |> Enum.map(fn %Candidate{} = candidate ->
      %{
        "strategy" => Atom.to_string(candidate.strategy),
        "local_rank" => candidate.rank,
        "local_score" => candidate.score,
        "fusion_contribution" => Map.fetch!(contributions, {candidate.id, candidate.strategy})
      }
    end)
  end

  defp rerank_status(nil), do: :not_configured
  defp rerank_status(%{status: "completed"}), do: :completed
  defp rerank_status(%{status: "dropped"}), do: :unavailable

  defp candidate_rerank_status(_rank, _head, :not_configured), do: "not_configured"
  defp candidate_rerank_status(rank, head, _status) when rank > head, do: "outside_rerank_head"
  defp candidate_rerank_status(_rank, _head, :completed), do: "reranked"
  defp candidate_rerank_status(_rank, _head, :unavailable), do: "rerank_unavailable"
end
