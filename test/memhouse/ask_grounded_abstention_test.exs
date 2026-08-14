# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.AskGroundedAbstentionTest do
  @moduledoc """
  Pins the grounded outcomes of `Memory.ask/2` and its MCP wrapper.

  A confident answer is cited and not abstained; a low-confidence answer keeps
  its text and citations but abstains whatever the model claimed; an answer with
  no surviving retrieved citation is replaced by the empty abstention. The
  prompt is also pinned to instruct the model never to refuse, because a refusal
  is what the confidence percentage replaced. The tests use an offline provider
  whose invented ids exercise the same citation intersection used in production,
  and run synchronously because provider selection is node-global.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.DataLayer
  alias MemHouse.Governance.Actions.McpRead
  alias MemHouse.Governance.Engine, as: GovernanceEngine
  alias MemHouse.Identity
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Memory
  alias MemHouse.Model.GroundedAnswerProvider

  require Ash.Query

  @supported_answer "The recorded statements do not establish this, but they support a preference for concise weekly release summaries."
  @inferred_answer "Avery most likely prefers concise weekly release summaries."
  @no_evidence_answer "No memory statements were retrieved for this question."

  setup do
    original_provider = Application.get_env(:memhouse, :model_provider)

    on_exit(fn ->
      GroundedAnswerProvider.stop()

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    :ok
  end

  test "preserves cited answer text when the model marks the conclusion inconclusive" do
    bootstrap = bootstrap_human!("supported")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "supported")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    result = ask(actor, scope_path)

    assert result["answer"] == @supported_answer
    assert result["citations"] == [knowledge_id]
    assert result["abstained"]
    assert result["answer_confidence"] == 30

    assert [prompt] = GroundedAnswerProvider.prompts()

    assert prompt =~ "Write the answer and its citations before you estimate answer_confidence."
    assert prompt =~ "MemHouse handles an empty memory context without calling you."
    refute prompt =~ "Never reply \"not known\""

    assert prompt =~
             "infer the most probable one from the statements, use an explicit likelihood word"

    assert prompt =~
             "Cite every statement your answer rests on, including a low-confidence one."

    assert result["answer_context_count"] == 1
    assert result["answerer_prompt_tokens"] == 20
  end

  test "keeps a confident inference as a conclusion" do
    bootstrap = bootstrap_human!("confident")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "confident")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:confident_inference)

    result = ask(actor, scope_path)

    assert result["answer"] == @inferred_answer
    assert result["citations"] == [knowledge_id]
    assert result["answer_confidence"] == 80
    refute result["abstained"]
  end

  test "abstains on a low-confidence inference while keeping its text and citations" do
    bootstrap = bootstrap_human!("low-confidence")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "low-confidence")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:low_confidence_inference)

    result = ask(actor, scope_path)

    # The fixture claims a conclusion at 20. The answer survives as a lead, the
    # claim does not.
    assert result["answer"] == @inferred_answer
    assert result["citations"] == [knowledge_id]
    assert result["answer_confidence"] == 20
    assert result["abstained"]
  end

  test "reports a failed model call as degraded, not as a confident answer" do
    bootstrap = bootstrap_human!("degraded")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "degraded")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:provider_error)

    handler_id = attach_degraded_telemetry()

    result = ask(actor, scope_path)

    # A failed model call is not a low-confidence answer: the retrieved
    # statement never became a claim, so it must not be presented as one.
    refute result["answer"] == "Avery prefers concise weekly release summaries."
    assert result["abstained"]
    assert result["answer_confidence"] == 0
    assert result["answer_degraded"] == "provider_upstream_error"
    assert result["answer_context_count"] == 1
    assert result["answerer_prompt_tokens"] == nil

    # The statement is still there, as a citation and as plain text, just not
    # dressed up as a conclusion anyone reasoned to (memhousehq/memhouse#143).
    assert result["citations"] == [knowledge_id]
    assert result["supporting_statements"] == ["Avery prefers concise weekly release summaries."]

    assert_receive {^handler_id, measurements, metadata}
    assert metadata.error_class == "provider_upstream_error"
    assert metadata.account_id == actor.account_id
    assert is_integer(measurements.duration_ms)
    assert measurements.duration_ms >= 0

    :telemetry.detach(handler_id)
  end

  test "a confident answer never carries answer_degraded" do
    bootstrap = bootstrap_human!("not-degraded")
    {_knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "not-degraded")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:confident_inference)

    result = ask(actor, scope_path)

    assert result["answer_degraded"] == nil
  end

  test "does not present observation time as the claim's valid time" do
    bootstrap = bootstrap_human!("dated")

    {_knowledge_id, scope_path, _session_id} =
      seed_memory!(bootstrap.actor, "dated",
        content: "Avery ran the northbound migration on the weekend before the freeze.",
        occurred_at: "2023-07-17T14:31:00Z"
      )

    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    ask(actor, scope_path)

    assert [prompt] = GroundedAnswerProvider.prompts()
    refute prompt =~ "2023-07-17"
  end

  test "passes the caller reference time and states the validity rule once" do
    bootstrap = bootstrap_human!("reference-time")
    {_knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "reference-time")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    Memory.ask(
      %{
        "scope_path" => scope_path,
        "question" => "What did Avery prefer then?",
        "profile" => "balanced",
        "deadline" => "disabled",
        "as_of" => "2024-02-03T04:05:06Z"
      },
      actor
    )

    assert [prompt] = GroundedAnswerProvider.prompts()
    assert prompt =~ "Reference time: 2024-02-03T04:05:06Z."
    assert length(Regex.scan(~r/A statement may be followed by/, prompt)) == 1
  end

  test "answers over the bounded ranked head and returns the full candidate list" do
    bootstrap = bootstrap_human!("bounded-context")

    {first_id, scope_path, _session_id} =
      seed_memory!(bootstrap.actor, "bounded-context",
        content: "Avery prefers concise weekly release summaries."
      )

    {second_id, ^scope_path, _session_id} =
      seed_memory!(bootstrap.actor, "bounded-context",
        content: "Avery prefers concise weekly planning summaries."
      )

    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    retrieval_profiles = Application.fetch_env!(:memhouse, :retrieval_profiles)

    on_exit(fn -> Application.put_env(:memhouse, :retrieval_profiles, retrieval_profiles) end)

    Application.put_env(
      :memhouse,
      :retrieval_profiles,
      Keyword.put(retrieval_profiles, :answer_context_limit, 1)
    )

    result = ask(actor, scope_path)

    assert length(result["candidates"]) == 2
    assert result["answer_context_count"] == 1

    assert [prompt] = GroundedAnswerProvider.prompts()
    assert length(Regex.scan(~r/^\s*\[[^\]]+\]\s/m, prompt)) == 1
    first_present? = prompt =~ first_id
    second_present? = prompt =~ second_id
    assert first_present? != second_present?
  end

  test "strips invented citations and falls back only when none survive" do
    bootstrap = bootstrap_human!("intersection")
    {knowledge_id, scope_path, _session_id} = seed_memory!(bootstrap.actor, "intersection")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention_with_invented_citation)

    partially_grounded = ask(actor, scope_path)

    assert partially_grounded["answer"] == @supported_answer
    assert partially_grounded["citations"] == [knowledge_id]
    assert partially_grounded["abstained"]

    # Rearming replaces the fixture response and clears its prompt log. This
    # time every citation is invented and the provider claims a conclusion at
    # 90; empty grounding evidence still wins over that claim.
    use_answer_mode!(:unsupported_assertion)

    assert %{
             "answer" => @no_evidence_answer,
             "citations" => [],
             "abstained" => true,
             "answer_confidence" => 0
           } = ask(actor, scope_path)
  end

  test "does not call the dialectic model when retrieval returns no candidates" do
    bootstrap = bootstrap_human!("empty")
    scope_path = "/ask-grounding/empty"

    assert {:ok, _message} =
             Memory.ingest_message(
               %{
                 "session_id" => "ask-empty-session",
                 "scope_path" => scope_path,
                 "peer_key" => "ask-empty-peer",
                 "role" => "user",
                 "content" => "This raw observation has not been extracted.",
                 "sync_extract" => false
               },
               bootstrap.actor
             )

    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    assert %{
             "answer" => @no_evidence_answer,
             "citations" => [],
             "abstained" => true,
             "answer_confidence" => 0
           } = ask(actor, scope_path)

    assert GroundedAnswerProvider.prompts() == []
  end

  test "MCP ask preserves the cited abstention response shape" do
    bootstrap = bootstrap_human!("mcp")
    {knowledge_id, scope_path, session_id} = seed_memory!(bootstrap.actor, "mcp")
    {:ok, actor} = Identity.authenticate_bearer(bootstrap.token)
    use_answer_mode!(:grounded_abstention)

    input = %{
      arguments: %{
        session_id: session_id,
        scope_path: scope_path,
        question:
          "Does the record establish that Avery prefers concise weekly release summaries?",
        profile: "balanced"
      }
    }

    assert {:ok, result} = McpRead.run(input, [operation: :ask], %{actor: actor})
    assert result["answer"] == @supported_answer
    assert result["citations"] == [knowledge_id]
    assert result["abstained"]
    assert result["answer_confidence"] == 30
  end

  defp bootstrap_human!(suffix) do
    Identity.bootstrap_human(%{
      email: "ask-#{suffix}@example.test",
      name: "Ask #{suffix}",
      password: "correct horse battery staple"
    })
  end

  defp seed_memory!(actor, suffix, overrides \\ []) do
    scope_path = "/ask-grounding/#{suffix}"
    session_id = "ask-#{suffix}-session"

    assert {:ok, message} =
             Memory.ingest_message(
               Map.merge(
                 %{
                   "session_id" => session_id,
                   "scope_path" => scope_path,
                   "peer_key" => "ask-#{suffix}-peer",
                   "role" => "user",
                   "content" => "Avery prefers concise weekly release summaries."
                 },
                 Map.new(overrides, fn {key, value} -> {to_string(key), value} end)
               ),
               actor
             )

    assert {:ok, [knowledge]} =
             Memory.extract_message_for_account(message["id"], actor.account_id)

    knowledge_id = knowledge["id"]

    # The answering contract is independent of Gate timing. Activate the
    # fixture through the ordinary governance engine so every retrieval profile
    # can see it without relying on provisional subject visibility.
    DataLayer.with_account_id(
      actor.account_id,
      [role: :system, pipeline?: true],
      fn account, pipeline_actor ->
        knowledge =
          KnowledgeItem
          |> Ash.Query.filter(id == ^knowledge_id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read_one!(actor: pipeline_actor)

        GovernanceEngine.transition!(
          knowledge,
          pipeline_actor,
          %{state: "active", verification: "auto_verified"},
          reason: "ask_grounding_test_activate",
          channel: "pipeline"
        )
      end
    )

    {knowledge_id, scope_path, session_id}
  end

  defp use_answer_mode!(mode) do
    GroundedAnswerProvider.start!(mode)
    Application.put_env(:memhouse, :model_provider, GroundedAnswerProvider)
  end

  defp attach_degraded_telemetry do
    test_process = self()
    handler_id = {:ask_degraded_test, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:memhouse, :ask, :degraded],
        fn _event, measurements, metadata, _config ->
          send(test_process, {handler_id, measurements, metadata})
        end,
        nil
      )

    handler_id
  end

  defp ask(actor, scope_path) do
    Memory.ask(
      %{
        "scope_path" => scope_path,
        "question" =>
          "Does the record establish that Avery prefers concise weekly release summaries?",
        "profile" => "balanced",
        "deadline" => "disabled"
      },
      actor
    )
  end
end
