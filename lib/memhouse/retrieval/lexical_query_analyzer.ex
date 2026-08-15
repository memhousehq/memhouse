# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.LexicalQueryAnalyzer do
  @moduledoc """
  Produces the bounded, deterministic query representation used by lexical retrieval.

  Plain English questions lose only reviewed interrogative boilerplate. Names, dates, and
  ordinary content terms remain. Explicit websearch operators bypass normalization so quoted
  phrases and negation keep PostgreSQL's documented semantics.
  """

  @version "lexical-question-v3"
  @websearch_operators ~r/"|(?:^|\s)-\S|(?:^|\s)or(?:\s|$)/i
  @boilerplate MapSet.new(
                 ~w(a an are could did do does for from how is me tell that the to was what when where which who why would you your)
               )

  # Each retained adjacent pair adds one ordered phrase clause. This keeps construction linear
  # in the term count and avoids the old distance-and-direction fan-out on every shortlisted row.
  @proximity_terms 4

  @doc "The version recorded with content-free retrieval diagnostics."
  def version, do: @version

  @doc """
  Analyzes one lexical query without calling a model or constructing SQL.

  `matching_text` is an OR-style term set. `proximity_text` is a bounded `tsquery` expression for
  adjacent retained-term phrases, or `nil` when the query has no proximity representation.
  Websearch queries always return `nil`: the caller asked for an exact parse.
  """
  def analyze(text) when is_binary(text) do
    if Regex.match?(@websearch_operators, text) do
      %{version: @version, mode: :websearch, matching_text: text, proximity_text: nil}
    else
      terms =
        text
        |> tokens()
        |> Enum.reject(&(String.downcase(&1) in @boilerplate))

      %{
        version: @version,
        mode: :normalized,
        matching_text: terms |> Enum.uniq_by(&String.downcase/1) |> Enum.join(" "),
        proximity_text: terms |> Enum.take(@proximity_terms) |> proximity_text()
      }
    end
  end

  def analyze(_text), do: analyze("")

  @doc "Returns whether one token is reviewed English query boilerplate."
  def boilerplate?(token) when is_binary(token),
    do: MapSet.member?(@boilerplate, String.downcase(token))

  def boilerplate?(_token), do: false

  defp tokens(text), do: Regex.scan(~r/[\p{L}\p{N}][\p{L}\p{N}'-]*/u, text) |> List.flatten()

  # Terms are interpolated as `tsquery` text, never as SQL. `tokens/1` admits only letters,
  # digits, `'`, and `-`, none of which open a quoted lexeme or an operator once a token starts
  # with a letter or digit, so `to_tsquery` reads every term as a word.
  defp proximity_text(terms) when length(terms) < 2, do: nil

  defp proximity_text(terms) do
    terms
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map_join(" | ", fn [left, right] -> "#{left} <-> #{right}" end)
  end
end
