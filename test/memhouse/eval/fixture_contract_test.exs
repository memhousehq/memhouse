# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.FixtureContractTest do
  @moduledoc """
  Freezes evaluation source bytes and normalized shape for comparable results.

  Digest failures mean fixture bytes changed; summary failures mean ids,
  formats, or case boundaries changed. Either requires a deliberate re-baseline
  and changelog entry. `poc-0` is the frozen behavior contract identity, not the
  application version. This evidence file must keep its name.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Eval.Adapter

  # Data, not prose: the test reads this JSON file and compares against it.
  @baseline_path "test/fixtures/eval/poc-contract-baseline.json"

  test "poc-0 eval fixtures match the committed source and normalization baseline" do
    baseline = @baseline_path |> File.read!() |> Jason.decode!()

    assert baseline["contract_version"] == "poc-0"

    Enum.each(baseline["fixtures"], fn expected ->
      path = expected["path"]
      dataset = Adapter.load!(path, benchmark: expected["benchmark"])

      # Confirm source bytes before comparing their normalized shape.
      assert sha256(path) == expected["sha256"]
      assert summarize(dataset) == expected["normalized"]
    end)
  end

  # The baseline stores raw-byte SHA-256 as lowercase hex.
  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Deliberately records identities and never content. Ids and the detected
  # source format are exactly the parts other components depend on — evidence
  # matching cites message ids, and reports key results by case and question id
  # — while the conversation text is already covered by the digest above.
  # Keeping content out also stops the baseline file from becoming a second,
  # divergent copy of every fixture.
  defp summarize(dataset) do
    %{
      "benchmark" => dataset.benchmark,
      "source_format" => dataset.source_format,
      "case_ids" => Enum.map(dataset.cases, & &1.id),
      "message_ids" =>
        Enum.flat_map(dataset.cases, &Enum.map(&1.messages, fn item -> item.id end)),
      "question_ids" =>
        Enum.flat_map(dataset.cases, &Enum.map(&1.questions, fn item -> item.id end))
    }
  end
end
