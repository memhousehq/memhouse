# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Providers.Deterministic do
  @moduledoc """
  An offline stand-in that produces schema-valid output without a model.

  Supports deterministic end-to-end tests and offline development without network, keys, or cost.

  ## This is not a model, and must not be mistaken for one

  Extraction uses sentence splitting and keyword guesses; reasoning is empty; answers abstain as
  `"not known"`.

  Every result is tagged `fallback: true` in metadata, which reaches the usage
  ledger, so it is always visible after the fact which calls were served by this
  adapter.

  ## Selection rules

  Selection is explicit and production defaults it off. Live provider failures never fall back
  here; they remain retryable errors.

  Callers that would display generated text should ask whether the role resolved
  to this provider and take a grounded, non-model path instead.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result

  @doc """
  Returns schema-shaped output for the task named by `opts[:task]`.

  Recognizes `:extraction`, `:reasoning`, and `:dialectic`. Any other task gets
  an empty object, and what happens next is the caller's business: a schema
  module's `cast/2` rejects it, while a caller reading one key straight off a
  `MemHouse.Model.Gateway.structured_once/5` result just sees that key absent.
  The dialectic branch always abstains rather than answering, because this
  adapter has no basis on which to answer anything.
  """
  @impl true
  def structured(_config, messages, _schema, opts) do
    value =
      case Keyword.get(opts, :task) do
        :extraction ->
          %{"items" => extraction_items(messages, opts)}

        :compact_extraction ->
          %{"items" => compact_extraction_items(messages, opts)}

        :extraction_batch ->
          %{
            "anchors" =>
              Enum.map(Keyword.get(opts, :batch_observations, []), fn observation ->
                anchor_opts =
                  opts
                  |> Keyword.put(:observation, observation.observation)
                  |> Keyword.put(:source_peer_key, observation.source_peer_key)
                  |> Keyword.put(:source_message_ids, observation.source_message_ids)

                %{
                  "anchor_id" => observation.anchor_id,
                  "items" => extraction_items(messages, anchor_opts)
                }
              end)
          }

        :compact_extraction_batch ->
          %{
            "anchors" =>
              Enum.map(Keyword.get(opts, :batch_observations, []), fn observation ->
                anchor_opts =
                  opts
                  |> Keyword.put(:observation, observation.observation)
                  |> Keyword.put(:source_peer_key, observation.source_peer_key)
                  |> Keyword.put(:source_message_ids, observation.source_message_ids)

                %{
                  "anchor_id" => observation.anchor_id,
                  "items" => compact_extraction_items(messages, anchor_opts)
                }
              end)
          }

        :reasoning ->
          %{"items" => [], "relations" => []}

        :dialectic ->
          %{
            "answer" => "not known",
            "citations" => [],
            "abstained" => true,
            "answer_confidence" => 0
          }

        _other ->
          %{}
      end

    {:ok, %Result{value: value, metadata: %{fallback: true}}}
  end

  @doc """
  Always answers `"not known"`. Saying nothing useful is the honest response
  from an adapter that ran no model.
  """
  @impl true
  def chat(_config, _messages, _opts),
    do: {:ok, %Result{value: "not known", metadata: %{fallback: true}}}

  @doc """
  Always an error: this adapter must never produce vectors.

  A fake embedding would be indistinguishable from a real one once stored, and
  would silently poison every similarity comparison in the corpus with no way to
  tell afterwards which vectors were meaningless. Refusing is the only safe
  behaviour, so an offline deployment uses the local ONNX embedder instead.
  """
  @impl true
  def embed(_config, _texts, _opts),
    do: {:error, :deterministic_embeddings_are_not_an_architectural_embedder}

  @doc """
  Returns the documents in their original order with decaying scores.

  Reranking only reorders candidates that retrieval already selected, so a
  no-op ordering degrades quality without inventing anything — unlike a fake
  embedding, this cannot contaminate stored data.
  """
  @impl true
  def rerank(_config, _query, documents, _opts) do
    ranked =
      documents
      |> Enum.with_index()
      |> Enum.map(fn {document, index} ->
        %{index: index, relevance_score: 1.0 / (index + 1), document: document}
      end)

    {:ok, %Result{value: ranked, metadata: %{fallback: true}}}
  end

  # Sentence-splits the observation and calls each sentence a candidate. This is
  # a stand-in for extraction, not extraction: it understands nothing.
  #
  # The candidates it emits are still ordinary proposals — they carry a modest
  # inferred confidence, are attributed to the speaking peer, and go through the
  # same validation and governance as anything a real model produces. Nothing
  # here can shortcut a gate.
  defp extraction_items(messages, opts) do
    messages
    |> candidate_sentences(opts)
    |> Enum.map(&full_candidate(&1, opts))
  end

  defp compact_extraction_items(messages, opts) do
    messages
    |> candidate_sentences(opts)
    |> Enum.map(&compact_candidate(&1, opts))
  end

  defp candidate_sentences(messages, opts) do
    content = Keyword.get(opts, :observation) || last_user_content(messages)

    content
    # Split after sentence-ending punctuation or on line breaks.
    |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
    |> Enum.map(&String.trim/1)
    # Under 12 characters is almost always a greeting or a fragment, not a
    # durable claim worth proposing.
    |> Enum.reject(
      &(String.length(&1) < 12 or non_durable_conversation?(&1) or subjectless_generic?(&1))
    )
    # At most 6 candidates per observation, keeping offline runs cheap and their
    # output small enough to assert on in tests.
    |> Enum.take(6)
  end

  defp full_candidate(statement, opts) do
    %{
      "supporting_span" => statement,
      "statement" => statement,
      "kind" => infer_kind(statement),
      "subject_type" => "peer",
      "subject_ref" => Keyword.get(opts, :source_peer_key),
      "source_message_ids" => Keyword.get(opts, :source_message_ids, []),
      "confidence_level" => "inferred",
      "sensitivity" => infer_sensitivity(statement),
      "target_level" => "peer",
      "relevant_from" => nil,
      "relevant_until" => nil
    }
  end

  defp compact_candidate(statement, opts) do
    %{
      "supporting_span" => statement,
      "statement" => statement,
      "subject_ref" => Keyword.get(opts, :source_peer_key),
      "source_message_ids" => Keyword.get(opts, :source_message_ids, []),
      "relevant_from_evidence" => nil,
      "relevant_until_evidence" => nil
    }
  end

  defp non_durable_conversation?(statement) do
    String.ends_with?(statement, "?") or
      String.match?(statement, ~r/^(hi|hello|hey|thanks|thank you|great job|nice work)\b/i)
  end

  # A peer key can be an opaque identity, so this local adapter cannot require
  # it to occur in natural language. It still declines common generic
  # leading-gerund claims that have no named subject.
  defp subjectless_generic?(statement) do
    String.match?(statement, ~r/\A(?:Running|Exercise|Sleep|Travel|Work)\s+(?:can|is|does)\b/u)
  end

  # Falls back to the most recent user turn when the caller did not pass the
  # observation explicitly. Handles both atom and string message keys because
  # test fixtures and real callers disagree about which they use. Returns an
  # empty string rather than nil so the split below always has something to work
  # on.
  defp last_user_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn message ->
      role = Map.get(message, :role) || Map.get(message, "role")
      content = Map.get(message, :content) || Map.get(message, "content")
      if role in [:user, "user"] and is_binary(content), do: content
    end)
  end

  # Keyword guesses, nothing more. Wrong often; the point is only that offline
  # runs produce a plausible spread of kinds rather than one uniform value.
  defp infer_kind(statement) do
    cond do
      String.match?(statement, ~r/\b(prefers|likes|wants|needs|favorite)\b/i) ->
        "preference"

      String.match?(statement, ~r/\b(on|at|by|before|after|yesterday|today|tomorrow)\b/i) ->
        "event"

      true ->
        "fact"
    end
  end

  # Errs toward the more restrictive label: anything mentioning contact,
  # health, or pay is called personal, and everything else is internal rather
  # than public. A too-cautious guess costs a curator one decision; a too-loose
  # one exposes something it should not.
  defp infer_sensitivity(statement) do
    if String.match?(statement, ~r/\b(email|phone|address|health|medical|salary|ssn)\b/i) do
      "personal"
    else
      "internal"
    end
  end
end
