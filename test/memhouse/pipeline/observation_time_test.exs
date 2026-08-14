# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.ObservationTimeTest do
  @moduledoc """
  Covers the belief-time a caller asserts on an observation, from the ingest
  body to the extraction prompt and its separation from valid time.

  A conversational corpus is almost always backfilled: the turn happened months
  before it was ingested. Every "when did X happen" answer depends on this chain
  holding, and each link failed independently before these tests existed — a
  naive ISO 8601 timestamp was silently replaced with the ingest wall clock, the
  extractor was never shown a clock at all, and a dated occurrence stored no
  `relevant_from`. A statement like "last weekend" is then unanchored, and a
  reader resolves it against whatever date it happens to hold.

  Runs with `async: false` because most tests install a global model provider.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.Memory
  alias MemHouse.Model.PromptCaptureProvider

  # 17 July 2023, the kind of date a backfilled transcript carries: long before
  # any plausible ingest time, so a wall-clock substitution cannot pass by luck.
  @observed_at ~U[2023-07-17 14:31:00Z]

  describe "ingest belief-time" do
    test "keeps an offset-bearing ISO 8601 occurred_at" do
      assert {:ok, message} =
               Memory.ingest_message(
                 ingest_attrs("obs-offset", occurred_at: "2023-07-17T14:31:00Z")
               )

      assert DateTime.compare(message["occurred_at"], @observed_at) == :eq
    end

    test "reads an ISO 8601 occurred_at without an offset as UTC" do
      # A naive timestamp is what a client emits by default — Python's
      # `datetime.isoformat()` on a zoneless value produces it. Rejecting it
      # backdated nothing and forward-dated every turn to the ingest instant.
      assert {:ok, message} =
               Memory.ingest_message(
                 ingest_attrs("obs-naive", occurred_at: "2023-07-17T14:31:00")
               )

      assert DateTime.compare(message["occurred_at"], @observed_at) == :eq
    end

    test "falls back to now when occurred_at cannot be parsed at all" do
      before = DateTime.utc_now()

      assert {:ok, message} =
               Memory.ingest_message(ingest_attrs("obs-garbage", occurred_at: "last tuesday"))

      assert DateTime.compare(message["occurred_at"], before) in [:eq, :gt]
    end
  end

  describe "extraction prompt" do
    setup :capture_prompts

    test "shows the model when the observation was made" do
      Memory.extract_message(seed_message!("obs-prompt"))

      assert user_prompt() =~ "2023-07-17T14:31:00Z"
    end

    test "puts resolved relative dates in the valid-time fields, not the statement frame" do
      Memory.extract_message(seed_message!("obs-relative"))

      prompt = system_prompt()

      assert prompt =~ "Resolve every relative"
      assert prompt =~ "relevant_from and relevant_until"
      assert prompt =~ "not as a dated utterance or observation frame"
      assert prompt =~ "ISO YYYY-MM-DD"
    end

    test "classifies by durable meaning and keeps valid time independent" do
      Memory.extract_message(seed_message!("obs-taxonomy"))

      prompt = system_prompt()

      assert prompt =~ "Use event only when the claim's"
      assert prompt =~ "whole durable content is that something occurred"
      assert prompt =~ "Avery prefers concise"
      assert prompt =~ ~s(status updates." is preference)
      assert prompt =~ ~s("Avery mentors Sam." is relation)
      assert prompt =~ ~s("Avery can administer PostgreSQL." is skill)
      assert prompt =~ "Valid time is independent of kind"
      refute prompt =~ "whatever else it also asserts"
    end
  end

  describe "valid time" do
    setup :capture_prompts

    test "does not turn observation time into an event validity window" do
      assert {:ok, [knowledge]} =
               Memory.extract_message(
                 seed_message!("obs-anchor",
                   statement: "Caroline joined a mentorship program."
                 )
               )

      assert knowledge["kind"] == "event"
      assert knowledge["relevant_from"] == nil
      assert knowledge["expires_at"] == nil
    end

    test "keeps a relevant_from the model supplied" do
      supplied = ~U[2023-07-15 00:00:00Z]

      message = seed_message!("obs-supplied", relevant_from: DateTime.to_iso8601(supplied))

      assert {:ok, [knowledge]} = Memory.extract_message(message)
      assert DateTime.compare(knowledge["relevant_from"], supplied) == :eq
    end

    test "keeps a relevant_until the model supplied, so an event may span days" do
      until = ~U[2023-07-16 23:59:59Z]

      message = seed_message!("obs-span", relevant_until: DateTime.to_iso8601(until))

      assert {:ok, [knowledge]} = Memory.extract_message(message)
      assert DateTime.compare(knowledge["relevant_until"], until) == :eq
    end

    test "leaves a non-event statement undated" do
      message = seed_message!("obs-preference", kind: "preference")

      assert {:ok, [knowledge]} = Memory.extract_message(message)

      assert knowledge["kind"] == "preference"
      assert knowledge["relevant_from"] == nil
    end
  end

  describe "the resource keeps belief time and valid time independent" do
    test "an event without a known validity window is valid" do
      assert create_changeset(kind: "event").valid?
    end

    test "observation time does not become relevant_from" do
      changeset = create_changeset(kind: "event", observed_at: @observed_at)

      assert changeset.valid?
      assert Ash.Changeset.get_attribute(changeset, :relevant_from) == nil
    end

    test "a non-event needs no window" do
      assert create_changeset(kind: "fact").valid?
    end
  end

  # Builds an unsaved `create_from_pipeline` changeset carrying only what the
  # action requires, so a validity assertion is about the field under test.
  defp create_changeset(overrides) do
    attrs =
      %{
        scope_id: Ecto.UUID.generate(),
        subject_peer_id: Ecto.UUID.generate(),
        statement: "Caroline joined a mentorship program.",
        confidence: 0.8,
        sensitivity: "public",
        state: "proposed",
        target_level: "peer",
        extracting_provider: "test",
        extracting_model: "test",
        extracting_model_version: "test",
        prompt_version: "test",
        pipeline_version: "f5-1"
      }
      |> Map.merge(Map.new(overrides))

    MemHouse.Knowledge.KnowledgeItem
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(Ecto.UUID.generate())
    |> Ash.Changeset.for_create(:create_from_pipeline, attrs)
  end

  # Installs the capturing provider for one test, so the prompt the pipeline
  # builds is observable and the candidate it extracts is fixed.
  defp capture_prompts(_context) do
    original = Application.get_env(:memhouse, :model_provider)
    Application.put_env(:memhouse, :model_provider, PromptCaptureProvider)

    on_exit(fn ->
      PromptCaptureProvider.stop()

      if original,
        do: Application.put_env(:memhouse, :model_provider, original),
        else: Application.delete_env(:memhouse, :model_provider)
    end)

    :ok
  end

  defp system_prompt, do: prompt_content("system")
  defp user_prompt, do: prompt_content("user")

  defp prompt_content(role) do
    assert [messages] = PromptCaptureProvider.messages()
    Enum.find_value(messages, "", &if(&1.role == role, do: &1.content))
  end

  # Ingests one dated observation and arms the provider to answer its extraction
  # with exactly one candidate. Overrides vary the single field a test is about;
  # everything else stays fixed so no assertion rests on an unrelated default.
  defp seed_message!(account_key, overrides \\ []) do
    {:ok, message} =
      Memory.ingest_message(
        ingest_attrs(account_key, occurred_at: DateTime.to_iso8601(@observed_at))
      )

    PromptCaptureProvider.start!([candidate(account_key, overrides)])

    message["id"]
  end

  defp candidate(account_key, overrides) do
    %{
      "supporting_span" => "Last weekend I joined a mentorship program for LGBTQ youth.",
      "statement" => "Caroline joined a mentorship program last weekend.",
      "kind" => "event",
      "subject_type" => "peer",
      "subject_ref" => "#{account_key}-peer",
      "confidence_level" => "clearly_implied",
      "sensitivity" => "public",
      "target_level" => "peer",
      "relevant_from" => nil,
      "relevant_until" => nil
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  defp ingest_attrs(account_key, overrides) do
    %{
      "account_key" => account_key,
      "session_id" => "#{account_key}-session",
      "scope_path" => "/observation-time/#{account_key}",
      "peer_key" => "#{account_key}-peer",
      "role" => "user",
      "content" => "Last weekend I joined a mentorship program for LGBTQ youth."
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end
end
