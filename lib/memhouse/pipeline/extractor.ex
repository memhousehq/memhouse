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
  - **Declining emits no candidate.** An empty candidate cannot later look like
    real knowledge.

  ## Failure behaviour

  Provider errors return unchanged. The observation remains unstamped for retry and reconciliation.
  There is no extractor fallback because it would falsify provenance.

  Nothing here activates knowledge. Every returned candidate is still a proposal
  that must pass governance before retrieval can see it.
  """

  alias MemHouse.Model
  alias MemHouse.Model.Schema.CompactExtraction
  alias MemHouse.Model.Schema.CompactExtractionBatch
  alias MemHouse.Model.Schema.Extraction
  alias MemHouse.Model.Schema.ExtractionBatch
  alias MemHouse.Pipeline.ExtractionAdmission

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
  @current_prompt_version "extract-14"

  # Ways a model names the process instead of a person. Deployment-specific
  # identities are added per observation; these hold everywhere.
  @generic_machine_referents ["the assistant", "the agent", "the ai", "the chatbot", "the bot"]

  @doc """
  The identity of the extraction-and-pipeline contract this build implements.
  """
  def pipeline_version, do: @pipeline_version

  @doc """
  The identity of the prompt wording currently used for extraction.
  """
  def prompt_version, do: extraction_contract().prompt_version

  @doc """
  Returns the selected extraction experiment contract.

  Compact extraction is an explicit, deployment-wide evaluation switch. The
  accepted `extract-14` contract remains the default. Its configured model role
  prompt must match the selected version, so a partial rollout fails before a
  provider call instead of stamping misleading provenance.
  """
  def extraction_contract do
    config = Application.get_env(:memhouse, :compact_extraction, [])
    enabled = Keyword.get(config, :enabled, false)

    case enabled do
      false ->
        %{
          mode: :current,
          experiment_identity: nil,
          prompt_version: @current_prompt_version,
          schema: Extraction,
          batch_schema: ExtractionBatch
        }

      true ->
        %{
          mode: :compact,
          experiment_identity: Keyword.fetch!(config, :experiment_identity),
          prompt_version: Keyword.fetch!(config, :prompt_version),
          schema: CompactExtraction,
          batch_schema: CompactExtractionBatch
        }

      invalid ->
        raise ArgumentError,
              ":compact_extraction :enabled must be a boolean, got: #{inspect(invalid)}"
    end
  end

  @doc """
  Returns the batch response schema selected by the current extraction contract.

  Admission and generation must call this through the same runtime contract so
  a compact-extraction experiment cannot budget one schema and validate another.
  """
  def batch_schema, do: extraction_contract().batch_schema

  @doc """
  Adds the selected extraction experiment to a request admission identity.

  The accepted extractor leaves `base_identity` unchanged. Experimental
  contracts append their stable identity so persisted outcomes remain
  distinguishable without storing prompts or observation content.
  """
  def admission_identity(base_identity) when is_binary(base_identity) do
    case extraction_contract().experiment_identity do
      nil -> base_identity
      experiment_identity -> base_identity <> ":extractor=" <> experiment_identity
    end
  end

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
  it. Candidates the model declined are omitted from the items array, so an
  empty list means "this observation contains no durable memory", not a failure.

  Returns the generator's `{:error, reason}` unchanged: a provider transport or
  credential failure, or `{:error, {:structured_validation_failed, errors}}`
  when the model could not produce schema-valid output within the repair
  budget. Returns `{:error, {:prompt_version_mismatch, details}}` before a model
  call when the Account's active extractor role names another prompt version.
  In each case the caller can leave the observation unprocessed for operator
  repair and retry.

  Raises `KeyError` when the observation is missing `"content"`, `"peer_key"`,
  or `"scope_path"` — those are required by the caller that assembled it, and a
  missing one means the observation was built incorrectly rather than that the
  content was unusable.
  """
  def extract(message, context \\ %{}) do
    contract = extraction_contract()
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

        An observation may be relayed by an agent that was not part of the
        conversation. The agent is never a subject and must never appear in a
        statement. Never write "the assistant", "the agent", or a relaying
        identity as the person a claim is about.

        Start each candidate by copying the shortest exact supporting_span
        from a source message that entails the claim. A question supports only
        that the question was asked; it never supports an answer. Then write
        the natural-language statement and confidence_level. Rate the statement as
        stated_explicitly, clearly_implied, or inferred. Resolve subject independently from source. For a first-person claim,
        use the Speaker peer key as subject_ref; never use "I", "me", or a
        display name. Every peer subject_ref must exactly copy one of the
        supplied Conversation participant keys. Use the current scope path only
        for a scope subject. Each candidate must cite source_message_ids drawn only
        from the supplied conversation window. The source-to-subject relationship is derived by
        MemHouse. Propose sensitivity and source-grounded relevant-window
        timestamps. Expiry is governance policy and is not part of extraction.
        Decline by omitting the
        candidate rather than emitting an empty statement.

        The observation carries the time it was made. Resolve every relative
        date against that time. Supported forms are yesterday, today, tonight,
        tomorrow, and a number of days, weeks, months, or years ago or from now.
        Record the result in relevant_from and relevant_until. Leave each
        field null when the source does not state or imply that boundary. Write the
        statement as the claim, not as a dated utterance or observation frame.
        Keep an ISO YYYY-MM-DD date in the statement only when the date itself
        is part of the claim.

        An elapsed possession or relationship duration can imply the event that
        started the duration. For example, "I have had X for about N months"
        means that the speaker obtained X about N months before the observation.
        Extract the event that started the duration. Set kind to event, resolve
        relevant_from against the observation time, and leave relevant_until
        null. Keep approximate wording approximate: choose a date within the
        implied calendar period, but do not claim exact day precision in the
        statement. Store the start event, not the elapsed duration as a timeless
        fact.

        Classify a claim by what remains useful after the moment passes. Use
        fact for stable information, preference for a choice, relation for a
        connection, and skill for an ability. Use event only when the claim's
        whole durable content is that something occurred. Apply this precedence
        even when the source stated the claim at a specific time.

        Examples: "Avery works at Northstar." is fact. "Avery prefers concise
        status updates." is preference. "Avery mentors Sam." is relation.
        "Avery can administer PostgreSQL." is skill. "Avery launched Northstar
        on 2026-08-12." is event.

        Valid time is independent of kind. Set relevant_from and relevant_until
        only when the source states or implies that the claim has a time or
        span. Set relevant_until only when the source says when the claim
        stopped being true. Leave the fields empty when the source gives no
        boundary. Do not invent a validity window from the observation time,
        and never emit equal relevant_from and relevant_until values.
        """
      },
      %{
        role: "user",
        content: """
        Speaker peer key: #{schema_context.source_peer_key}
        Speaker role: #{Map.get(message, "role", "user")}
        Current scope: #{schema_context.scope_path}
        Conversation participants: #{Enum.join(schema_context.known_peer_keys, ", ")}
        Observed at: #{observed_at(schema_context.occurred_at)}

        Anchored observation:
        #{Map.fetch!(message, "content")}

        Conversation window (id | speaker | observed at | text):
        #{window_text(schema_context.window_messages, schema_context.occurred_at)}
        """
      }
    ]

    messages =
      if contract.mode == :compact do
        List.replace_at(messages, 0, %{role: "system", content: compact_system_prompt()})
      else
        messages
      end

    # `observation` hands the raw text to the gateway as a call option; the
    # deterministic local provider reads it instead of re-parsing the prompt.
    # It travels no further: gateway options are not persisted, and observation
    # text must never reach usage records, telemetry, or job arguments.
    opts = [
      task: if(contract.mode == :compact, do: :compact_extraction, else: :extraction),
      source_peer_key: schema_context.source_peer_key,
      observation: Map.fetch!(message, "content"),
      source_message_ids: [schema_context.message_id],
      prompt_version: contract.prompt_version
    ]

    case Model.generate_structured(
           :ingest_extractor,
           messages,
           contract.schema,
           schema_context,
           opts
         ) do
      {:ok, items, provenance} ->
        {:ok, Enum.map(items, &Map.merge(&1, provenance))}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Extracts several adjacent anchored observations in one provider call.

  Every entry is `%{message: message, context: context}`. The provider must
  return one envelope per message with an explicit `anchor_id`; candidate source
  ids are still checked against that anchor's ordinary bounded window. The
  return keeps per-anchor success or terminal structured-validation state so a
  caller can commit siblings independently.

  Whole-call provider failures are returned unchanged. A request that fails
  deterministic pre-call context admission returns
  `{:error, {:repairable, :oversized, details}}` without invoking a provider.
  """
  def extract_batch(anchors) when is_list(anchors) and anchors != [] do
    case extract_batch_with_attempts(anchors) do
      {:ok, results, _provider_attempts} -> {:ok, results}
      {:error, error, _provider_attempts} -> {:error, error}
    end
  end

  @doc """
  Extracts a batch and includes exact provider-attempt accounting.

  Returns `{:ok, results, provider_attempts}` or
  `{:error, reason, provider_attempts}`. Deterministic context admission returns
  zero; an admitted structured request counts each provider callback across the
  bounded repair loop. `extract_batch/1` preserves the established two-tuple
  public result by dropping only the accounting value.
  """
  def extract_batch_with_attempts(anchors) when is_list(anchors) and anchors != [] do
    contract = extraction_contract()
    {messages, context, opts} = batch_request(anchors, contract)
    schema = contract.batch_schema

    case ExtractionAdmission.admit(messages, schema.json_schema()) do
      {:ok, admission} ->
        case Model.generate_structured_with_attempts(
               :ingest_extractor,
               messages,
               schema,
               context,
               opts
             ) do
          {:ok, results, provenance, provider_attempts} ->
            results =
              Enum.map(results, fn
                %{status: :ok, items: items} = result ->
                  result
                  |> Map.put(:items, Enum.map(items, &Map.merge(&1, provenance)))
                  |> Map.put(:admission_identity, admission_identity(admission.identity))

                result ->
                  Map.put(result, :admission_identity, admission_identity(admission.identity))
              end)

            {:ok, results, provider_attempts}

          {:error, error, provider_attempts} ->
            {:error, error, provider_attempts}
        end

      {:error, details} ->
        {:error, {:repairable, :oversized, details}, 0}
    end
  end

  @doc """
  Builds the provider request, schema context, and bounded options for a batch.

  This is the shared preparation seam used by admission and the actual provider
  call. It returns `{messages, context, opts}`; `opts` carries one content-bound
  observation descriptor per anchor so the response schema can enforce exact
  ownership and provenance.
  """
  def batch_request(anchors) when is_list(anchors) and anchors != [] do
    batch_request(anchors, extraction_contract())
  end

  defp batch_request(anchors, contract) do
    prepared =
      Enum.map(anchors, fn %{message: message, context: context} ->
        schema_context = schema_context(message, context)
        %{message: message, context: schema_context}
      end)

    anchor_contexts = Map.new(prepared, &{&1.message["id"], &1.context})

    messages = [
      %{
        role: "system",
        content:
          if(contract.mode == :compact,
            do: compact_batch_system_prompt(),
            else: batch_system_prompt()
          )
      },
      %{
        role: "user",
        content:
          "Extraction anchors. Return one envelope per anchor.\n\n" <>
            Enum.map_join(prepared, "\n\n", &batch_anchor_text/1)
      }
    ]

    context =
      prepared
      |> hd()
      |> Map.fetch!(:context)
      |> Map.put(:anchor_contexts, anchor_contexts)

    observations =
      Enum.map(prepared, fn %{message: message, context: schema_context} ->
        %{
          anchor_id: message["id"],
          observation: message["content"],
          source_peer_key: schema_context.source_peer_key,
          source_message_ids: [message["id"]]
        }
      end)

    opts = [
      task:
        if(contract.mode == :compact,
          do: :compact_extraction_batch,
          else: :extraction_batch
        ),
      batch_observations: observations,
      prompt_version: contract.prompt_version
    ]

    {messages, context, opts}
  end

  defp batch_system_prompt do
    """
    Extract durable, explicit, atomic agent-memory knowledge from multiple
    anchored observations. Return one envelope for every supplied anchor and
    copy its exact Anchor id into anchor_id. Keep candidates for different
    anchors separate.

    For every candidate copy the shortest exact supporting_span, cite only
    source_message_ids from that anchor's supplied conversation window, name
    the human or scope subject explicitly, and never invent facts. Questions,
    greetings, thanks, reactions, speech-act transcripts, and claims about the
    relaying assistant produce no item. Resolve first-person evidence to its
    source speaker. The relaying agent is never a subject.

    Preserve stable facts, preferences, relationships, possessions, skills,
    commitments, plans, and lasting events. Classify sensitivity conservatively;
    restricted is the safe choice when evidence is ambiguous. Use only the
    supplied participant keys or current scope as subject_ref. Resolve relative
    dates against the anchor's observed time, but do not invent validity bounds.
    An elapsed possession or relationship duration implies the event that
    started it. Emit that dated start event, not a timeless duration fact. For
    approximate month durations, choose a date in the implied calendar month
    and do not claim exact day precision in the statement.
    confidence_level is stated_explicitly, clearly_implied, or inferred.
    """
  end

  defp compact_system_prompt do
    """
    Return only explicit durable facts from the anchored observation and its
    supplied evidence window. Each item is one self-contained atomic statement.
    Omit greetings, reactions, questions, guesses, conversational acts, and
    facts that are useful only during this exchange.

    For every item copy the shortest exact supporting_span, name one supplied
    participant key or the exact current scope as subject_ref, and cite only
    supplied source_message_ids. Replace first-person wording in the statement
    with the person's name. Never make the relaying software a subject.

    When the source explicitly names when the fact starts or stops being true,
    copy the shortest exact date or relative-time phrase into the matching
    evidence field. Otherwise use null. Do not infer a date, policy label,
    classification, confidence, visibility, lifecycle state, or explanation.
    """
  end

  defp compact_batch_system_prompt do
    """
    Return one envelope for every supplied anchor and copy its exact Anchor id.
    Keep anchors separate. Within each envelope, return only explicit durable
    facts as self-contained atomic statements.

    Every item copies the shortest exact supporting_span, names one supplied
    participant key or exact current scope as subject_ref, and cites only ids
    from that anchor's window. Replace first-person wording with the person's
    name. Omit questions, guesses, conversational acts, and claims about the
    relaying software.

    Copy an exact date or relative-time phrase into a validity-evidence field
    only when the source explicitly supplies that boundary; otherwise use null.
    Do not emit policy labels, classifications, confidence, lifecycle choices,
    explanations, or cross-anchor facts.
    """
  end

  defp batch_anchor_text(%{message: message, context: context}) do
    """
    Anchor id: #{message["id"]}
    Speaker peer key: #{context.source_peer_key}
    Speaker role: #{Map.get(message, "role", "user")}
    Current scope: #{context.scope_path}
    Conversation participants: #{Enum.join(context.known_peer_keys, ", ")}
    Observed at: #{observed_at(context.occurred_at)}
    Anchored observation: #{message["content"]}
    Conversation window (id | speaker | observed at | text):
    #{window_text(context.window_messages, context.occurred_at)}
    """
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
  # The known-peer list is taken as given. The speaker used to be appended to it
  # unconditionally, which made an agent relaying somebody else's conversation a
  # legal subject of claims about them; the caller now decides who was actually
  # present.
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
    |> Map.put(:grounding_mode, :ingest)
    |> Map.put(
      :window_message_ids,
      Map.get(context, :window_message_ids, List.wrap(Map.get(message, "id")))
    )
    # Falls back to now only for a standalone caller that assembled an
    # observation without one. Both pipeline paths always carry a stored time.
    |> Map.put(:occurred_at, Map.get(message, "occurred_at") || MemHouse.Clock.utc_now())
    |> Map.put(:known_peer_keys, Map.get(message, "known_peer_keys", [source_peer_key]))
    |> Map.put(:forbidden_subject_terms, forbidden_subject_terms(message))
  end

  # Identities a statement may not be written about, whatever the model proposes.
  #
  # The subject allowlist already stops a machine identity becoming
  # `subject_ref`, but nothing stopped one appearing in the prose — a statement
  # like "The assistant is allergic to shellfish" is a claim about a person,
  # misfiled onto the process that carried it. Governance then reads that
  # subject as having consented to itself.
  #
  # Two sources: the Account's agent peers, which the caller supplies because it
  # is the only side that knows which identities are machines, and the generic
  # ways a model refers to itself.
  defp forbidden_subject_terms(message) do
    Enum.uniq(Map.get(message, "agent_peer_keys", []) ++ @generic_machine_referents)
  end

  defp window_text(messages, fallback_occurred_at) do
    Enum.map_join(messages, "\n", fn window_message ->
      occurred_at = window_message["occurred_at"] || fallback_occurred_at

      "#{window_message["id"]} | #{window_message["peer_key"]} | #{observed_at(occurred_at)} | #{window_message["content"]}"
    end)
  end
end
