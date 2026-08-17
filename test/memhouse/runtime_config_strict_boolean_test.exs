# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.RuntimeConfigStrictBooleanTest do
  use ExUnit.Case, async: false

  @variable "MEMHOUSE_EXPERIMENTAL_MINIMAL_RECALL"

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
end
