# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.RuntimeConfigStrictBooleanTest do
  @moduledoc """
  Verifies ambiguous experiment booleans fail closed during runtime configuration.
  """

  use ExUnit.Case, async: false

  @variable "MEMHOUSE_EXPERIMENTAL_MINIMAL_RECALL"

  test "generation and reranker routes can pin different provider classes" do
    variables = %{
      "MEMHOUSE_OPENROUTER_GENERATION_UPSTREAM_ROUTE" => "openai",
      "MEMHOUSE_OPENROUTER_RERANKER_UPSTREAM_ROUTE" => "voyage"
    }

    originals = Map.new(variables, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(variables, fn {name, value} -> System.put_env(name, value) end)

      roles =
        "config/runtime.exs"
        |> Config.Reader.read!(env: :test, target: :host)
        |> Keyword.fetch!(:memhouse)
        |> Keyword.fetch!(:model_roles)

      assert get_in(roles, [:ingest_extractor, :options, "upstream_route"]) == "openai"
      assert get_in(roles, [:reranker, :options, "upstream_route"]) == "voyage"
    after
      Enum.each(originals, fn {name, value} -> restore_env(name, value) end)
    end
  end

  test "campaign startup binds the approved run and PostgreSQL backend" do
    variables = %{
      "MEMHOUSE_CAMPAIGN_ADMISSION_PATH" => "/tmp/admission.json",
      "MEMHOUSE_CAMPAIGN_LEDGER_DIR" => "/tmp/campaign-ledger",
      "MEMHOUSE_CAMPAIGN_ADMISSION_SHA256" => String.duplicate("a", 64),
      "MEMHOUSE_CAMPAIGN_DEFINITION_ID" => "issue-287-v1",
      "MEMHOUSE_CAMPAIGN_ARM_ID" => "B",
      "MEMHOUSE_CAMPAIGN_RUN_ID" => "issue-287-pg0-run-1",
      "MEMHOUSE_CAMPAIGN_BACKEND_MODE" => "pg0",
      "MEMHOUSE_CAMPAIGN_TARGET_REVISION" => String.duplicate("b", 40),
      "MEMHOUSE_DATABASE_MODE" => "pg0"
    }

    originals = Map.new(variables, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(variables, fn {name, value} -> System.put_env(name, value) end)

      {_path, _digest, opts} =
        "config/runtime.exs"
        |> Config.Reader.read!(env: :test, target: :host)
        |> Keyword.fetch!(:memhouse)
        |> Keyword.fetch!(:campaign_admission)

      assert opts[:run_id] == "issue-287-pg0-run-1"

      assert opts[:backend] == %{
               "engine" => "postgres",
               "mode" => "pg0",
               "sqlite" => "unsupported"
             }
    after
      Enum.each(originals, fn {name, value} -> restore_env(name, value) end)
    end
  end

  test "campaign backend must match the node's actual PostgreSQL mode" do
    variables = %{
      "MEMHOUSE_CAMPAIGN_ADMISSION_PATH" => "/tmp/admission.json",
      "MEMHOUSE_CAMPAIGN_LEDGER_DIR" => "/tmp/campaign-ledger",
      "MEMHOUSE_CAMPAIGN_ADMISSION_SHA256" => String.duplicate("a", 64),
      "MEMHOUSE_CAMPAIGN_DEFINITION_ID" => "issue-287-v1",
      "MEMHOUSE_CAMPAIGN_ARM_ID" => "B",
      "MEMHOUSE_CAMPAIGN_RUN_ID" => "issue-287-pg0-run-1",
      "MEMHOUSE_CAMPAIGN_BACKEND_MODE" => "pg0",
      "MEMHOUSE_CAMPAIGN_TARGET_REVISION" => String.duplicate("b", 40),
      "MEMHOUSE_DATABASE_MODE" => "external"
    }

    originals = Map.new(variables, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(variables, fn {name, value} -> System.put_env(name, value) end)

      assert_raise RuntimeError,
                   ~r/MEMHOUSE_CAMPAIGN_BACKEND_MODE must match MEMHOUSE_DATABASE_MODE/,
                   fn -> Config.Reader.read!("config/runtime.exs", env: :test, target: :host) end
    after
      Enum.each(originals, fn {name, value} -> restore_env(name, value) end)
    end
  end

  test "minimal-recall switch rejects an ambiguous value at boot and restores the environment" do
    original = System.get_env(@variable)

    try do
      System.put_env(@variable, "tru")

      assert_raise RuntimeError,
                   ~r/MEMHOUSE_EXPERIMENTAL_MINIMAL_RECALL must be true or false, got: "tru"/,
                   fn ->
                     Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
                   end
    after
      restore_env(original)
    end

    assert System.get_env(@variable) == original
  end

  defp restore_env(nil), do: System.delete_env(@variable)
  defp restore_env(value), do: System.put_env(@variable, value)
  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
