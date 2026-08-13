# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Governance.AutoshareTest do
  @moduledoc """
  Evidence that the benchmark posture is reachable, and that it stops where it should.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Governance.GateRule

  require Ash.Query

  test "writes one automatic cell per level and sensitivity, and none for restricted" do
    key = ensure_account!("autoshare")

    run!(key)

    rules = rules(key)

    assert length(rules) == 9
    assert Enum.all?(rules, &(&1.gate_a_mode == "auto_keep" and &1.gate_b_mode == "auto_place"))

    # The evidence floor is the field that decides whether the rest has any effect: one
    # participant speaking about another is indirect, which is most of a relayed conversation.
    assert Enum.all?(rules, &(&1.minimum_evidence_level == "indirect"))

    refute Enum.any?(rules, &(&1.sensitivity == "restricted"))
  end

  test "running it twice leaves the same nine cells" do
    key = ensure_account!("autoshare-repeat")

    run!(key)
    run!(key)

    assert length(rules(key)) == 9
  end

  test "refuses to run without an Account" do
    assert_raise Mix.Error, fn -> Mix.Tasks.Memhouse.Governance.Autoshare.run([]) end
  end

  defp ensure_account!(prefix) do
    key = "#{prefix}-#{System.unique_integer([:positive])}"
    DataLayer.with_account_key(key, fn _account, _actor -> :ok end)
    key
  end

  defp run!(key) do
    Mix.shell(Mix.Shell.Process)
    Mix.Tasks.Memhouse.Governance.Autoshare.run(["--account-key", key])
  end

  defp rules(key) do
    DataLayer.with_account_key(key, [role: :system, pipeline?: true], fn account, actor ->
      GateRule
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: actor)
    end)
  end
end
