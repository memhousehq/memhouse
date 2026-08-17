# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Schema do
  @moduledoc """
  The contract every structured-output shape implements.

  A schema supplies provider JSON Schema and an independent `cast/2`. Provider enforcement is not
  trusted; `cast/2` validates and normalizes hostile input.

  `cast/2` returns `{:ok, value}` or `{:error, messages}` with a list of
  human-readable, content-free error strings. Those messages are fed back to the
  model in a bounded repair prompt, so they must describe the *shape* problem
  without restating Account content.
  """

  @callback json_schema() :: map()
  @callback cast(map(), map()) :: {:ok, term()} | {:error, [String.t()]}
  @callback recover_after_repairs(map(), map()) :: {:ok, term()} | :error

  @optional_callbacks recover_after_repairs: 2
end

defmodule MemHouse.Model.Schema.Extraction do
  @moduledoc """
  The structured shape an extractor must return, and the validator that decides
  whether a candidate is allowed to become proposed knowledge.

  ## Derived from the resource, not hand-copied

  Types and numeric bounds come from the knowledge resource. Each candidate also passes the
  pipeline create action as an unsaved changeset. Local `@allowed` enums must match its
  `attribute_in` validations.

  ## What one candidate is

  A candidate includes statement, classification, an anchored confidence
  level, sensitivity, target level, independent subject, expiry, and a validity
  window.

  ## Rules this module enforces

  - **Statements assert durable knowledge.** A candidate cannot be a question,
    a transcription of a speech act, or an unanchored generic claim. A peer
    claim must name a subject in prose. These checks give the repair loop a
    deterministic floor; the extractor still decides whether a supported fact
    is durable enough to propose.
  - **Statements are about people.** A candidate naming a relaying agent, in
    `subject_ref` or in its prose, is rejected. Knowledge filed against the
    process that carried it is misattribution governance cannot detect.
  - **Subject is independent of source.** The model names the subject itself. A
    `peer` subject must be one of the known peer keys supplied in the context,
    and a `scope` subject must be exactly the current scope path. Nothing else
    can be named, so a model cannot attach a claim to a peer or a scope the
    caller never mentioned.
  - **Evidence is derived, not asserted.** Only a peer speaking about itself is
    `direct`; every other source-to-subject relationship is `indirect`. The
    same deterministic relationship applies the third-party confidence discount.
  - **Message provenance is bounded.** A candidate may cite only message ids
    supplied in the extractor's conversation window. During ingest extraction,
    its supporting span must occur verbatim in one of those cited messages.
    A statement date must also be present in cited text or resolve from a
    relative-time expression in that text.
  - **Time bounds must be coherent.** A validity window that starts after it
    ends is rejected.
  - **Nothing here activates knowledge.** A valid candidate is still only a
    proposal; it enters the `proposed` state and must pass governance before it
    is visible to retrieval.

  ## Mistakes to avoid

  - Do not relax `cast/2` to salvage partially valid output. Repair must see
    every validation error first. `recover_after_repairs/2` may omit invalid
    candidates only after the repair budget is exhausted.
  - Do not put Account content into an error message: the messages are sent
    back to the model in the repair prompt and appear in error tuples.
  """

  @behaviour MemHouse.Model.Schema

  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.Statement

  # Generic ways a model names the process instead of a person. These are matched only in the
  # statement's subject position. Agent-specific peer keys are supplied per validation context.
  @generic_machine_referents ["the assistant", "the agent", "the ai", "the chatbot", "the bot"]

  # Anchored to the start of the statement, because a generic referent is refused as the thing a
  # claim is about, not as a thing a claim mentions. "Melanie recommends the assistant." is a
  # fact about Melanie; "The assistant is allergic to shellfish." is a person's fact misfiled.
  @generic_referent_subject Regex.compile!(
                              "\\A(" <>
                                Enum.map_join(@generic_machine_referents, "|", &Regex.escape/1) <>
                                ")\\b",
                              "iu"
                            )

  # Candidate fields taken straight from the knowledge resource's attributes.
  # `confidence_level` is normalized to the persisted `confidence` value after
  # validation, so it deliberately is not part of this list.
  @knowledge_fields ~w(statement kind confidence sensitivity target_level)a

  # Valid time comes from the observation. Expiry and revalidation are
  # governance policy and never enter the model contract.
  @temporal_fields ~w(relevant_from relevant_until)a

  @temporal_descriptions %{
    relevant_from:
      "when the claim became true, only when the source states or implies a date; otherwise null",
    relevant_until:
      "when the claim stopped being true, only when the source states or implies an end date; otherwise null"
  }

  @candidate_fields (@knowledge_fields ++
                       @temporal_fields ++
                       ~w(supporting_span confidence_level subject_type subject_ref source_message_ids)a)
                    |> Enum.map(&Atom.to_string/1)
                    |> MapSet.new()

  # The only two things a statement may be about. Source is separate: who said
  # it is not who it is about.
  @subject_types ~w(peer scope)

  @confidence_levels %{
    "stated_explicitly" => 1.0,
    "clearly_implied" => 0.8,
    "inferred" => 0.6
  }

  # Enumerations that the JSON schema advertises and `cast/2` re-checks. The
  # attributes themselves carry no enum constraint, so these must be kept equal
  # to the `attribute_in` validations on KnowledgeItem's `create_from_pipeline`.
  @allowed %{
    kind: ~w(fact preference event relation skill),
    sensitivity: ~w(public internal personal restricted),
    target_level: ~w(peer scope account)
  }

  @enum_descriptions %{
    kind:
      "fact is stable information; preference is a choice; event has a time; relation connects people or things; skill is an ability",
    sensitivity:
      "public can be shared; internal stays in the Account; personal concerns one person; restricted needs the most care",
    target_level:
      "peer stays with one person; scope is for the current scope; account is Account-wide"
  }

  @doc """
  Builds the JSON schema sent to the provider.

  Field types and bounds come from the knowledge resource's attributes, so the
  advertised contract cannot drift from what will actually be accepted.
  `additionalProperties` is false, and the candidate list advertises a
  `maxItems` of 24 — a hint to the provider about how much one raw message
  should cost downstream. `cast/2` does not re-check the count, so a provider
  that ignores the bound is not rejected for it.
  """
  @impl true
  def json_schema do
    candidate = candidate_json_schema()

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "items" => %{"type" => "array", "items" => candidate, "maxItems" => 24}
      },
      "required" => ["items"]
    }
  end

  @doc """
  Returns the JSON Schema for one candidate in the current extraction contract.

  The schema is embedded by both single-anchor and batched structured requests;
  validation still runs through `cast/2` before any candidate can be persisted.
  """
  def candidate_json_schema do
    knowledge_properties =
      Map.new(@knowledge_fields, fn name ->
        {Atom.to_string(name), attribute_schema(name)}
      end)
      |> Map.delete("confidence")

    temporal_properties =
      Map.new(@temporal_fields, fn name ->
        {Atom.to_string(name),
         %{
           "description" => Map.fetch!(@temporal_descriptions, name),
           "anyOf" => [
             %{"type" => "string", "format" => "date-time"},
             %{"type" => "null"}
           ]
         }}
      end)

    property_order =
      ~w(supporting_span statement confidence_level kind subject_type subject_ref sensitivity target_level source_message_ids relevant_from relevant_until)

    %{
      "type" => "object",
      "description" =>
        "Copy supporting_span, write the statement, then rate it with confidence_level.",
      "additionalProperties" => false,
      "properties" =>
        knowledge_properties
        |> Map.merge(temporal_properties)
        |> Map.merge(%{
          "supporting_span" => %{
            "type" => "string",
            "minLength" => 1,
            "description" =>
              "Exact source text that supports the claim; ingest validation requires it to occur in a cited message"
          },
          "confidence_level" => %{
            "type" => "string",
            "enum" => ~w(stated_explicitly clearly_implied inferred),
            "description" =>
              "stated_explicitly means the source states the claim; clearly_implied means the claim follows directly; inferred requires interpretation"
          },
          "subject_type" => %{
            "type" => "string",
            "enum" => @subject_types,
            "description" => "peer identifies one person; scope identifies the current scope"
          },
          "subject_ref" => %{"type" => "string", "minLength" => 1},
          "source_message_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string", "format" => "uuid"},
            "minItems" => 1,
            "uniqueItems" => true
          }
        }),
      "propertyOrdering" => property_order,
      "required" =>
        ~w(supporting_span statement confidence_level kind subject_type subject_ref sensitivity target_level)
    }
  end

  @doc """
  Validates a provider response into a list of extraction candidates.

  `context` must carry `:account_id` and `:scope_id`, and `:scope_path` as well
  once any candidate names a scope subject. `:known_peer_keys` defaults to the
  empty list, which rejects every peer subject, so a caller that wants peer
  subjects must supply it. `:source_peer_id`, `:source_peer_key`, and
  `:message_id` are optional. The peer keys and the scope path are the allowlist
  a subject reference is checked against.

  Returns `{:ok, candidates}` only when every candidate is valid — the response
  is accepted or rejected as a whole, because a half-applied extraction would
  leave the observation partially represented with no record of what was
  dropped. Otherwise returns `{:error, messages}` with each message prefixed by
  the failing candidate's index, which is what the repair prompt shows the
  model.
  """
  @impl true
  def cast(object, context) when is_map(object) and is_map(context) do
    # Prepare generic machine referent matchers once per validation context and reuse them
    # across all statements rather than rebuilding the regex for each one.
    context = prepare_forbidden_term_matchers(context)

    case fetch(object, "items") do
      items when is_list(items) ->
        items
        |> Enum.with_index()
        |> Enum.reduce({[], []}, fn {item, index}, {valid, errors} ->
          case cast_item(item, context) do
            {:ok, casted} -> {[casted | valid], errors}
            {:error, item_errors} -> {valid, errors ++ prefix_errors(item_errors, index)}
          end
        end)
        |> case do
          {valid, []} -> {:ok, Enum.reverse(valid)}
          {_valid, errors} -> {:error, errors}
        end

      _other ->
        {:error, ["items must be an array"]}
    end
  end

  def cast(_object, _context), do: {:error, ["response must be an object"]}

  @doc """
  Returns valid candidates after structured-output repair is exhausted.

  Recovery is allowed only for a well-formed candidate list with at least one
  valid and one invalid item. A wholly invalid response remains an error so the
  pipeline job can retry the observation.
  """
  @impl true
  def recover_after_repairs(object, context) when is_map(object) and is_map(context) do
    context = prepare_forbidden_term_matchers(context)

    case fetch(object, "items") do
      items when is_list(items) ->
        {valid, invalid_count} =
          Enum.reduce(items, {[], 0}, fn item, {valid, invalid_count} ->
            case cast_item(item, context) do
              {:ok, casted} -> {[casted | valid], invalid_count}
              {:error, _errors} -> {valid, invalid_count + 1}
            end
          end)

        if valid != [] and invalid_count > 0,
          do: {:ok, Enum.reverse(valid)},
          else: :error

      _other ->
        :error
    end
  end

  def recover_after_repairs(_object, _context), do: :error

  # Validates one candidate. The `with` chain is ordered cheapest-first and
  # stops at the first failure, so the resource changeset check — the most
  # expensive step — only runs on a candidate that is already well formed.
  # Confidence is computed rather than copied: see `source_confidence/4`.
  defp cast_item(item, context) when is_map(item) do
    with :ok <- candidate_keys(item, context),
         {:ok, statement} <- readable_statement(item),
         {:ok, kind} <- enum(item, "kind", allowed(:kind)),
         {:ok, subject_type} <- enum(item, "subject_type", @subject_types),
         {:ok, source_message_ids} <- source_message_ids(item, context),
         :ok <- grounded_in_sources(item, statement, source_message_ids, context),
         {:ok, subject_ref, evidence_source_peer_key} <-
           valid_subject_ref(item, subject_type, source_message_ids, context),
         :ok <- self_contained_statement(statement, item),
         :ok <- durable_statement(statement, subject_type, subject_ref),
         :ok <- human_subject_statement(statement, context),
         {:ok, confidence} <- confidence(item),
         {:ok, sensitivity} <- enum(item, "sensitivity", allowed(:sensitivity)),
         {:ok, target_level} <- enum(item, "target_level", allowed(:target_level)),
         {:ok, temporal} <- temporal(item),
         :ok <- temporal_order(temporal),
         casted <-
           %{
             statement: statement,
             kind: kind,
             subject_type: subject_type,
             subject_ref: subject_ref,
             source_message_ids: source_message_ids,
             confidence:
               source_confidence(
                 confidence,
                 subject_type,
                 subject_ref,
                 evidence_source_peer_key
               ),
             evidence_level: evidence_level(subject_type, subject_ref, evidence_source_peer_key),
             sensitivity: sensitivity,
             target_level: target_level,
             revalidate_after: nil,
             expires_at: nil
           }
           |> Map.merge(temporal),
         :ok <- validate_ash_action(casted, context) do
      {:ok, casted}
    end
  end

  defp cast_item(_item, _context), do: {:error, ["candidate must be an object"]}

  defp candidate_keys(item, context) do
    keys =
      Enum.map(Map.keys(item), fn
        key when is_binary(key) -> key
        key when is_atom(key) -> Atom.to_string(key)
        _key -> :invalid
      end)

    allowed =
      context
      |> Map.get(:extraction_extra_fields, [])
      |> Enum.reduce(@candidate_fields, &MapSet.put(&2, &1))

    if Enum.all?(keys, &MapSet.member?(allowed, &1)),
      do: :ok,
      else: {:error, ["candidate contains unsupported fields"]}
  end

  defp source_message_ids(item, context) do
    allowed = Map.get(context, :window_message_ids, [])

    case Map.fetch(item, "source_message_ids") do
      {:ok, ids} when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &(is_binary(&1) and &1 in allowed)) and
             length(ids) == length(Enum.uniq(ids)) do
          {:ok, ids}
        else
          {:error, ["source_message_ids must be unique ids from the supplied observation window"]}
        end

      :error when allowed != [] ->
        {:ok, [List.last(allowed)]}

      :error ->
        {:ok, []}

      _other ->
        {:error, ["source_message_ids must be a non-empty array"]}
    end
  end

  # Dream-time deductions reuse the candidate shape but have contributor
  # validation of their own. Raw ingest marks its context explicitly so missing
  # cited content cannot silently disable this stricter evidence boundary.
  defp grounded_in_sources(item, statement, source_message_ids, context) do
    messages = Map.get(context, :window_messages, [])
    messages_by_id = Map.new(messages, &{fetch(&1, "id"), fetch(&1, "content")})
    source_texts = Enum.map(source_message_ids, &Map.get(messages_by_id, &1))

    if Map.get(context, :grounding_mode) != :ingest do
      :ok
    else
      validate_source_grounding(item, statement, source_texts, context)
    end
  end

  defp validate_source_grounding(_item, _statement, source_texts, _context)
       when source_texts == [] do
    {:error, ["cited source content must be available for grounding"]}
  end

  defp validate_source_grounding(item, statement, source_texts, context) do
    if Enum.any?(source_texts, &(not is_binary(&1))) do
      {:error, ["cited source content must be available for grounding"]}
    else
      case non_empty_string(item, "supporting_span") do
        {:ok, supporting_span} ->
          cond do
            not Enum.any?(source_texts, &String.contains?(&1, supporting_span)) ->
              {:error, ["supporting_span must be exact text from a cited source"]}

            question?(supporting_span) ->
              {:error, ["supporting_span must assert knowledge, not ask a question"]}

            not dates_grounded?(statement, source_texts, Map.get(context, :occurred_at)) ->
              {:error, ["statement must be supported by its cited source text"]}

            true ->
              :ok
          end

        {:error, _error} ->
          {:error, ["supporting_span must be exact text from a cited source"]}
      end
    end
  end

  defp question?(text) do
    String.ends_with?(String.trim(text), "?") or
      String.match?(
        text,
        ~r/^\s*(?:who|what|when|where|why|how|is|are|was|were|do|does|did|can|could|will|would|has|have|had)\b/iu
      )
  end

  defp dates_grounded?(statement, source_texts, occurred_at) do
    dates = Regex.scan(~r/\b\d{4}-\d{2}-\d{2}\b/u, statement) |> List.flatten()
    source = Enum.join(source_texts, " ")

    dates == [] or
      Enum.all?(dates, fn date ->
        date_present?(date, source) or date_resolved?(date, source, occurred_at)
      end)
  end

  defp date_present?(date, source) do
    case Date.from_iso8601(date) do
      {:ok, parsed} ->
        month = parsed |> Calendar.strftime("%B") |> Regex.escape()
        short_month = parsed |> Calendar.strftime("%b") |> Regex.escape()
        day = parsed.day
        year = parsed.year

        String.contains?(source, date) or
          String.match?(source, ~r/\b#{day}\s+(?:#{month}|#{short_month})\s+#{year}\b/iu) or
          String.match?(
            source,
            ~r/\b(?:#{month}|#{short_month})\s+#{day}(?:st|nd|rd|th)?,?\s+#{year}\b/iu
          )

      _error ->
        false
    end
  end

  defp date_resolved?(date, source, %DateTime{} = occurred_at) do
    case Date.from_iso8601(date) do
      {:ok, expected} ->
        source
        |> resolve_relative_dates(DateTime.to_date(occurred_at))
        |> Enum.member?(expected)

      _error ->
        false
    end
  end

  defp date_resolved?(_date, _source, _occurred_at), do: false

  defp resolve_relative_dates(source, observed_on) do
    named_dates =
      [
        {~r/\byesterday\b/iu, Date.add(observed_on, -1)},
        {~r/\b(?:today|tonight)\b/iu, observed_on},
        {~r/\btomorrow\b/iu, Date.add(observed_on, 1)}
      ]
      |> Enum.flat_map(fn {pattern, date} ->
        if String.match?(source, pattern), do: [date], else: []
      end)

    amount_dates =
      ~r/\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(day|week|month|year)s?\s+(ago|from\s+now)\b/iu
      |> Regex.scan(source)
      |> Enum.map(&resolve_relative_amount(observed_on, &1))

    named_dates ++ amount_dates
  end

  defp resolve_relative_amount(observed_on, [_text, amount, unit, direction]) do
    multiplier = if String.downcase(direction) == "ago", do: -1, else: 1
    amount = relative_amount(amount) * multiplier

    case String.downcase(unit) do
      "day" -> Date.add(observed_on, amount)
      "week" -> Date.add(observed_on, amount * 7)
      "month" -> Date.shift(observed_on, month: amount)
      "year" -> Date.shift(observed_on, year: amount)
    end
  end

  defp relative_amount(amount) do
    case Integer.parse(amount) do
      {value, ""} ->
        value

      :error ->
        ~w(one two three four five six seven eight nine ten eleven twelve)
        |> Enum.find_index(&(&1 == String.downcase(amount)))
        |> Kernel.+(1)
    end
  end

  # Final gate: build the real pipeline create changeset and ask whether it is
  # valid, without saving. This makes the resource's own attribute constraints,
  # not a copy of them, the authority on what a candidate may contain.
  #
  # The provenance placeholders below exist only to satisfy required attributes
  # during this dry run. The caller replaces them with the real provider, model,
  # and prompt identity before anything is persisted, so nothing carrying the
  # string "schema-validation" ever reaches the database. "f5-1" is the contract
  # identity value for the extractor and pipeline; changing it obliges a
  # maintainer to add a changelog entry and refresh the contract evidence.
  defp validate_ash_action(item, context) do
    attrs =
      item
      |> Map.take(@knowledge_fields ++ @temporal_fields)
      |> Map.merge(%{
        scope_id: Map.fetch!(context, :scope_id),
        subject_peer_id: Map.get(context, :source_peer_id),
        state: "proposed",
        source_message_ids: item.source_message_ids,
        extracting_provider: "schema-validation",
        extracting_model: "schema-validation",
        extracting_model_version: "schema-validation",
        prompt_version: "schema-validation",
        pipeline_version: "f5-1",
        # The real write anchors an undated event to this. Withholding it here would
        # reject a candidate the pipeline can in fact record.
        observed_at: Map.get(context, :occurred_at)
      })

    changeset =
      KnowledgeItem
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_tenant(Map.fetch!(context, :account_id))
      |> Ash.Changeset.for_create(:create_from_pipeline, attrs)

    if changeset.valid? do
      :ok
    else
      {:error, ["candidate does not satisfy KnowledgeItem.create_from_pipeline"]}
    end
  end

  # Translates one knowledge attribute into its JSON-schema fragment, carrying
  # across whatever bounds the resource declares. Reading them from the resource
  # is what keeps the advertised schema and the enforced schema identical.
  defp attribute_schema(name) do
    attribute = Ash.Resource.Info.attribute(KnowledgeItem, name)
    constraints = attribute.constraints || []

    base =
      case attribute.type do
        type when type in [:float, Ash.Type.Float] -> %{"type" => "number"}
        type when type in [:integer, Ash.Type.Integer] -> %{"type" => "integer"}
        _other -> %{"type" => "string"}
      end

    base
    |> maybe_put("enum", Map.get(@allowed, name))
    |> maybe_put("description", Map.get(@enum_descriptions, name))
    |> maybe_put("minimum", constraints[:min])
    |> maybe_put("maximum", constraints[:max])
    |> maybe_put("minLength", constraints[:min_length])
  end

  defp allowed(name), do: Map.fetch!(@allowed, name)

  # The resource rejects unreadable text as well, but only as a whole-candidate changeset
  # failure. Checking here too is what turns that into a message the repair prompt can act on,
  # which is the difference between the model rewriting the statement and it retrying the same
  # collapse.
  defp readable_statement(item) do
    with {:ok, statement} <- non_empty_string(item, "statement") do
      normalized = Statement.normalize(statement)

      if Statement.prose?(normalized) do
        {:ok, normalized}
      else
        {:error, ["statement must be readable text, not repeated filler characters"]}
      end
    end
  end

  # This is intentionally a small deterministic floor, not an attempt to
  # classify all durable knowledge with regular expressions. The provider has
  # the conversation window and makes that decision. These three shapes never
  # become knowledge: a question, a record that somebody spoke, or a peer
  # claim that does not name the peer it purports to describe.
  defp durable_statement(statement, subject_type, _subject_ref) do
    cond do
      String.contains?(statement, "?") ->
        {:error, ["statement must assert knowledge, not record a question"]}

      speech_act_transcription?(statement) ->
        {:error, ["statement must assert the fact, not record a speech act"]}

      subject_type == "peer" and not statement_names_subject?(statement) ->
        {:error, ["statement must name its peer subject"]}

      true ->
        :ok
    end
  end

  # Some verbs describe only a conversational turn. Reporting verbs can also describe durable
  # work (for example, "Avery wrote a book"), so they are refused only when they introduce the
  # content of a message. This keeps the deterministic floor narrow enough to avoid classifying
  # durability from prose while still rejecting the known transcription shapes.
  defp speech_act_transcription?(statement) do
    conversational_turn? =
      String.match?(
        statement,
        ~r/\b(?:asked|greeted|replied|texted|thanked|congratulated|complimented|welcomed|wished)\b/iu
      )

    reported_content? =
      String.match?(
        statement,
        ~r/\b(?i:said|says|told|mentioned|wrote)\b\s*(?:(?:(?i:to)\s+)?\p{Lu}[\p{L}\p{N}_-]*(?:\s+\p{Lu}[\p{L}\p{N}_-]*){0,2}\s*)?(?i:that\b|[:,]|["“])/u
      )

    conversational_turn? or reported_content?
  end

  # Knowledge is about people, not about the software that carried it. A relaying
  # agent's own key and the generic ways a model refers to itself are refused in
  # the statement text, not only in `subject_ref`: a claim about a human wearing
  # the relay's name is misattribution that governance then treats as consented,
  # because the "subject" is the process consenting to itself.
  #
  # Generic machine referents (e.g., "the assistant", "the agent") are matched only in the
  # statement's subject position using case-insensitive word-boundary matching. Agent peer keys
  # are compared as exact opaque values (case-sensitive, whole-word) so keys such as "bot-" remain
  # valid when they don't match an agent's actual key. Only terms the caller supplies are refused;
  # nothing is inferred from the prose.
  defp human_subject_statement(statement, context) do
    cond do
      String.match?(statement, @generic_referent_subject) ->
        {:error, ["statement must be about a person, not about the relaying agent"]}

      Enum.any?(Map.get(context, :agent_peer_keys, []), &names_agent_peer?(statement, &1)) ->
        {:error, ["statement must be about a person, not about the relaying agent"]}

      true ->
        :ok
    end
  end

  # Splits the caller's forbidden terms once per response, rather than per candidate. What is
  # left after removing the generic referents is the deployment's own agent peer keys.
  defp prepare_forbidden_term_matchers(context) do
    Map.put(
      context,
      :agent_peer_keys,
      Map.get(context, :forbidden_subject_terms, []) -- @generic_machine_referents
    )
  end

  # An agent peer key matches anywhere in the statement, case-insensitively because prose
  # capitalises it at the start of a sentence.
  #
  # The boundaries exclude hyphens as well as word characters, which `\\b` alone does not. A key
  # is usually hyphenated — `membench-agent`, `agent-1` — and splitting the statement on
  # punctuation would tear those apart and never match the very identities this exists to catch.
  # Excluding the hyphen on both sides keeps them whole while still refusing to find `bot`
  # inside `bot-x`.
  defp names_agent_peer?(statement, agent_key) do
    String.match?(statement, ~r/(?<![\w-])#{Regex.escape(agent_key)}(?![\w-])/iu)
  end

  # Peer keys are opaque identities in some deployments (`agent-1`), while a
  # statement uses a human name (`Avery`). The validator therefore requires a
  # prose subject instead of incorrectly coupling an authorization identifier
  # to its display text. A leading gerund plus a generic predicate is not a
  # subject; a proper name such as `Vanishing` still is.
  defp statement_names_subject?(statement) do
    String.match?(statement, ~r/\A\p{Lu}[\p{L}\p{N}_-]*\b/u) and
      not generic_leading_gerund?(statement)
  end

  defp generic_leading_gerund?(statement) do
    String.match?(statement, ~r/\A(?:Running|Exercise|Sleep|Travel|Work)\s+(?:can|is|does)\b/u)
  end

  defp non_empty_string(item, key) do
    case fetch(item, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, ["#{key} must not be blank"]}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, ["#{key} must be a string"]}
    end
  end

  # Subject references are checked against an allowlist supplied by the caller,
  # never trusted from the model. A peer subject must be one of the peer keys
  # the caller already knows about, and a scope subject must be exactly the
  # scope the observation arrived in. This is what stops a model from attaching
  # a claim to an unrelated peer or to a scope the caller cannot see.
  defp valid_subject_ref(item, "peer", source_message_ids, context) do
    case first_person_source_peer(item, source_message_ids, context) do
      {:ok, peer_key} ->
        {:ok, peer_key, peer_key}

      :not_first_person ->
        with {:ok, ref} <- non_empty_string(item, "subject_ref") do
          if ref in Map.get(context, :known_peer_keys, []) do
            {:ok, ref, Map.get(context, :source_peer_key)}
          else
            {:error, ["subject_ref must name a known peer"]}
          end
        end

      :unresolved ->
        {:error, ["first-person subject must resolve to one known cited speaker"]}
    end
  end

  defp valid_subject_ref(item, "scope", source_message_ids, context) do
    case first_person_source_peer(item, source_message_ids, context) do
      :not_first_person ->
        with {:ok, ref} <- non_empty_string(item, "subject_ref") do
          if ref == Map.fetch!(context, :scope_path) do
            {:ok, ref, Map.get(context, :source_peer_key)}
          else
            {:error, ["subject_ref must be the current scope path"]}
          end
        end

      _first_person ->
        {:error, ["subject_type must be peer for first-person evidence"]}
    end
  end

  # A first-person span identifies its subject through durable source metadata,
  # not through a model-generated identifier. The cited messages must agree on
  # one known human peer. This keeps relayed or ambiguous evidence fail-closed.
  defp first_person_source_peer(item, source_message_ids, context) do
    with {:ok, supporting_span} <- non_empty_string(item, "supporting_span"),
         true <- first_person?(supporting_span) do
      peers =
        context
        |> Map.get(:window_messages, [])
        |> Enum.filter(fn message ->
          fetch(message, "id") in source_message_ids and
            is_binary(fetch(message, "content")) and
            String.contains?(fetch(message, "content"), supporting_span)
        end)
        |> Enum.map(&fetch(&1, "peer_key"))
        |> Enum.filter(&(&1 in Map.get(context, :known_peer_keys, [])))
        |> Enum.reject(&(&1 in Map.get(context, :agent_peer_keys, [])))
        |> Enum.uniq()

      case peers do
        [peer_key] -> {:ok, peer_key}
        _other -> :unresolved
      end
    else
      _other -> :not_first_person
    end
  end

  defp first_person?(text) do
    String.match?(text, ~r/^\s*(?:I(?:['’](?:m|ve|d|ll))?\b|my\b|mine\b|me\b)/iu)
  end

  # Evidence can identify an opaque Peer key, but that key is not display text.
  # Require the model to provide self-contained prose instead of manufacturing
  # a human name or persisting a pronoun whose referent disappears on retrieval.
  defp self_contained_statement(statement, item) do
    supporting_span = fetch(item, "supporting_span")

    if is_binary(supporting_span) and first_person?(supporting_span) and
         first_person?(statement) do
      {:error, ["statement must replace first-person wording with the person's name"]}
    else
      :ok
    end
  end

  defp enum(item, key, allowed) do
    case fetch(item, key) do
      value when is_binary(value) ->
        normalized = String.downcase(value)
        if normalized in allowed, do: {:ok, normalized}, else: {:error, ["#{key} is invalid"]}

      _other ->
        {:error, ["#{key} must be a string"]}
    end
  end

  # A small anchored scale is reproducible enough for downstream ordering. The
  # normalized fraction preserves the existing durable storage contract.
  defp confidence(item) do
    case fetch(item, "confidence_level") do
      value when is_binary(value) ->
        case Map.fetch(@confidence_levels, String.downcase(value)) do
          {:ok, confidence} -> {:ok, confidence}
          :error -> {:error, ["confidence_level is invalid"]}
        end

      _other ->
        {:error, ["confidence_level must be a string"]}
    end
  end

  defp temporal(item) do
    @temporal_fields
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      case datetime(fetch(item, Atom.to_string(field))) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, reason} -> {:halt, {:error, ["#{field} #{reason}"]}}
      end
    end)
  end

  defp datetime(nil), do: {:ok, nil}
  defp datetime(""), do: {:ok, nil}
  defp datetime(%DateTime{} = value), do: {:ok, value}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, "must be an ISO-8601 timestamp or null"}
    end
  end

  defp datetime(_value), do: {:error, "must be an ISO-8601 timestamp or null"}

  defp temporal_order(%{relevant_from: from, relevant_until: until})
       when not is_nil(from) and not is_nil(until) do
    if DateTime.compare(from, until) == :lt,
      do: :ok,
      else: {:error, ["relevant_from must be before relevant_until"]}
  end

  defp temporal_order(_temporal), do: :ok

  # Third-party status comes from the resolved subject and known source peer.
  defp source_confidence(confidence, subject_type, subject_ref, source_peer_key) do
    if evidence_level(subject_type, subject_ref, source_peer_key) == "indirect" do
      Float.round(confidence * 0.75, 4)
    else
      confidence
    end
  end

  defp evidence_level("peer", subject_ref, source_peer_key)
       when subject_ref == source_peer_key,
       do: "direct"

  defp evidence_level(_subject_type, _subject_ref, _source_peer_key), do: "indirect"

  # Looks a key up by its string name whether the map arrived with string or
  # atom keys. Providers, cassettes, and hand-written test fixtures disagree
  # about which they use, and this validator must behave identically for all of
  # them. Deliberately does not call `String.to_atom/1`: input from a model must
  # never be allowed to create atoms.
  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {candidate, value} when is_atom(candidate) ->
            if Atom.to_string(candidate) == key, do: {:found, value}

          {_candidate, _value} ->
            nil
        end)
        |> case do
          {:found, value} -> value
          nil -> nil
        end
    end
  end

  defp prefix_errors(errors, index), do: Enum.map(errors, &"items[#{index}].#{&1}")

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule MemHouse.Model.Schema.ExtractionBatch do
  @moduledoc """
  Per-anchor extraction envelopes for one token-batched provider call.

  The outer response must name every supplied anchor exactly once. Each
  envelope is then validated with the ordinary extraction schema and that
  anchor's own allowlists, evidence window, observation time, and subject
  context. A candidate can therefore cite another supplied message only when
  that message was also in its anchor's bounded source window.

  Validation repairs the batch as a whole. When the repair budget is exhausted,
  valid envelopes are retained and invalid or missing anchors become explicit
  terminal results. The caller can commit or reject each anchor independently;
  malformed output for one anchor never changes a sibling's attribution.
  """

  @behaviour MemHouse.Model.Schema

  alias MemHouse.Model.Schema.Extraction

  @impl true
  def json_schema, do: json_schema(Extraction)

  @doc """
  Builds the closed batch envelope around a candidate schema module.

  The supplied module must implement the extraction-schema callbacks. The
  returned schema requires one result per anchor and rejects undeclared fields;
  semantic and provenance validation happens after provider output is decoded.
  """
  def json_schema(candidate_schema) when is_atom(candidate_schema) do
    envelope = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "anchor_id" => %{"type" => "string", "format" => "uuid"},
        "items" => %{
          "type" => "array",
          "items" => candidate_schema.candidate_json_schema(),
          "maxItems" => 24
        }
      },
      "required" => ["anchor_id", "items"]
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "anchors" => %{"type" => "array", "items" => envelope}
      },
      "required" => ["anchors"]
    }
  end

  @impl true
  def cast(object, %{anchor_contexts: contexts} = context)
      when is_map(object) and is_map(contexts) do
    candidate_schema = Map.get(context, :candidate_schema, Extraction)

    with {:ok, envelopes} <- envelopes(object),
         :ok <- exact_anchor_set(envelopes, contexts) do
      cast_envelopes(envelopes, contexts, candidate_schema)
    end
  end

  def cast(_object, _context), do: {:error, ["batch response must be an object"]}

  @impl true
  def recover_after_repairs(object, %{anchor_contexts: contexts} = context)
      when is_map(object) and is_map(contexts) do
    candidate_schema = Map.get(context, :candidate_schema, Extraction)

    case envelopes(object) do
      {:ok, envelopes} ->
        by_anchor =
          Map.new(envelopes, fn envelope ->
            {Map.get(envelope, "anchor_id"), envelope}
          end)

        results =
          Enum.map(contexts, fn {anchor_id, context} ->
            case Map.get(by_anchor, anchor_id) do
              %{"items" => items} ->
                recover_envelope(anchor_id, items, context, candidate_schema)

              _missing_or_malformed ->
                terminal(anchor_id, "missing_or_malformed_envelope")
            end
          end)

        {:ok, results}

      {:error, _errors} ->
        {:ok, Enum.map(Map.keys(contexts), &terminal(&1, "malformed_batch_response"))}
    end
  end

  def recover_after_repairs(_object, _context), do: :error

  defp envelopes(%{"anchors" => envelopes}) when is_list(envelopes), do: {:ok, envelopes}
  defp envelopes(_object), do: {:error, ["anchors must be an array"]}

  defp exact_anchor_set(envelopes, contexts) do
    ids = Enum.map(envelopes, &Map.get(&1, "anchor_id"))
    expected = Map.keys(contexts)

    if length(ids) == length(Enum.uniq(ids)) and Enum.sort(ids) == Enum.sort(expected) do
      :ok
    else
      {:error, ["anchors must name every supplied anchor exactly once"]}
    end
  end

  defp cast_envelopes(envelopes, contexts, candidate_schema) do
    {results, errors} =
      envelopes
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {envelope, index}, {results, errors} ->
        anchor_id = Map.get(envelope, "anchor_id")
        context = Map.get(contexts, anchor_id)

        case cast_envelope(anchor_id, Map.get(envelope, "items"), context, candidate_schema) do
          {:ok, result} -> {[result | results], errors}
          {:error, envelope_errors} -> {results, errors ++ prefix(envelope_errors, index)}
        end
      end)

    if errors == [], do: {:ok, Enum.reverse(results)}, else: {:error, errors}
  end

  defp cast_envelope(anchor_id, items, context, candidate_schema)
       when is_binary(anchor_id) and is_list(items) and is_map(context) do
    case candidate_schema.cast(%{"items" => items}, context) do
      {:ok, casted} -> {:ok, %{anchor_id: anchor_id, status: :ok, items: casted}}
      {:error, errors} -> {:error, errors}
    end
  end

  defp cast_envelope(_anchor_id, _items, _context, _candidate_schema),
    do: {:error, ["anchor envelope is malformed"]}

  defp recover_envelope(anchor_id, items, context, candidate_schema) when is_list(items) do
    case candidate_schema.cast(%{"items" => items}, context) do
      {:ok, casted} -> %{anchor_id: anchor_id, status: :ok, items: casted}
      {:error, _errors} -> recover_candidates(anchor_id, items, context, candidate_schema)
    end
  end

  defp recover_envelope(anchor_id, _items, _context, _candidate_schema),
    do: terminal(anchor_id, "malformed_anchor_envelope")

  defp recover_candidates(anchor_id, items, context, candidate_schema) do
    case candidate_schema.recover_after_repairs(%{"items" => items}, context) do
      {:ok, casted} -> %{anchor_id: anchor_id, status: :ok, items: casted}
      :error -> terminal(anchor_id, "structured_validation_exhausted")
    end
  end

  defp terminal(anchor_id, reason_class),
    do: %{anchor_id: anchor_id, status: :terminal, reason_class: reason_class, items: []}

  defp prefix(errors, index), do: Enum.map(errors, &"anchor #{index}: #{&1}")
end

defmodule MemHouse.Model.Schema.Reasoning do
  @moduledoc """
  The structured shape for background reasoning: extraction candidates plus
  typed relations between existing knowledge.

  A response is untrusted input, not a write instruction. Candidate statements
  inherit their scope, sensitivity, and target level from the pipeline working
  set. Relations may name only supplied active inputs in that Account and scope.
  The pipeline applies accepted output as governed proposals; this schema never
  selects a lifecycle state or widens visibility.
  """

  @behaviour MemHouse.Model.Schema

  @max_deductions 12
  @max_relations 24
  @relation_kinds ~w(supports contradicts derived_from)
  @controlled_item_fields ~w(account_id scope_id state held_scope_id verification)

  @doc """
  The extraction schema with a required `relations` array added.
  """
  @impl true
  def json_schema do
    extraction = MemHouse.Model.Schema.Extraction.json_schema()

    extraction
    |> put_in(["properties", "items", "maxItems"], @max_deductions)
    |> put_in(["properties", "items", "items", "properties", "contributor_ids"], %{
      "type" => "array",
      "items" => %{"type" => "string", "format" => "uuid"},
      "minItems" => 2,
      "uniqueItems" => true
    })
    |> update_in(["properties", "items", "items", "required"], &(&1 ++ ["contributor_ids"]))
    |> put_in(["properties", "relations"], %{
      "type" => "array",
      "maxItems" => @max_relations,
      "items" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "source_id" => %{"type" => "string"},
          "target_id" => %{"type" => "string"},
          "kind" => %{"type" => "string", "enum" => ~w(supports contradicts derived_from)}
        },
        "required" => ~w(source_id target_id kind)
      }
    })
    |> Map.put("required", ["items", "relations"])
  end

  @doc """
  Validates a reasoning response into `{:ok, %{items:, relations:}}`.

  Candidates go through extraction validation and must match the pipeline's
  inherited sensitivity and target level. A non-empty relation list also
  requires `:reasoning_inputs`: active input maps with `id`, `account_id`,
  `scope_id`, and `state`. Inputs may also carry their content-free durable
  `source_observations`; the synthesis contract uses those trusted references
  to require genuinely independent sources rather than merely distinct
  knowledge ids. The pipeline builds that list from authorized rows and their
  provenance; callers must not construct it from model output.

  Returns normalized atom-keyed relations, or stable content-free rejection
  reasons. It never performs a database write.
  """
  @impl true
  def cast(object, context) when is_map(object) and is_map(context) do
    with {:ok, raw_items} <- items(object),
         :ok <- deduction_limit(raw_items),
         :ok <- reject_controlled_item_fields(raw_items),
         extraction_context =
           Map.put(context, :extraction_extra_fields, ~w(reasoning contributor_ids)),
         {:ok, items} <-
           MemHouse.Model.Schema.Extraction.cast(%{"items" => raw_items}, extraction_context),
         {:ok, items} <- validate_deduction_contributors(items, raw_items, context),
         {:ok, raw_relations} <- relations(object),
         :ok <- relation_limit(raw_relations),
         {:ok, relations} <- validate_relations(raw_relations, context) do
      {:ok, %{items: items, relations: relations}}
    else
      {:error, errors} -> {:error, errors}
    end
  end

  def cast(_object, _context), do: {:error, ["response must be an object"]}

  defp items(object) do
    case fetch(object, "items") do
      items when is_list(items) -> {:ok, items}
      _other -> {:error, ["items must be an array"]}
    end
  end

  defp relations(object) do
    case fetch(object, "relations") do
      nil -> {:ok, []}
      relations when is_list(relations) -> {:ok, relations}
      _other -> {:error, ["relations must be an array"]}
    end
  end

  defp deduction_limit(items) when length(items) <= @max_deductions, do: :ok

  defp deduction_limit(_items),
    do: {:error, ["items must contain at most #{@max_deductions} deductions"]}

  defp relation_limit(relations) when length(relations) <= @max_relations, do: :ok

  defp relation_limit(_relations),
    do: {:error, ["relations must contain at most #{@max_relations} relations"]}

  defp reject_controlled_item_fields(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce([], fn {item, index}, errors ->
      if is_map(item) do
        case Enum.find(@controlled_item_fields, &has_key?(item, &1)) do
          nil -> errors
          field -> errors ++ ["items[#{index}].#{field} is pipeline-controlled"]
        end
      else
        errors
      end
    end)
    |> case do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp validate_deduction_contributors([], [], _context), do: {:ok, []}

  defp validate_deduction_contributors(items, raw_items, context) do
    with {:ok, inputs} <- reasoning_inputs(context) do
      items
      |> Enum.zip(raw_items)
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{item, raw}, index}, {valid, errors} ->
        case contributor_ids(raw, inputs, context, index) do
          {:ok, ids, inheritance} ->
            add_valid_deduction(item, ids, inheritance, index, valid, errors)

          {:error, item_errors} ->
            {valid, errors ++ item_errors}
        end
      end)
      |> case do
        {valid, []} -> {:ok, Enum.reverse(valid)}
        {_valid, errors} -> {:error, errors}
      end
    end
  end

  defp add_valid_deduction(item, ids, inheritance, index, valid, errors) do
    item_errors =
      []
      |> mismatch(
        item.sensitivity,
        inheritance.sensitivity,
        "items[#{index}].sensitivity must inherit its contributors"
      )
      |> mismatch(
        item.target_level,
        inheritance.target_level,
        "items[#{index}].target_level must not widen its contributors"
      )

    if item_errors == [] do
      {[Map.put(item, :contributor_ids, ids) | valid], errors}
    else
      {valid, errors ++ item_errors}
    end
  end

  defp contributor_ids(raw, inputs, context, index) do
    case fetch(raw, "contributor_ids") do
      ids when is_list(ids) and length(ids) >= 2 ->
        if length(ids) == length(Enum.uniq(ids)) do
          with :ok <- all_uuids(ids, index),
               {:ok, contributors} <- contributor_inputs(ids, inputs, context, index),
               :ok <- independent_sources(contributors, context, index) do
            {:ok, ids, inheritance(contributors)}
          end
        else
          {:error, ["items[#{index}].contributor_ids must contain at least two unique input ids"]}
        end

      _other ->
        {:error, ["items[#{index}].contributor_ids must contain at least two unique input ids"]}
    end
  end

  defp independent_sources(contributors, %{require_independent_sources?: true}, index) do
    sources =
      contributors
      |> Enum.flat_map(& &1.source_observations)
      |> MapSet.new()

    if MapSet.size(sources) >= 2,
      do: :ok,
      else:
        {:error,
         [
           "items[#{index}].contributor_ids must reference at least two distinct durable sources"
         ]}
  end

  defp independent_sources(_contributors, _context, _index), do: :ok

  defp all_uuids(ids, index) do
    if Enum.all?(ids, fn id -> is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id)) end),
      do: :ok,
      else: {:error, ["items[#{index}].contributor_ids must contain UUIDs"]}
  end

  defp contributor_inputs(ids, inputs, context, index) do
    contributors = Enum.map(ids, &Map.get(inputs, &1))

    if Enum.any?(contributors, &is_nil/1) or
         Enum.any?(
           contributors,
           &(&1.account_id != context.account_id or &1.scope_id != context.scope_id or
               &1.state != "active")
         ) do
      {:error, ["items[#{index}].contributor_ids must name active authorized inputs"]}
    else
      {:ok, contributors}
    end
  end

  defp inheritance(contributors) do
    sensitivity = Enum.max_by(contributors, &sensitivity_rank(&1.sensitivity)).sensitivity
    target_level = Enum.min_by(contributors, &target_rank(&1.target_level)).target_level
    %{sensitivity: sensitivity, target_level: target_level}
  end

  defp sensitivity_rank("public"), do: 0
  defp sensitivity_rank("internal"), do: 1
  defp sensitivity_rank("personal"), do: 2
  defp sensitivity_rank("restricted"), do: 3
  defp target_rank("peer"), do: 0
  defp target_rank("scope"), do: 1
  defp target_rank("account"), do: 2

  defp mismatch(errors, value, expected, _message) when value == expected, do: errors
  defp mismatch(errors, _value, _expected, message), do: errors ++ [message]

  defp validate_relations([], _context), do: {:ok, []}

  defp validate_relations(relations, context) do
    with {:ok, inputs} <- reasoning_inputs(context) do
      relations
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new(), []}, &validate_relation_entry(&1, &2, inputs, context))
      |> case do
        {valid, _seen, []} -> {:ok, Enum.reverse(valid)}
        {_valid, _seen, errors} -> {:error, errors}
      end
    end
  end

  defp validate_relation_entry({relation, index}, {valid, seen, errors}, inputs, context) do
    case validate_relation(relation, index, inputs, context) do
      {:ok, normalized} -> add_relation(normalized, index, valid, seen, errors)
      {:error, relation_errors} -> {valid, seen, errors ++ relation_errors}
    end
  end

  defp add_relation(normalized, index, valid, seen, errors) do
    edge = {normalized.source_id, normalized.target_id, normalized.kind}

    if MapSet.member?(seen, edge) do
      {valid, seen, errors ++ ["relations[#{index}] duplicates another relation"]}
    else
      {[normalized | valid], MapSet.put(seen, edge), errors}
    end
  end

  defp reasoning_inputs(%{reasoning_inputs: inputs}) when is_list(inputs) do
    inputs
    |> Enum.reduce_while({:ok, %{}}, fn input, {:ok, indexed} ->
      with id when is_binary(id) <- value(input, "id"),
           {:ok, ^id} <- Ecto.UUID.cast(id),
           account_id when is_binary(account_id) <- value(input, "account_id"),
           scope_id when is_binary(scope_id) <- value(input, "scope_id"),
           state when is_binary(state) <- value(input, "state") do
        {:cont,
         {:ok,
          Map.put(indexed, id, %{
            account_id: account_id,
            scope_id: scope_id,
            state: state,
            sensitivity: value(input, "sensitivity"),
            target_level: value(input, "target_level"),
            source_observations: source_observations(input)
          })}}
      else
        _other -> {:halt, {:error, ["reasoning inputs must be active knowledge rows"]}}
      end
    end)
  end

  defp reasoning_inputs(_context),
    do: {:error, ["reasoning inputs must be supplied for relations"]}

  defp source_observations(input) do
    input
    |> value("source_observations")
    |> List.wrap()
    |> Enum.reduce(MapSet.new(), fn
      observation, sources when is_map(observation) ->
        source_type = value(observation, "source_type")
        source_id = value(observation, "source_id")

        if source_type in ["message", "document"] and is_binary(source_id) and
             match?({:ok, _}, Ecto.UUID.cast(source_id)) do
          MapSet.put(sources, {source_type, source_id})
        else
          sources
        end

      _observation, sources ->
        sources
    end)
  end

  defp validate_relation(relation, index, inputs, context) when is_map(relation) do
    with {:ok, source_id} <- uuid(relation, "source_id", index),
         {:ok, target_id} <- uuid(relation, "target_id", index),
         :ok <- not_self_relation(source_id, target_id, index),
         {:ok, kind} <- relation_kind(relation, index),
         {:ok, source} <- input(source_id, "source_id", index, inputs),
         {:ok, target} <- input(target_id, "target_id", index, inputs),
         :ok <- current_account(source, "source_id", index, context),
         :ok <- current_account(target, "target_id", index, context),
         :ok <- current_scope(source, "source_id", index, context),
         :ok <- current_scope(target, "target_id", index, context),
         :ok <- active(source, "source_id", index),
         :ok <- active(target, "target_id", index) do
      {:ok, %{source_id: source_id, target_id: target_id, kind: kind}}
    end
  end

  defp validate_relation(_relation, index, _inputs, _context),
    do: {:error, ["relations[#{index}] must be an object"]}

  defp uuid(relation, field, index) do
    case value(relation, field) do
      id when is_binary(id) ->
        case Ecto.UUID.cast(id) do
          {:ok, ^id} -> {:ok, id}
          :error -> {:error, ["relations[#{index}].#{field} must be a UUID"]}
        end

      _other ->
        {:error, ["relations[#{index}].#{field} must be a UUID"]}
    end
  end

  defp not_self_relation(id, id, index),
    do: {:error, ["relations[#{index}] must not be self-referential"]}

  defp not_self_relation(_source_id, _target_id, _index), do: :ok

  defp relation_kind(relation, index) do
    case value(relation, "kind") do
      kind when kind in @relation_kinds -> {:ok, kind}
      _other -> {:error, ["relations[#{index}].kind is invalid"]}
    end
  end

  defp input(id, field, index, inputs) do
    case Map.fetch(inputs, id) do
      {:ok, input} -> {:ok, input}
      :error -> {:error, ["relations[#{index}].#{field} must name a supplied input"]}
    end
  end

  defp current_account(%{account_id: account_id}, _field, _index, %{account_id: account_id}),
    do: :ok

  defp current_account(_input, field, index, _context),
    do: {:error, ["relations[#{index}].#{field} must belong to the current account"]}

  defp current_scope(%{scope_id: scope_id}, _field, _index, %{scope_id: scope_id}), do: :ok

  defp current_scope(_input, field, index, _context),
    do: {:error, ["relations[#{index}].#{field} must be in the current scope"]}

  defp active(%{state: "active"}, _field, _index), do: :ok

  defp active(_input, field, index),
    do: {:error, ["relations[#{index}].#{field} must name active knowledge"]}

  defp has_key?(map, key),
    do:
      Map.has_key?(map, key) or
        Enum.any?(Map.keys(map), &(is_atom(&1) and Atom.to_string(&1) == key))

  defp value(map, key) when is_map(map), do: fetch(map, key)

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn {candidate, value} ->
          if is_atom(candidate) and Atom.to_string(candidate) == key, do: value
        end)
    end
  end
end

defmodule MemHouse.Model.Schema.ReasoningUpdate do
  @moduledoc """
  Narrow update/contradiction contract over existing working-set ids.

  It may classify support or contradiction edges. It cannot create a statement,
  request deletion, or emit a derived-from edge. The shared `Reasoning` caster
  still enforces Account, scope, lifecycle, UUID, cycle, and duplicate checks.
  """

  @behaviour MemHouse.Model.Schema

  @impl true
  def json_schema do
    MemHouse.Model.Schema.Reasoning.json_schema()
    |> put_in(["properties", "items", "maxItems"], 0)
    |> put_in(
      ["properties", "relations", "items", "properties", "kind", "enum"],
      ~w(supports contradicts)
    )
  end

  @impl true
  def cast(object, context) do
    with {:ok, result} <- MemHouse.Model.Schema.Reasoning.cast(object, context),
         :ok <- no_items(result.items),
         :ok <- relation_kinds(result.relations, ~w(supports contradicts), "update") do
      {:ok, result}
    end
  end

  defp no_items([]), do: :ok
  defp no_items(_items), do: {:error, ["update operation cannot create deductions"]}

  defp relation_kinds(relations, allowed, operation) do
    if Enum.all?(relations, &(&1.kind in allowed)),
      do: :ok,
      else: {:error, ["#{operation} operation contains an invalid relation kind"]}
  end
end

defmodule MemHouse.Model.Schema.ReasoningSynthesis do
  @moduledoc """
  Narrow multi-source synthesis contract.

  Every candidate names at least two contributors from the authorized bounded
  working set, and their trusted provenance must resolve to at least two
  distinct durable message or document observations. Structural relations may
  be `derived_from` only; contradiction classification belongs to the update
  operation.
  """

  @behaviour MemHouse.Model.Schema

  @impl true
  def json_schema do
    MemHouse.Model.Schema.Reasoning.json_schema()
    |> put_in(
      ["properties", "relations", "items", "properties", "kind", "enum"],
      ["derived_from"]
    )
  end

  @impl true
  def cast(object, context) do
    context = Map.put(context, :require_independent_sources?, true)

    with {:ok, result} <- MemHouse.Model.Schema.Reasoning.cast(object, context),
         :ok <- relation_kinds(result.relations) do
      {:ok, result}
    end
  end

  defp relation_kinds(relations) do
    if Enum.all?(relations, &(&1.kind == "derived_from")),
      do: :ok,
      else: {:error, ["synthesis operation contains an invalid relation kind"]}
  end
end

defmodule MemHouse.Model.Schema.DialecticAnswer do
  @moduledoc """
  The structured shape for a grounded answer to a question.

  Requires answer text, governed evidence-id citations, an explicit `abstained`
  status, and an `answer_confidence` percentage. An evidence id may identify a
  governed knowledge candidate or an authorized immutable source-message
  candidate; the response keeps the compatible list-of-strings shape. The
  status is independent of citation presence: a cited answer may abstain from a
  conclusion while explaining what the cited evidence does support.

  `answer_confidence` is the model's own probability, 0-100, that the answer it
  gave is correct. It is reported separately from `abstained` because the two
  answer different questions, but the caller may still derive one from the
  other.

  This module checks citation shape. The caller must separately verify every id was shown to the
  model.
  """

  @behaviour MemHouse.Model.Schema

  @doc """
  The answer/citations/abstained/answer_confidence object schema sent to the provider.
  """
  @impl true
  def json_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "answer" => %{"type" => "string"},
        "citations" => %{"type" => "array", "items" => %{"type" => "string"}},
        "abstained" => %{"type" => "boolean"},
        "answer_confidence" => %{
          "type" => "integer",
          "minimum" => 0,
          "maximum" => 100,
          "description" => "Probability that the completed answer is correct"
        }
      },
      "required" => ~w(answer citations abstained answer_confidence)
    }
  end

  @doc """
  Validates a dialectic response into
  `{:ok, %{answer:, citations:, abstained:, answer_confidence:}}`.

  All four fields must be present and correctly typed, with every citation a
  string and the confidence an integer percentage. Anything else returns
  `{:error, messages}` and the generator retries within its repair budget. The
  context argument is unused: unlike extraction, nothing here depends on the
  caller's scope or peers.
  """
  @impl true
  def cast(object, _context) when is_map(object) do
    answer = Map.get(object, "answer", Map.get(object, :answer))
    citations = Map.get(object, "citations", Map.get(object, :citations))
    abstained = Map.get(object, "abstained", Map.get(object, :abstained))

    confidence =
      Map.get(object, "answer_confidence", Map.get(object, :answer_confidence))

    if is_binary(answer) and is_list(citations) and Enum.all?(citations, &is_binary/1) and
         is_boolean(abstained) and is_integer(confidence) and confidence >= 0 and
         confidence <= 100 do
      {:ok,
       %{
         answer: answer,
         citations: citations,
         abstained: abstained,
         answer_confidence: confidence
       }}
    else
      {:error, ["dialectic answer does not satisfy its response schema"]}
    end
  end

  def cast(_object, _context), do: {:error, ["response must be an object"]}
end
