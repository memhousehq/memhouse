# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.LexicalQueryAnalyzerTest do
  @moduledoc """
  Tests the deterministic lexical-query representation before it reaches PostgreSQL.

  Query analysis keeps user terms and reviewed boilerplate rules. It must not add
  vocabulary fitted to an evaluation split.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Retrieval.LexicalQueryAnalyzer

  test "does not expand a query with benchmark-fitted vocabulary" do
    analysis = LexicalQueryAnalyzer.analyze("What does Melanie do to destress?")

    assert analysis.matching_text == "Melanie destress"
    assert analysis.version == "lexical-question-v3"
    assert analysis.proximity_text == "Melanie <-> destress"

    terms = String.split(analysis.matching_text)
    refute "stress" in terms
    refute "relax" in terms
    refute "calming" in terms
    refute "therapeutic" in terms
  end
end
