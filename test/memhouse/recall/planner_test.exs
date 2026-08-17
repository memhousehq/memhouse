# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Recall.PlannerTest do
  use ExUnit.Case, async: true

  alias MemHouse.Recall.Planner

  test "deduplicates stable evidence and obeys the low effort call budget" do
    parent = self()

    tools = %{
      profile: fn _query, _state ->
        send(parent, :profile)
        {:ok, [%{"id" => "p1", "evidence_type" => "profile", "statement" => "stable"}]}
      end,
      source_exact: fn _query, _state ->
        send(parent, :exact)

        {:ok,
         [
           %{"id" => "p1", "evidence_type" => "profile"},
           %{"id" => "m1", "evidence_type" => "source_message", "statement" => "source"}
         ]}
      end,
      source_semantic: fn _query, _state ->
        send(parent, :semantic)
        {:ok, [%{"id" => "m1", "evidence_type" => "source_message"}]}
      end
    }

    result =
      Planner.run("What does Avery prefer?", :low, tools,
        initial_evidence: [%{"id" => "k1", "candidate_type" => "knowledge"}],
        initial_tool_calls: 1
      )

    assert Enum.map(result.evidence, & &1["id"]) == ["k1", "p1", "m1"]
    assert result.diagnostics.effort == "low"
    assert result.diagnostics.playbook == "preferences"
    assert result.diagnostics.tool_calls == 3
    assert result.diagnostics.model_calls == 0
    assert "tool_calls" in result.diagnostics.exhausted
    assert_receive :profile
    assert_receive :exact
    refute_receive :semantic
  end

  test "tool failures are content-safe and partial evidence survives" do
    tools = %{
      source_exact: fn _query, _state -> {:error, {:provider_error, "secret body"}} end,
      source_semantic: fn _query, _state ->
        {:ok, [%{"id" => "m1", "evidence_type" => "source_message"}]}
      end
    }

    result = Planner.run("When did the release change?", :medium, tools)

    assert Enum.map(result.evidence, & &1["id"]) == ["m1"]
    assert result.diagnostics.playbook == "updates"
    assert Enum.any?(result.diagnostics.outcomes, &(&1.reason_class == "provider_error"))
    refute inspect(result.diagnostics) =~ "secret body"
  end

  test "unknown effort and non-allowlisted tools fail closed" do
    assert_raise ArgumentError, ~r/unknown recall effort/, fn ->
      Planner.run("question", "unbounded", %{})
    end

    result =
      Planner.run("question", :high, %{
        delete_memory: fn _query, _state -> raise "must never run" end
      })

    assert result.evidence == []
    assert result.diagnostics.tool_calls == 0
  end
end
