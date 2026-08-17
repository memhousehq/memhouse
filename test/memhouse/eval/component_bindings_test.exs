# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ComponentBindingsTest do
  use ExUnit.Case, async: false

  alias MemHouse.Eval.{ComponentBindings, VariantRuntime}

  test "derives independently controlled recall and maintenance components" do
    variant = %{
      "id" => "minimal-ablation",
      "profile" => "minimal",
      "strategies" => nil,
      "deadline" => "disabled",
      "extraction_batching" => true,
      "recall_effort" => "medium",
      "source_recall" => true,
      "lineage_recall" => false,
      "semantic_index_refresh" => false,
      "recall_projection_refresh" => true,
      "idle_dream_scheduling" => true,
      "dream_time" => true,
      "durability_audit" => false
    }

    assert ComponentBindings.resolve!(variant) == %{
             "adaptive_recall_effort" => "medium",
             "dream_time" => true,
             "dream_reasoning_operations" => %{
               "split_enabled" => false,
               "synthesis" => false,
               "update" => true
             },
             "durability_audit" => false,
             "extraction_batching" => %{
               "claim_timeout_seconds" => 1200,
               "context_limit_tokens" => 131_072,
               "enabled" => true,
               "identity" => "utf8-bytes-v1:target=4096:context=131072:output=8192:margin=2048",
               "max_anchors" => 32,
               "reserved_output_tokens" => 8192,
               "safety_margin_tokens" => 2048,
               "target_tokens" => 4096,
               "tokenizer" => "utf8-bytes-v1"
             },
             "idle_dream_scheduling" => %{
               "enabled" => true,
               "idle_seconds" => 0,
               "max_delta_items" => 20,
               "max_elapsed_ms" => 120_000,
               "max_working_set_items" => 50,
               "min_changes" => 1,
               "min_interval_seconds" => 0
             },
             "lineage_recall" => false,
             "recall_projection_refresh" => true,
             "retrieval_deadline" => "disabled",
             "retrieval_profile" => "minimal",
             "retrieval_rerank" => false,
             "retrieval_seeds" => ["semantic_dual_lane", "lexical"],
             "retrieval_strategies" => ["semantic_dual_lane", "lexical"],
             "semantic_index_refresh" => false,
             "source_recall" => true
           }
  end

  test "fixed recall cannot falsely claim source or lineage behavior" do
    variant = %{
      "id" => "lying-fixed",
      "profile" => "balanced",
      "strategies" => ["lexical"],
      "source_recall" => true
    }

    assert_raise ArgumentError,
                 ~r/cannot enable source or lineage recall with fixed effort/,
                 fn ->
                   ComponentBindings.resolve!(variant)
                 end
  end

  test "profile bindings keep the closed JSON string boundary" do
    assert_raise ArgumentError, ~r/unknown retrieval profile: :balanced/, fn ->
      ComponentBindings.resolve!(%{
        "id" => "atom-profile",
        "profile" => :balanced,
        "strategies" => nil
      })
    end

    assert_raise ArgumentError, ~r/unknown retrieval profile: "balanced-ish"/, fn ->
      ComponentBindings.resolve!(%{
        "id" => "unknown-profile",
        "profile" => "balanced-ish",
        "strategies" => nil
      })
    end
  end

  test "runtime feature switches are restored when execution raises" do
    batching = Application.fetch_env!(:memhouse, :extraction_batching)
    dream_gates = Application.fetch_env!(:memhouse, :dream_time_gates)
    dream_operations = Application.fetch_env!(:memhouse, :dream_reasoning_operations)
    profiles = Application.fetch_env!(:memhouse, :retrieval_profiles)

    components = %{
      "extraction_batching" => %{"enabled" => true},
      "idle_dream_scheduling" => %{"enabled" => true},
      "dream_reasoning_operations" => %{"split_enabled" => true},
      "retrieval_profile" => "minimal"
    }

    assert_raise RuntimeError, "stop", fn ->
      VariantRuntime.with_components(components, fn ->
        assert Application.fetch_env!(:memhouse, :extraction_batching)[:enabled]
        assert Application.fetch_env!(:memhouse, :dream_time_gates)[:idle_scheduler_enabled]
        assert Application.fetch_env!(:memhouse, :dream_reasoning_operations)[:split_enabled]
        assert Application.fetch_env!(:memhouse, :retrieval_profiles)[:minimal_enabled]
        assert MemHouse.Pipeline.ExtractionAdmission.enabled?()
        assert MemHouse.Pipeline.idle_dream_time_enabled?()
        raise "stop"
      end)
    end

    assert Application.fetch_env!(:memhouse, :extraction_batching) == batching
    assert Application.fetch_env!(:memhouse, :dream_time_gates) == dream_gates
    assert Application.fetch_env!(:memhouse, :dream_reasoning_operations) == dream_operations
    assert Application.fetch_env!(:memhouse, :retrieval_profiles) == profiles
  end

  test "split dream reasoning cannot be declared without executing dream-time" do
    assert_raise ArgumentError, ~r/cannot enable split dream reasoning without dream_time/, fn ->
      ComponentBindings.resolve!(%{
        "id" => "inert-split",
        "profile" => "balanced",
        "strategies" => ["lexical"],
        "dream_reasoning_split" => true
      })
    end
  end
end
