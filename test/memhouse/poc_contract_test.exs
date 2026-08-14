# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.PocContractTest do
  @moduledoc """
  Pins the frozen behaviour baseline of the memory system as executable evidence.

    `poc-0` is the version identity of that baseline: the earliest public behaviour of
    this system, frozen on purpose so later work cannot drift away from it by accident.
    The string is a version value, not a project phase.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.Memory

  # Strips every credential a provider could pick up: the environment variable named by the
  # role's `api_key_ref` and the legacy `:models` entry. The deterministic extractor identity
  # asserted below is chosen at boot by the test environment's role configuration, not here;
  # this setup only makes sure a stray key in the developer's shell cannot send the extractor
  # at a live endpoint. Both values are global to the node, so they are captured and restored
  # and this module cannot run async.
  setup do
    original_api_key = System.get_env("OPENROUTER_API_KEY")
    original_models = Application.fetch_env!(:memhouse, :models)

    System.delete_env("OPENROUTER_API_KEY")
    Application.put_env(:memhouse, :models, Keyword.put(original_models, :api_key, nil))

    on_exit(fn ->
      if original_api_key do
        System.put_env("OPENROUTER_API_KEY", original_api_key)
      else
        System.delete_env("OPENROUTER_API_KEY")
      end

      Application.put_env(:memhouse, :models, original_models)
    end)

    :ok
  end

  test "ingest persists the raw message and pipeline-created knowledge lifecycle" do
    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => "contract-persistence",
               "session_id" => "session-1",
               "scope_path" => "/contract/persistence",
               "peer_key" => "agent-1",
               "role" => "user",
               "content" => "Avery prefers concise weekly release summaries."
             })

    # The raw observation must survive byte-for-byte: it is the system of record that every
    # derived row can be rebuilt from. Extraction identity is stored on the knowledge row so a
    # later reader can tell which extractor produced a statement and re-run or discard it.
    # "f5-1" is the version identity of the extraction-and-pipeline contract; changing it is a
    # deliberate transition that also changes what the health endpoint reports.
    assert message["content"] == "Avery prefers concise weekly release summaries."

    assert {:ok, [knowledge]} =
             Memory.extract_message(message["id"], "contract-persistence")

    assert knowledge["statement"] == "Avery prefers concise weekly release summaries."
    assert knowledge["extracting_provider"] == "deterministic"
    assert knowledge["extracting_model"] == "local-structured-fallback"
    assert knowledge["extracting_model_version"] == "1"
    assert knowledge["prompt_version"] == "extract-11"
    assert knowledge["pipeline_version"] == "f5-1"
    assert knowledge["source_message_ids"] == [message["id"]]

    # Read the durable rows directly instead of trusting the response map, so this also proves
    # the message, the knowledge item, and its lifecycle really committed. Repeating the
    # `message_id` and `knowledge_id` bindings across both rows makes the match itself require
    # that both lifecycle events belong to the same message and the same knowledge item.
    #
    # The two rows must appear in this order and no other: knowledge enters `proposed` from the
    # pipeline, and governance then places it in `provisional` because the default gate matrix
    # defers to a human rather than auto-activating. The reason strings are durable audit
    # values. A single row, a different order, or an `active` state here means auto-activation
    # has crept back in and knowledge is escaping review.
    assert %{
             rows: [
               [
                 message_id,
                 "Avery prefers concise weekly release summaries.",
                 knowledge_id,
                 "proposed",
                 "f4_pipeline_proposed"
               ],
               [
                 message_id,
                 "Avery prefers concise weekly release summaries.",
                 knowledge_id,
                 "provisional",
                 "f4_gate_a_b_deferred"
               ]
             ]
           } =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT m.id, m.content, k.id, event.to_state, event.reason
               FROM messages AS m
               JOIN knowledge_items AS k ON m.id = ANY(k.source_message_ids)
               JOIN knowledge_lifecycle_events AS event ON event.knowledge_item_id = k.id
               WHERE m.id = $1
               ORDER BY event.occurred_at, event.inserted_at, event.id
               """,
               [Ecto.UUID.dump!(message["id"])]
             )

    assert Ecto.UUID.load!(message_id) == message["id"]
    assert Ecto.UUID.load!(knowledge_id) == knowledge["id"]
  end

  # Two scopes in one containment chain: /contract/team contains /contract/team/project. Each
  # gets its own session, peer, and observation so the two knowledge items are distinguishable.
  test "knowledge inherits from ancestors down to descendants but never upward" do
    assert {:ok, parent_message} =
             Memory.ingest_message(%{
               "account_key" => "contract-inheritance",
               "session_id" => "parent-session",
               "scope_path" => "/contract/team",
               "peer_key" => "parent-agent",
               "content" => "The team architecture uses an append-only audit ledger."
             })

    assert {:ok, child_message} =
             Memory.ingest_message(%{
               "account_key" => "contract-inheritance",
               "session_id" => "child-session",
               "scope_path" => "/contract/team/project",
               "peer_key" => "child-agent",
               "content" => "The project release review happens every Friday."
             })

    assert {:ok, [parent_knowledge]} =
             Memory.extract_message(parent_message["id"], "contract-inheritance")

    assert {:ok, [child_knowledge]} =
             Memory.extract_message(child_message["id"], "contract-inheritance")

    parent_knowledge_id = Map.fetch!(parent_knowledge, "id")
    child_knowledge_id = Map.fetch!(child_knowledge, "id")

    descendant_ids =
      "contract-inheritance"
      |> knowledge_ids("/contract/team/project")
      |> MapSet.new()

    ancestor_ids =
      "contract-inheritance"
      |> knowledge_ids("/contract/team")
      |> MapSet.new()

    # Reading the nested scope sees both its own knowledge and everything inherited from the
    # containing scope. Reading the containing scope sees only its own.
    assert MapSet.member?(descendant_ids, parent_knowledge_id)
    assert MapSet.member?(descendant_ids, child_knowledge_id)
    assert MapSet.member?(ancestor_ids, parent_knowledge_id)

    # The load-bearing line of this test. If the nested scope's knowledge ever shows up when
    # reading its parent, a private sub-team's memory has leaked upward to everyone who can
    # read the enclosing scope, bypassing the governed promotion path entirely.
    refute MapSet.member?(ancestor_ids, child_knowledge_id)
  end

  # Lists the knowledge ids an Account-key-scoped read of one scope path returns, including
  # everything inherited from that scope's ancestors.
  defp knowledge_ids(account_key, scope_path) do
    %{"account_key" => account_key, "scope_path" => scope_path}
    |> Memory.query_knowledge()
    |> Enum.map(& &1["id"])
  end
end
