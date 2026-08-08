# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Console.Diagnostic do
  @moduledoc """
  Presentation rules for the tool workbench's retrieval diagnostic mode.

  Authorization is not here: `MemHouse.Memory.diagnostic_search/2` decides who
  may run a diagnostic, and `MemHouseWeb.Console.Access` decides who is shown
  the controls. This module only turns an already-authorized result into what
  the page renders, so nothing it returns may widen what a run disclosed.

  Query-term highlighting returns plain segments rather than markup, so the
  template escapes every fragment of statement text on the ordinary path and
  there is no raw HTML to get wrong.
  """

  alias MemHouse.Retrieval.DiagnosticGrant
  alias MemHouse.Retrieval.Profile

  # A term shorter than this matches inside too many unrelated words to be a
  # reading aid, and highlighting every "a" makes a statement harder to read
  # rather than easier.
  @min_term_length 2

  @doc """
  Every registered strategy name with whether it reads the query text.

  The page uses the flag to explain what isolating a strategy will do, since a
  run whose surviving strategies all ignore the query ranks the scope instead.
  """
  def strategy_options do
    Profile.strategy_names()
    |> Enum.map(&{Atom.to_string(&1), Profile.module(&1).query_dependent?()})
    |> Enum.sort_by(fn {name, _dependent?} -> name end)
  end

  @doc "Largest limit the diagnostic form may request."
  def limit_cap, do: DiagnosticGrant.max_limit()

  @doc """
  The reproducible request for one diagnostic run, as pretty JSON.

  Built from an allowlist rather than by removing fields, so a key added to the
  form later cannot leak into an export by omission. The session id is excluded
  along with every credential: the run is reproducible from the scope, query,
  profile, and diagnostic options alone.
  """
  def request_json(scope_path, query, profile, diagnostic) when is_map(diagnostic) do
    Jason.encode!(
      %{
        "tool" => "search",
        "mode" => "diagnostic",
        "scope_path" => scope_path,
        "query" => query,
        "profile" => profile,
        "limit" => diagnostic["limit"],
        "strategies" => diagnostic["strategies"],
        "deadline" => diagnostic["deadline"],
        "rerank" => diagnostic["rerank"]
      },
      pretty: true
    )
  end

  @doc """
  Keeps only candidates a query-dependent strategy voted for.

  With no query-dependent strategy contributing, every candidate ranked the
  scope rather than the question, and the honest answer is an empty list rather
  than the same rows relabelled.
  """
  def query_dependent_only(candidates, diagnostic) when is_list(candidates) do
    dependent = MapSet.new(Map.get(diagnostic, "query_dependent_strategies", []))

    Enum.filter(candidates, fn candidate ->
      candidate
      |> Map.get("strategies", [])
      |> Enum.any?(&MapSet.member?(dependent, &1))
    end)
  end

  @doc """
  Splits `text` into `{:match, part}` and `{:plain, part}` segments around the
  words of `query`.

  Matching is case-insensitive and substring-based, so "standup" highlights
  inside "standups". An empty query, or one carrying no term long enough to be
  useful, returns the text as a single plain segment.
  """
  def segments(text, query) when is_binary(text) do
    case terms(query) do
      [] -> [{:plain, text}]
      terms -> split(text, term_regex(terms))
    end
  end

  def segments(text, _query), do: [{:plain, to_string(text)}]

  @doc """
  How the ordinary result window should be described, or `nil` when it needs no
  note.

  A run that returned exactly as many candidates as it asked for stopped at the
  limit rather than at the end of the matches, so deeper candidates may exist.
  This says only that, and never that anything deeper would be better.
  """
  def window_note(candidate_count, limit)
      when is_integer(candidate_count) and is_integer(limit) and candidate_count >= limit,
      do:
        "The window was full at #{limit} results, so deeper candidates may exist. " <>
          "Raise the limit or open diagnostic mode to look past it."

  def window_note(_candidate_count, _limit), do: nil

  defp terms(query) when is_binary(query) do
    query
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= @min_term_length))
    |> Enum.uniq_by(&String.downcase/1)
    # Longest first so an overlapping shorter term cannot claim the prefix of a
    # longer one and split a single highlight in two.
    |> Enum.sort_by(&String.length/1, :desc)
  end

  defp terms(_query), do: []

  defp term_regex(terms) do
    Regex.compile!("(?:" <> Enum.map_join(terms, "|", &Regex.escape/1) <> ")", "iu")
  end

  # Byte offsets from `Regex.scan/3` always land on codepoint boundaries for a
  # match, so `binary_part/3` cannot split a multi-byte character here.
  defp split(text, regex) do
    {segments, cursor} =
      regex
      |> Regex.scan(text, return: :index)
      |> Enum.reduce({[], 0}, fn [{start, length} | _captures], {segments, cursor} ->
        leading =
          if start > cursor,
            do: [{:plain, binary_part(text, cursor, start - cursor)}],
            else: []

        {[{:match, binary_part(text, start, length)} | leading] ++ segments, start + length}
      end)

    trailing =
      if cursor < byte_size(text),
        do: [{:plain, binary_part(text, cursor, byte_size(text) - cursor)}],
        else: []

    Enum.reverse(trailing ++ segments)
  end
end
