# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Recall.PlannerTest do
  use ExUnit.Case, async: false

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

  test "reserves adaptive headroom, deduplicates the full base page, and refills its tail" do
    initial =
      Enum.map(1..12, fn index ->
        %{
          "id" => "k#{index}",
          "candidate_type" => "knowledge",
          "statement" => "base #{index}"
        }
      end)

    result =
      Planner.run(
        "What changed?",
        :medium,
        %{
          profile: fn _query, _state ->
            {:ok,
             [
               %{"id" => "k4", "evidence_type" => "knowledge", "statement" => "duplicate"},
               %{"id" => "adaptive", "evidence_type" => "knowledge", "statement" => "new"}
             ]}
          end
        },
        initial_evidence: initial,
        initial_item_limit: 6
      )

    ids = Enum.map(result.evidence, & &1["id"])

    assert Enum.take(ids, 8) == ["k1", "k2", "k3", "k4", "k5", "k6", "adaptive", "k7"]
    assert Enum.sort(ids) == Enum.sort(["adaptive" | Enum.map(1..12, &"k#{&1}")])
    assert "adaptive" in Enum.take(ids, 12)
    refute "k12" in Enum.take(ids, 12)

    assert [%{tool: "profile", admitted_items: 1} | _rest] = result.diagnostics.outcomes
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

  test "emits a content-free planner budget event" do
    handler = "planner-budget-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:memhouse, :recall, :planner],
        fn event, measurements, metadata, _config ->
          send(parent, {:planner_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Planner.run("Avery secret preference text", :low, %{})

    assert_receive {:planner_event, [:memhouse, :recall, :planner], measurements, metadata}
    assert measurements.tool_calls == 0
    assert measurements.model_calls == 0
    assert measurements.query_tokens == 0
    assert measurements.evidence_tokens == 0
    assert measurements.tokens == 0
    assert measurements.item_count == 0
    assert is_integer(measurements.elapsed_ms)
    assert metadata.effort == "low"
    assert metadata.playbook == "preferences"
    assert metadata.exhausted? == true
    assert metadata.exhausted == ["iterations"]
    refute inspect({measurements, metadata}) =~ "secret"
  end

  test "reserves model calls before running provider-backed tools" do
    original = Application.fetch_env!(:memhouse, :recall_planner)

    Application.put_env(
      :memhouse,
      :recall_planner,
      Keyword.update!(original, :low, &Map.put(&1, :max_model_calls, 1))
    )

    on_exit(fn -> Application.put_env(:memhouse, :recall_planner, original) end)
    parent = self()

    result =
      Planner.run("What changed?", :low, %{
        profile: %{
          model_calls: 2,
          run: fn _query, _state ->
            send(parent, :ran)
            {:ok, []}
          end
        }
      })

    assert result.diagnostics.model_calls == 0
    assert result.diagnostics.exhausted == ["model_calls"]
    refute_receive :ran
  end

  test "bounds initial and retrieved evidence by the total token budget" do
    original = Application.fetch_env!(:memhouse, :recall_planner)

    Application.put_env(
      :memhouse,
      :recall_planner,
      Keyword.update!(original, :low, &Map.merge(&1, %{max_total_tokens: 30, max_items: 10}))
    )

    on_exit(fn -> Application.put_env(:memhouse, :recall_planner, original) end)

    result =
      Planner.run("preference", :low, %{
        profile: fn _query, _state ->
          {:ok,
           [
             %{
               "id" => "too-large",
               "evidence_type" => "knowledge",
               "statement" => String.duplicate("private evidence ", 30)
             }
           ]}
        end
      })

    assert result.evidence == []
    assert "tokens" in result.diagnostics.exhausted
    assert result.diagnostics.tokens <= 30
  end

  test "kills a tool at the hard whole-planner elapsed budget" do
    original = Application.fetch_env!(:memhouse, :recall_planner)

    Application.put_env(
      :memhouse,
      :recall_planner,
      Keyword.update!(original, :low, &Map.put(&1, :max_elapsed_ms, 20))
    )

    on_exit(fn -> Application.put_env(:memhouse, :recall_planner, original) end)

    started_at = System.monotonic_time(:millisecond)

    result =
      Planner.run("slow preference", :low, %{
        profile: fn _query, _state ->
          Process.sleep(200)
          {:ok, [%{"id" => "must-not-arrive", "evidence_type" => "knowledge"}]}
        end
      })

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 150
    assert result.evidence == []
    assert result.diagnostics.tool_calls == 1
    assert result.diagnostics.exhausted == ["elapsed"]

    assert [%{status: "failed", reason_class: "timeout", admitted_items: 0}] =
             Enum.map(
               result.diagnostics.outcomes,
               &Map.take(&1, ~w(status reason_class admitted_items)a)
             )
  end
end
