# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Extractor do
  @moduledoc """
  Turns one anchored observation and a bounded conversation window into candidate knowledge items.

  Builds the extraction prompt and returns schema-validated candidates. It writes nothing;
  persistence, merging, and governance remain pipeline responsibilities.

  ## What extraction constrains

  - **Bounded message windows.** Message extraction reads a small same-session
    window with one explicit anchor. Candidates cite only ids from that window.
  - **Subject is resolved independently of source.** Who spoke and who a claim
    is about are separate. A peer subject must be one of the supplied known peer
    keys and a scope subject must be the current scope path; the schema rejects
    anything else, so this is enforced rather than merely requested.
  - **Source evidence is derived.** The resolved source and subject produce a
    stable direct or indirect level; indirect claims receive the third-party
    confidence discount during validation.
  - **Declining is explicit.** A candidate emitted with the `no_op` operation is
    dropped here rather than becoming an empty statement that would later look
    like real knowledge.

  ## Failure behaviour

  Provider errors return unchanged. The observation remains unstamped for retry and reconciliation.
  There is no extractor fallback because it would falsify provenance.

  Nothing here activates knowledge. Every returned candidate is still a proposal
  that must pass governance before retrieval can see it.
  """

  alias MemHouse.Model
  alias MemHouse.Model.Schema.Extraction

  # Identity of the extraction-and-pipeline contract this build implements. The
  # same string is configured as every model role's `pipeline_version` — which
  # is what gets stamped onto knowledge, provenance rows, and usage events — and
  # is the version `GET /api/health` reports. Those copies must move together.
  #
  # Changing this string is a deliberate contract transition, not a tidy-up: it
  # obliges a maintainer to add a changelog entry and refresh the contract
  # regression evidence, because stored provenance and recorded evaluation
  # results are compared against it.
  @pipeline_version "f5-1"

  # Names the prompt text below, and is passed to the gateway as a call option.
  # The `prompt_version` actually stamped on provenance and usage rows comes
  # from the resolved `ingest_extractor` role, not from here; the two are kept
  # equal on purpose, so editing the prompt means bumping both.
  @prompt_version "extract-6"

  @doc """
  The identity of the extraction-and-pipeline contract this build implements.
  """
  def pipeline_version, do: @pipeline_version

  @doc """
  The identity of the prompt wording currently used for extraction.
  """
  def prompt_version, do: @prompt_version

  @doc """
  Extracts candidate knowledge from one raw observation.

  `message` is a string-keyed map of the raw observation. It must carry
  `"content"`, `"peer_key"` (who produced the observation) and `"scope_path"`
  (where it was said); `"known_peer_keys"` bounds which peers a statement may be
  about. `context` supplies the surrounding identifiers — Account, scope, source
  peer, and the message or document version id — which are used for validation
  and provenance rather than being shown to the model.

  Returns `{:ok, candidates}`, where each candidate is the validated schema
  value merged with the provider, model, and version provenance that produced
  it. Candidates the model declined (`no_op`) are already removed, so an empty
  list means "this observation contains no durable memory", not a failure.

  Returns the generator's `{:error, reason}` unchanged: a provider transport or
  credential failure, or `{:error, {:structured_validation_failed, errors}}`
  when the model could not produce schema-valid output within the repair
  budget. Either way the caller can leave the observation unprocessed and let
  the durable job retry.

  Raises `KeyError` when the observation is missing `"content"`, `"peer_key"`,
  or `"scope_path"` — those are required by the caller that assembled it, and a
  missing one means the observation was built incorrectly rather than that the
  content was unusable.
  """
  def extract(message, context \\ %{}) do
    schema_context = schema_context(message, context)

    messages = [
      %{
        role: "system",
        content: """
        Extract durable agent-memory knowledge from an anchored observation and
        its bounded conversation window. Return the supplied structured schema.
        Natural-language statements are the knowledge atom.

        Durable memory is a fact that remains useful after this conversation:
        a stable fact, preference, relationship, possession, skill,
        commitment, plan, or event with a lasting consequence. Keep a specific
        claim such as "Avery prefers weekly release summaries." Keep a promise
        as "Avery will send the release notes by 2026-08-15.", not as a record
        that Avery spoke.

        Return no item when the content has no durable claim. Drop greetings,
        thanks, compliments, reactions, encouragement, small talk, questions,
        invitations without an asserted fact, and messages whose only fact is
        that somebody sent or received a message. For example, drop "Thanks,
        that helped!", "What are Avery's pets' names?", and "Avery greeted
        Melanie." A mix of durable and non-durable content may produce one or
        more items; entirely non-durable content must produce an empty items
        array.

        State what is true. Never frame a candidate as a speech act or
        transcription such as "Avery said ...", "Avery asked ...", or a quoted
        message. A statement about a peer must name that peer directly. Do not
        invent facts.

        Start each candidate with concise reasoning, then its natural-language
        statement, then confidence_percentage. Rate your confidence percentage
        on an integer scale from 1 to 100 (where 1 is completely uncertain and
        100 is absolute certainty). Resolve subject independently from source. A peer subject_ref must be
        one of the supplied known peer keys. Use the current scope path only for
        a scope subject. Each candidate must cite source_message_ids drawn only
        from the supplied conversation window. The source-to-subject relationship is derived by
        MemHouse. Propose sensitivity and the independent
        expiry, revalidation, and relevant-window timestamps. Use no_op by
        omitting the candidate rather than emitting an empty statement.

        The observation carries the time it was made. Resolve every relative
        date against that time — "last weekend", "yesterday", "next month" —
        and write the absolute date into the statement itself, because a reader
        of the statement alone has no other clock.

        Use kind "event" for anything that happened at a point or over a span of
        time, whatever else it also asserts. Give an event relevant_from, and
        relevant_until as well when it spans more than an instant. Leave the
        relevant window empty for a statement with no time of its own.
        """
      },
      %{
        role: "user",
        content: """
        Source peer key: #{schema_context.source_peer_key}
        Source role: #{Map.get(message, "role", "user")}
        Current scope: #{schema_context.scope_path}
        Known peer keys: #{Enum.join(schema_context.known_peer_keys, ", ")}
        Observed at: #{observed_at(schema_context.occurred_at)}

        Anchored observation:
        #{Map.fetch!(message, "content")}

        Conversation window (id | speaker | observed at | text):
        #{window_text(schema_context.window_messages, schema_context.occurred_at)}
        """
      }
    ]

    # `observation` hands the raw text to the gateway as a call option; the
    # deterministic local provider reads it instead of re-parsing the prompt.
    # It travels no further: gateway options are not persisted, and observation
    # text must never reach usage records, telemetry, or job arguments.
    opts = [
      task: :extraction,
      source_peer_key: schema_context.source_peer_key,
      observation: Map.fetch!(message, "content"),
      source_message_ids: [schema_context.message_id],
      prompt_version: @prompt_version
    ]

    case Model.generate_structured(
           :ingest_extractor,
           messages,
           Extraction,
           schema_context,
           opts
         ) do
      {:ok, items, provenance} ->
        # Declined candidates are dropped here rather than downstream, so an
        # explicit "nothing to record" never reaches the writer as a row. Every
        # surviving candidate carries the provider/model/version provenance of
        # the call that produced it.
        {:ok,
         items
         |> Enum.reject(&(&1.update_operation == "no_op"))
         |> Enum.map(&Map.merge(&1, provenance))}

      {:error, error} ->
        {:error, error}
    end
  end

  # Second precision: no observation is dated more finely than that in practice,
  # and stored microseconds would only spend prompt tokens on digits the model
  # cannot use.
  defp observed_at(%DateTime{} = occurred_at) do
    occurred_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  # Assembles the validation context the schema uses to police the model's
  # output. The generated ids in the `put_new` fallbacks only ever apply to
  # standalone callers that pass no context (tooling and tests); the pipeline
  # always supplies the real Account, scope, and peer.
  #
  # The source peer key is appended to the known-peer list unconditionally: a
  # speaker must always be nameable as a subject of their own statement, even if
  # the caller forgot to include them.
  defp schema_context(message, context) do
    source_peer_key = Map.fetch!(message, "peer_key")

    context
    |> Map.put_new(:account_id, Map.get(message, "account_id", Ecto.UUID.generate()))
    |> Map.put_new(:scope_id, Map.get(message, "scope_id", Ecto.UUID.generate()))
    |> Map.put_new(:source_peer_id, Map.get(message, "peer_id", Ecto.UUID.generate()))
    |> Map.put_new(:message_id, Map.get(message, "id"))
    |> Map.put(:source_peer_key, source_peer_key)
    |> Map.put(:scope_path, Map.fetch!(message, "scope_path"))
    |> Map.put(:window_messages, Map.get(context, :window_messages, [message]))
    |> Map.put(
      :window_message_ids,
      Map.get(context, :window_message_ids, List.wrap(Map.get(message, "id")))
    )
    # Falls back to now only for a standalone caller that assembled an
    # observation without one. Both pipeline paths always carry a stored time.
    |> Map.put(:occurred_at, Map.get(message, "occurred_at") || MemHouse.Clock.utc_now())
    |> Map.put(
      :known_peer_keys,
      message
      |> Map.get("known_peer_keys", [source_peer_key])
      |> Kernel.++([source_peer_key])
      |> Enum.uniq()
    )
  end

  defp window_text(messages, fallback_occurred_at) do
    Enum.map_join(messages, "\n", fn window_message ->
      occurred_at = window_message["occurred_at"] || fallback_occurred_at

      "#{window_message["id"]} | #{window_message["peer_key"]} | #{observed_at(occurred_at)} | #{window_message["content"]}"
    end)
  end
end
