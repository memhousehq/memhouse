# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Knowledge.LifecycleContractTest do
  use ExUnit.Case, async: true

  alias MemHouse.Knowledge.Lifecycle
  alias MemHouse.Memory.Visibility

  test "the lifecycle contract rejects undocumented edges" do
    assert Lifecycle.allowed_transition?("proposed", "active")
    assert Lifecycle.allowed_transition?("provisional", "held")
    assert Lifecycle.allowed_transition?("active", "needs_revalidation")

    refute Lifecycle.allowed_transition?("active", "proposed")
    refute Lifecycle.allowed_transition?("expired", "active")
  end

  test "the lifecycle contract owns every public state and its operator meaning" do
    assert Lifecycle.states() ==
             ~w(
               proposed active provisional held needs_revalidation superseded
               expired rejected contested redacted stale retracted
             )

    for state <- Lifecycle.states() do
      contract = Lifecycle.fetch!(state)
      assert contract.meaning != ""
      assert contract.example != ""
      assert contract.fixture != ""
      assert contract.entry != ""
      assert contract.actor_queue != ""
      assert contract.lifecycle != ""
      assert contract.downstream != ""
      assert contract.evidence != ""
      assert contract.stability in [:transient, :stable, :terminal]
      assert contract.retrieval in [:all_authorized, :subject_only, :none]
    end
  end

  test "the graph gives an explicit verdict for every state pair" do
    documented =
      Map.new(Lifecycle.states(), fn state ->
        {state, Lifecycle.fetch!(state).exits}
      end)

    for from_state <- Lifecycle.states(), to_state <- Lifecycle.states() do
      assert Lifecycle.allowed_transition?(from_state, to_state) ==
               to_state in Map.fetch!(documented, from_state)
    end
  end

  test "search and ask visibility follows the state contract" do
    peer = "22222222-2222-2222-2222-222222222222"
    other = "33333333-3333-3333-3333-333333333333"
    actor = %{peer_id: peer}

    for state <- Lifecycle.states() do
      own = %{
        state: state,
        subject_peer_id: peer,
        sensitivity: "internal",
        target_level: "peer",
        expires_at: nil
      }

      another = %{own | subject_peer_id: other}

      case Lifecycle.fetch!(state).retrieval do
        :all_authorized ->
          assert Visibility.visible?(own, actor, false)
          assert Visibility.visible?(another, actor, false)

        :subject_only ->
          assert Visibility.visible?(own, actor, false)
          refute Visibility.visible?(another, actor, false)

        :none ->
          refute Visibility.visible?(own, actor, false)
          refute Visibility.visible?(another, actor, false)
      end
    end
  end

  test "the published contract names every executable state and fixture" do
    docs = File.read!("docs/concepts/memory-model.md")

    assert docs =~ "`MemHouse.Knowledge.Lifecycle` is the executable source"
    assert docs =~ Lifecycle.markdown_table()
  end

  test "the offline lifecycle fixture names every required real-path scenario" do
    fixture =
      "test/fixtures/eval/lifecycle-contract.json"
      |> File.read!()
      |> Jason.decode!()

    assert fixture["provider_calls"] == "none"

    assert fixture["executor"] ==
             "mix test test/memhouse/f4_real_gate_a_b_governance_test.exs test/memhouse/f6_documents_connectors_sync_test.exs --only issue_277_lifecycle_fixture"

    assert Enum.flat_map(fixture["paths"], & &1["states"]) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(Lifecycle.states())

    assert MapSet.new(Enum.map(fixture["paths"], & &1["id"])) ==
             MapSet.new(~w(
               review approval rejection revalidation expiry dispute supersession redaction
               source_retraction
             ))
  end
end
