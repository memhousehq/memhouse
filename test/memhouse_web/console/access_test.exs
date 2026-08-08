# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Console.AccessTest do
  @moduledoc """
  Pins the two visibility rules and the action gates the browser console runs on.
  """

  use ExUnit.Case, async: true

  alias MemHouse.Actor
  alias MemHouseWeb.Console.Access

  @account_id "11111111-1111-1111-1111-111111111111"
  @me "22222222-2222-2222-2222-222222222222"
  @someone_else "33333333-3333-3333-3333-333333333333"

  describe "visible_states/1" do
    test "a curator sees every lifecycle state" do
      assert Access.visible_states(actor(role: :curator)) == Access.all_states()
    end

    test "an account admin sees every lifecycle state" do
      assert Access.visible_states(actor(role: :account_admin)) == Access.all_states()
    end

    test "a member sees only settled states" do
      states = Access.visible_states(actor(role: :member))

      assert "active" in states
      assert "superseded" in states

      # These are the disclosures the rule exists to prevent: undecided
      # proposals and content withdrawn on purpose.
      refute "proposed" in states
      refute "held" in states
      refute "provisional" in states
      refute "rejected" in states
      refute "contested" in states
      refute "redacted" in states
    end

    test "a reader sees the same settled states as a member" do
      assert Access.visible_states(actor(role: :reader)) ==
               Access.visible_states(actor(role: :member))
    end
  end

  describe "visible_knowledge?/2 — the provisional rule" do
    test "another peer's provisional statement is hidden from an account admin" do
      refute Access.visible_knowledge?(
               actor(role: :account_admin),
               item(state: "provisional", subject_peer_id: @someone_else)
             )
    end

    test "another peer's provisional statement is hidden from a member" do
      refute Access.visible_knowledge?(
               actor(role: :member),
               item(state: "provisional", subject_peer_id: @someone_else)
             )
    end

    test "your own provisional statement is visible to you" do
      assert Access.visible_knowledge?(
               actor(role: :reader),
               item(state: "provisional", subject_peer_id: @me)
             )
    end
  end

  describe "visible_knowledge?/2 — the governance-state rule" do
    test "a member sees an active statement about anyone" do
      assert Access.visible_knowledge?(
               actor(role: :member),
               item(state: "active", subject_peer_id: @someone_else)
             )
    end

    test "a member does not see a proposal about someone else" do
      refute Access.visible_knowledge?(
               actor(role: :member),
               item(state: "proposed", subject_peer_id: @someone_else)
             )
    end

    test "a member does see a proposal about themselves" do
      # The self-view exemption. Without it a person could not contest or redact
      # a claim about them that had not yet cleared a gate.
      assert Access.visible_knowledge?(
               actor(role: :member),
               item(state: "proposed", subject_peer_id: @me)
             )
    end

    test "a curator sees a proposal about anyone" do
      assert Access.visible_knowledge?(
               actor(role: :curator),
               item(state: "proposed", subject_peer_id: @someone_else)
             )
    end
  end

  describe "can?/2" do
    test "curation and promotion need a governing role" do
      assert Access.can?(actor(role: :curator), :curate)
      assert Access.can?(actor(role: :account_admin), :curate)
      refute Access.can?(actor(role: :member), :curate)
      refute Access.can?(actor(role: :reader), :promote)
    end

    test "the operations view is account-admin only" do
      assert Access.can?(actor(role: :account_admin), :administer)
      refute Access.can?(actor(role: :curator), :administer)
    end

    test "a machine credential holds no console authority at all" do
      # This is the check that keeps an agent out of curator and subject
      # gestures even when its resolved role would otherwise allow them.
      machine = actor(role: :account_admin, identity_kind: :api_key)

      refute Access.can?(machine, :curate)
      refute Access.can?(machine, :promote)
      refute Access.can?(machine, :administer)
      refute Access.can?(machine, :self_govern)
    end

    test "an unrecognised action is refused rather than raising" do
      refute Access.can?(actor(role: :account_admin), :invent_knowledge)
    end
  end

  describe "subject_of?/2" do
    test "true only for the subject, and only for a person" do
      assert Access.subject_of?(actor(role: :reader), item(subject_peer_id: @me))
      refute Access.subject_of?(actor(role: :reader), item(subject_peer_id: @someone_else))

      refute Access.subject_of?(
               actor(role: :account_admin, identity_kind: :api_key),
               item(subject_peer_id: @me)
             )
    end
  end

  describe "scope_role/2" do
    test "a scope absent from the actor's map has no role" do
      # Absent means "no access", either because no grant applies or because a
      # deny removed it. It must never soften to a default.
      assert Access.scope_role(actor(role: :member), "unknown-scope") == nil
    end
  end

  defp actor(overrides) do
    struct!(
      %Actor{
        account_id: @account_id,
        account_key: "test",
        peer_id: @me,
        identity_kind: :password,
        role: :member,
        scope_ids: [],
        scope_roles: %{}
      },
      overrides
    )
  end

  # A knowledge row reduced to the two fields the rules read. Using a plain map
  # keeps the test honest about what the rules actually depend on.
  defp item(overrides) do
    Enum.into(overrides, %{state: "active", subject_peer_id: nil})
  end
end
