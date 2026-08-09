# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.SchemaReasoningTest do
  @moduledoc """
  Pins the hostile-output boundary for dream-time reasoning.

  The model can propose deductions and edges. It cannot choose their durable
  visibility, lifecycle, or inputs outside the Account-scoped working set.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Model.Schema.Reasoning

  @account_id Ecto.UUID.generate()
  @scope_id Ecto.UUID.generate()
  @source_id Ecto.UUID.generate()
  @target_id Ecto.UUID.generate()

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        account_id: @account_id,
        scope_id: @scope_id,
        known_peer_keys: ["avery"],
        source_peer_key: "avery",
        reasoning_inheritance: %{sensitivity: "internal", target_level: "peer"},
        reasoning_inputs: [
          %{id: @source_id, account_id: @account_id, scope_id: @scope_id, state: "active"},
          %{id: @target_id, account_id: @account_id, scope_id: @scope_id, state: "active"}
        ]
      },
      overrides
    )
  end

  defp relation(attrs \\ %{}) do
    Map.merge(
      %{"source_id" => @source_id, "target_id" => @target_id, "kind" => "supports"},
      attrs
    )
  end

  defp deduction(attrs \\ %{}) do
    Map.merge(
      %{
        "reasoning" => "The active inputs support this deduction.",
        "statement" => "Avery prefers weekly release summaries.",
        "kind" => "preference",
        "subject_type" => "peer",
        "subject_ref" => "avery",
        "confidence_percentage" => 90,
        "sensitivity" => "internal",
        "target_level" => "peer",
        "update_operation" => "add"
      },
      attrs
    )
  end

  test "accepts bounded active same-scope relations and returns normalized edges" do
    assert {:ok,
            %{
              items: [],
              relations: [%{source_id: @source_id, target_id: @target_id, kind: "supports"}]
            }} = Reasoning.cast(%{"items" => [], "relations" => [relation()]}, context())
  end

  test "rejects malformed, unsupported, self, and duplicate relation output" do
    assert {:error, ["relations[0].source_id must be a UUID"]} =
             Reasoning.cast(
               %{"items" => [], "relations" => [relation(%{"source_id" => "not-a-uuid"})]},
               context()
             )

    assert {:error, ["relations[0].kind is invalid"]} =
             Reasoning.cast(
               %{"items" => [], "relations" => [relation(%{"kind" => "related_to"})]},
               context()
             )

    assert {:error, ["relations[0] must not be self-referential"]} =
             Reasoning.cast(
               %{"items" => [], "relations" => [relation(%{"target_id" => @source_id})]},
               context()
             )

    assert {:error, ["relations[1] duplicates another relation"]} =
             Reasoning.cast(%{"items" => [], "relations" => [relation(), relation()]}, context())
  end

  test "rejects a missing, foreign-account, foreign-scope, or inactive input" do
    assert {:error, ["relations[0].target_id must name a supplied input"]} =
             Reasoning.cast(
               %{
                 "items" => [],
                 "relations" => [relation(%{"target_id" => Ecto.UUID.generate()})]
               },
               context()
             )

    foreign_account = Ecto.UUID.generate()

    assert {:error, ["relations[0].target_id must belong to the current account"]} =
             Reasoning.cast(
               %{"items" => [], "relations" => [relation()]},
               context(%{
                 reasoning_inputs: [
                   %{
                     id: @source_id,
                     account_id: @account_id,
                     scope_id: @scope_id,
                     state: "active"
                   },
                   %{
                     id: @target_id,
                     account_id: foreign_account,
                     scope_id: @scope_id,
                     state: "active"
                   }
                 ]
               })
             )

    assert {:error, ["relations[0].target_id must be in the current scope"]} =
             Reasoning.cast(
               %{"items" => [], "relations" => [relation()]},
               context(%{
                 reasoning_inputs: [
                   %{
                     id: @source_id,
                     account_id: @account_id,
                     scope_id: @scope_id,
                     state: "active"
                   },
                   %{
                     id: @target_id,
                     account_id: @account_id,
                     scope_id: Ecto.UUID.generate(),
                     state: "active"
                   }
                 ]
               })
             )

    assert {:error, ["relations[0].target_id must name active knowledge"]} =
             Reasoning.cast(
               %{"items" => [], "relations" => [relation()]},
               context(%{
                 reasoning_inputs: [
                   %{
                     id: @source_id,
                     account_id: @account_id,
                     scope_id: @scope_id,
                     state: "active"
                   },
                   %{
                     id: @target_id,
                     account_id: @account_id,
                     scope_id: @scope_id,
                     state: "superseded"
                   }
                 ]
               })
             )
  end

  test "deductions inherit visibility and cannot request lifecycle control" do
    assert {:error, ["items[0].target_level must inherit the working set"]} =
             Reasoning.cast(
               %{"items" => [deduction(%{"target_level" => "account"})], "relations" => []},
               context()
             )

    assert {:error, ["items[0].state is pipeline-controlled"]} =
             Reasoning.cast(
               %{"items" => [deduction(%{"state" => "active"})], "relations" => []},
               context()
             )
  end

  test "the advertised limits match the cast boundary" do
    schema = Reasoning.json_schema()

    assert get_in(schema, ["properties", "items", "maxItems"]) == 12
    assert get_in(schema, ["properties", "relations", "maxItems"]) == 24

    assert {:error, ["items must contain at most 12 deductions"]} =
             Reasoning.cast(
               %{"items" => List.duplicate(deduction(), 13), "relations" => []},
               context()
             )

    assert {:error, ["relations must contain at most 24 relations"]} =
             Reasoning.cast(
               %{"items" => [], "relations" => List.duplicate(relation(), 25)},
               context()
             )
  end
end
