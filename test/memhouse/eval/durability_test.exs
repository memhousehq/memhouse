# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.DurabilityTest do
  @moduledoc """
  Pins the content-safe, deterministic part of durability audit accounting.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Eval.Durability

  test "classifies structural residue and reports no statement content" do
    audit =
      Durability.audit(
        [
          [
            %{"id" => "a", "statement" => "Avery prefers weekly release summaries."},
            %{"id" => "b", "statement" => "What does Avery prefer?"}
          ],
          [
            %{"id" => "c", "statement" => "Avery said that summaries are useful."}
          ],
          []
        ],
        judge: "deterministic",
        seed: "test-seed"
      )

    assert audit["available"] == 3
    assert audit["sampled"] == 3
    assert audit["durable"] == 1
    assert audit["noise"] == 2
    assert audit["categories"]["question"] == 1
    assert audit["categories"]["speech_act_transcription"] == 1
    assert audit["messages"] == %{"zero" => 1, "one" => 1, "multiple" => 1}
    refute inspect(audit) =~ "Avery prefers"
  end

  test "selects the same bounded sample for the same seed" do
    extractions =
      [
        Enum.map(1..6, fn id ->
          %{"id" => Integer.to_string(id), "statement" => "Avery prefers weekly summaries."}
        end)
      ]

    first = Durability.audit(extractions, sample: 3, seed: "fixed")
    second = Durability.audit(Enum.reverse(extractions), sample: 3, seed: "fixed")

    assert first == second
    assert first["sampled"] == 3
  end
end
