# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.IngestRelayTest do
  @moduledoc """
  Evidence that an agent relaying a conversation never becomes a party to it.

  An agent submits observations spoken by other people. Attributing those turns to the
  agent made it the only nameable subject in the Account, so every personal statement was
  filed against an infrastructure identity — which then consented to itself, could not be
  erased by its real subject, and counted as first-hand evidence.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Governance.AuditEvent
  alias MemHouse.Identity
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Model.PromptCaptureProvider
  alias MemHouse.Observations.SessionParticipant

  require Ash.Query

  setup do
    bootstrap =
      Identity.bootstrap_human(%{
        email: "relay@example.test",
        name: "Relay Admin",
        password: "correct horse battery staple"
      })

    agent =
      Identity.provision_agent(bootstrap.actor, %{
        key: "relay-agent",
        name: "Relay Agent",
        scope_path: "/",
        role: "member"
      })

    {:ok, agent_actor} = Identity.authenticate_bearer(agent.api_key)

    %{bootstrap: bootstrap, agent: agent, agent_actor: agent_actor}
  end

  test "a relayed turn is attributed to its speaker, not to the credential", ctx do
    {:ok, message} = relay(ctx.agent_actor, "caroline", "Caroline keeps bees on her allotment.")

    speaker = peer_by_key!(ctx, "caroline")

    assert message["peer_id"] == speaker.id
    refute message["peer_id"] == ctx.agent.peer.id
  end

  test "the relaying credential stays the audited actor, with the speaker beside it", ctx do
    {:ok, message} = relay(ctx.agent_actor, "caroline", "Caroline keeps bees on her allotment.")

    speaker = peer_by_key!(ctx, "caroline")

    entry =
      DataLayer.with_actor(ctx.bootstrap.actor, fn account, actor ->
        AuditEvent
        |> Ash.Query.filter(resource_id == ^message["id"] and action == "message.ingested")
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: actor)
      end)

    # Who spoke and who submitted are different questions, and the audit answers both.
    assert entry.actor_peer_id == ctx.agent.peer.id
    assert entry.metadata["speaker_peer_id"] == speaker.id
  end

  test "two speakers in one session enrol separately and the agent does not", ctx do
    {:ok, _} = relay(ctx.agent_actor, "caroline", "Caroline keeps bees on her allotment.")
    {:ok, _} = relay(ctx.agent_actor, "melanie", "Melanie teaches watercolour on Tuesdays.")

    participants =
      DataLayer.with_actor(ctx.bootstrap.actor, fn account, actor ->
        SessionParticipant
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.peer_id)
      end)

    caroline = peer_by_key!(ctx, "caroline")
    melanie = peer_by_key!(ctx, "melanie")

    assert caroline.id in participants
    assert melanie.id in participants
    refute ctx.agent.peer.id in participants
  end

  test "no extracted statement is about the relaying agent", ctx do
    {:ok, first} = relay(ctx.agent_actor, "caroline", "Caroline keeps bees on her allotment.")
    {:ok, second} = relay(ctx.agent_actor, "melanie", "Melanie teaches watercolour on Tuesdays.")

    {:ok, _} = Memory.extract_message(first["id"], ctx.bootstrap.account.key)
    {:ok, _} = Memory.extract_message(second["id"], ctx.bootstrap.account.key)

    items =
      DataLayer.with_actor(ctx.bootstrap.actor, fn account, actor ->
        KnowledgeItem
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read!(actor: %{actor | scope_ids: :all})
      end)

    assert items != []

    # The two halves of the bug, asserted separately: the agent is not a subject, and its
    # name is not in the prose either.
    refute Enum.any?(items, &(&1.subject_peer_id == ctx.agent.peer.id))
    refute Enum.any?(items, &String.contains?(&1.statement, "relay-agent"))

    subjects = items |> Enum.map(& &1.subject_peer_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    assert peer_by_key!(ctx, "caroline").id in subjects
  end

  test "a speaker's own statement is direct evidence and another's is not", ctx do
    {:ok, message} = relay(ctx.agent_actor, "caroline", "Caroline keeps bees on her allotment.")
    {:ok, [knowledge]} = Memory.extract_message(message["id"], ctx.bootstrap.account.key)

    # Caroline spoke about Caroline. Before the fix the speaker was the agent, so this was
    # hearsay about a robot; now it is what it always was.
    assert Map.fetch!(knowledge, "evidence_level") == "direct"
  end

  test "a password session speaks as itself and ignores a body peer_key", ctx do
    {:ok, message} =
      Memory.ingest_message(
        %{
          "session_id" => "relay-human",
          "scope_path" => "/relay",
          "peer_key" => "caroline",
          "content" => "The team uses Elixir."
        },
        ctx.bootstrap.actor
      )

    # Relaying is a machine's job. A person signed in as themselves posting under somebody
    # else's name is impersonation, and the field is ignored rather than honoured.
    assert message["peer_id"] == ctx.bootstrap.actor.peer_id
  end

  test "relaying an existing agent's key does not turn that agent into a person", ctx do
    {:ok, _} = relay(ctx.agent_actor, "relay-agent", "The team uses Elixir.")

    # `Peer.:ensure` upserts `kind`, so a blind create here would rewrite the agent as human
    # — and a human-kind agent is a legal subject again.
    assert peer_by_key!(ctx, "relay-agent").kind == "agent"
  end

  test "the prompt offers the session's people as subjects and never the agent", ctx do
    original = Application.get_env(:memhouse, :model_provider)
    Application.put_env(:memhouse, :model_provider, PromptCaptureProvider)

    # Restore the global provider before stopping the recorder, never after: a teardown that
    # fails part-way must not leave `:model_provider` naming a process that is gone.
    on_exit(fn ->
      if original,
        do: Application.put_env(:memhouse, :model_provider, original),
        else: Application.delete_env(:memhouse, :model_provider)

      PromptCaptureProvider.stop()
    end)

    {:ok, _} = relay(ctx.agent_actor, "caroline", "Caroline keeps bees on her allotment.")
    {:ok, message} = relay(ctx.agent_actor, "melanie", "Melanie teaches watercolour on Tuesdays.")

    PromptCaptureProvider.start!([
      %{
        "reasoning" => "The observation states this directly.",
        "statement" => "Melanie teaches watercolour on Tuesdays.",
        "kind" => "fact",
        "subject_type" => "peer",
        "subject_ref" => "melanie",
        "confidence_level" => "stated_explicitly",
        "sensitivity" => "internal",
        "target_level" => "peer",
        "source_message_ids" => [message["id"]]
      }
    ])

    {:ok, _} = Memory.extract_message(message["id"], ctx.bootstrap.account.key)

    assert [messages] = PromptCaptureProvider.messages()
    user = Enum.find_value(messages, "", &if(&1.role == "user", do: &1.content))

    # The prompt is the only place the allowlist is observable, and it is the exact surface
    # where the agent used to appear as a nameable subject.
    assert user =~ "Conversation participants: caroline, melanie"
    refute user =~ "relay-agent"
  end

  defp relay(actor, peer_key, content) do
    Memory.ingest_message(
      %{
        "session_id" => "relay-session",
        "scope_path" => "/relay",
        "peer_key" => peer_key,
        "content" => content
      },
      actor
    )
  end

  defp peer_by_key!(ctx, key) do
    DataLayer.with_actor(ctx.bootstrap.actor, fn account, actor ->
      MemHouse.Accounts.Peer
      |> Ash.Query.filter(key == ^key)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)
    end)
  end
end
