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
  @issue_279_path "test/fixtures/eval/issue-279-acquisition-events.json"

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

  test "issue 279 live fixture stays unevaluated and pins repeated paired batches" do
    fixture = @issue_279_path |> File.read!() |> Jason.decode!()

    assert fixture["status"] == "unevaluated_live_provider"
    assert fixture["pipeline_version"] == "f5-1"
    assert fixture["execution"]["batch_shape"] == "paired"
    assert fixture["execution"]["repetitions_per_arm"] == 10
    assert fixture["execution"]["anchors_per_batch"] == 2
    assert fixture["execution"]["batches_per_arm"] == 10
    assert fixture["execution"]["anchors_per_arm"] == 20
    assert fixture["execution"]["total_arms"] == 3
    assert fixture["execution"]["total_pre_repair_provider_requests"] == 30
    assert fixture["execution"]["total_anchor_presentations"] == 60
    assert fixture["execution"]["price_only_after_provider_free_admission_dry_run"]
    assert fixture["execution"]["admit_and_price_each_arm_separately"]

    assert Enum.map(fixture["arms"], &{&1["id"], &1["prompt_version"]}) == [
             {"A", "extract-13"},
             {"B", "extract-14"},
             {"C", "extract-compact-exp-1"}
           ]

    assert Enum.map(fixture["cases"], & &1["id"]) == ["six_months", "nine_months"]

    assert Enum.sort(fixture["required_result_metadata"]) ==
             Enum.sort(
               ~w(provider model model_version prompt_version pipeline_version run_date source_revision request_count input_tokens output_tokens estimated_cost)
             )
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
