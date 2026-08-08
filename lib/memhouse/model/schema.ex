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

  A candidate includes statement, classification, confidence, sensitivity,
  target level, independent subject, operation, expiry, revalidation, and a
  validity window.

  ## Rules this module enforces

  - **Subject is independent of source.** The model names the subject itself. A
    `peer` subject must be one of the known peer keys supplied in the context,
    and a `scope` subject must be exactly the current scope path. Nothing else
    can be named, so a model cannot attach a claim to a peer or a scope the
    caller never mentioned.
  - **Evidence is derived, not asserted.** Only a peer speaking about itself is
    `direct`; every other source-to-subject relationship is `indirect`. The
    same deterministic relationship applies the third-party confidence discount.
  - **Time bounds must be coherent.** A validity window that starts after it
    ends is rejected.
  - **Nothing here activates knowledge.** A valid candidate is still only a
    proposal; it enters the `proposed` state and must pass governance before it
    is visible to retrieval.

  ## Mistakes to avoid

  - Do not relax `cast/2` to salvage partially valid output. An unparseable
    response is an error the pipeline retries, not knowledge.
  - Do not put Account content into an error message: the messages are sent
    back to the model in the repair prompt and appear in error tuples.
  """

  @behaviour MemHouse.Model.Schema

  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.Statement

  # Candidate fields taken straight from the knowledge resource's attributes.
  # `confidence_percentage` is normalized to the persisted `confidence` value
  # after validation, so it deliberately is not part of this list.
  @knowledge_fields ~w(statement kind confidence sensitivity target_level)a

  # Expiry, the revalidation due date, and the two ends of the validity window
  # are independent of each other and of when the claim was believed. All four
  # are optional and nullable, so a timeless fact simply leaves them empty.
  @temporal_fields ~w(expires_at revalidate_after relevant_from relevant_until)a

  # The only two things a statement may be about. Source is separate: who said
  # it is not who it is about.
  @subject_types ~w(peer scope)

  # What the extractor proposes doing with the candidate. `no_op` exists so the
  # model can decline explicitly instead of inventing an empty statement.
  @operations ~w(add merge supersede_candidate no_op)

  # Enumerations that the JSON schema advertises and `cast/2` re-checks. The
  # attributes themselves carry no enum constraint, so these must be kept equal
  # to the `attribute_in` validations on KnowledgeItem's `create_from_pipeline`.
  @allowed %{
    kind: ~w(fact preference event relation skill),
    sensitivity: ~w(public internal personal restricted),
    target_level: ~w(peer scope account)
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
    knowledge_properties =
      Map.new(@knowledge_fields, fn name ->
        {Atom.to_string(name), attribute_schema(name)}
      end)
      |> Map.delete("confidence")

    temporal_properties =
      Map.new(@temporal_fields, fn name ->
        {Atom.to_string(name),
         %{
           "anyOf" => [
             %{"type" => "string", "format" => "date-time"},
             %{"type" => "null"}
           ]
         }}
      end)

    candidate =
      %{
        "type" => "object",
        "description" =>
          "Return fields in this order: reasoning, statement, confidence_percentage, then the remaining fields.",
        "additionalProperties" => false,
        "properties" =>
          knowledge_properties
          |> Map.merge(temporal_properties)
          |> Map.merge(%{
            "reasoning" => %{"type" => "string", "minLength" => 1},
            "confidence_percentage" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
            "subject_type" => %{"type" => "string", "enum" => @subject_types},
            "subject_ref" => %{"type" => "string", "minLength" => 1},
            "update_operation" => %{"type" => "string", "enum" => @operations}
          }),
        "required" =>
          ~w(reasoning statement confidence_percentage kind subject_type subject_ref sensitivity target_level update_operation)
      }

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

  # Validates one candidate. The `with` chain is ordered cheapest-first and
  # stops at the first failure, so the resource changeset check — the most
  # expensive step — only runs on a candidate that is already well formed.
  # Confidence is computed rather than copied: see `source_confidence/4`.
  defp cast_item(item, context) when is_map(item) do
    with {:ok, _reasoning} <- non_empty_string(item, "reasoning"),
         {:ok, statement} <- readable_statement(item),
         {:ok, kind} <- enum(item, "kind", allowed(:kind)),
         {:ok, subject_type} <- enum(item, "subject_type", @subject_types),
         {:ok, subject_ref} <- valid_subject_ref(item, subject_type, context),
         {:ok, confidence} <- confidence(item),
         {:ok, sensitivity} <- enum(item, "sensitivity", allowed(:sensitivity)),
         {:ok, target_level} <- enum(item, "target_level", allowed(:target_level)),
         {:ok, operation} <- enum(item, "update_operation", @operations),
         {:ok, temporal} <- temporal(item),
         :ok <- temporal_order(temporal),
         casted <-
           %{
             statement: statement,
             kind: kind,
             subject_type: subject_type,
             subject_ref: subject_ref,
             confidence: source_confidence(confidence, subject_type, subject_ref, context),
             evidence_level: evidence_level(subject_type, subject_ref, context),
             sensitivity: sensitivity,
             target_level: target_level,
             update_operation: operation
           }
           |> Map.merge(temporal),
         :ok <- validate_ash_action(casted, context) do
      {:ok, casted}
    end
  end

  defp cast_item(_item, _context), do: {:error, ["candidate must be an object"]}

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
        source_message_ids: List.wrap(Map.get(context, :message_id)),
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
  defp valid_subject_ref(item, "peer", context) do
    with {:ok, ref} <- non_empty_string(item, "subject_ref") do
      if ref in Map.get(context, :known_peer_keys, []) do
        {:ok, ref}
      else
        {:error, ["subject_ref must name a known peer"]}
      end
    end
  end

  defp valid_subject_ref(item, "scope", context) do
    with {:ok, ref} <- non_empty_string(item, "subject_ref") do
      if ref == Map.fetch!(context, :scope_path) do
        {:ok, ref}
      else
        {:error, ["subject_ref must be the current scope path"]}
      end
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

  # The wire field is deliberately a human-friendly whole percentage. Providers
  # occasionally decorate an otherwise useful value (for example, `"93%"`), so
  # validation retains only digits before it checks the 1..100 interval. The
  # normalized fraction is the value that reaches governance and storage.
  defp confidence(item) do
    case fetch(item, "confidence_percentage") do
      value when is_integer(value) ->
        confidence_percentage_in_range(value)

      value when is_binary(value) ->
        case value |> String.replace(~r/[^0-9]/, "") |> Integer.parse() do
          {percentage, ""} -> confidence_percentage_in_range(percentage)
          _other -> {:error, ["confidence_percentage must be between 1 and 100"]}
        end

      _other ->
        {:error, ["confidence_percentage must be between 1 and 100"]}
    end
  end

  defp confidence_percentage_in_range(value) when value in 1..100, do: {:ok, value / 100}

  defp confidence_percentage_in_range(_value),
    do: {:error, ["confidence_percentage must be between 1 and 100"]}

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
    if DateTime.compare(from, until) in [:lt, :eq],
      do: :ok,
      else: {:error, ["relevant_from must not be after relevant_until"]}
  end

  defp temporal_order(_temporal), do: :ok

  # Third-party status comes from the resolved subject and known source peer.
  defp source_confidence(confidence, subject_type, subject_ref, context) do
    if evidence_level(subject_type, subject_ref, context) == "indirect" do
      Float.round(confidence * 0.75, 4)
    else
      confidence
    end
  end

  defp evidence_level("peer", subject_ref, %{source_peer_key: source_peer_key})
       when subject_ref == source_peer_key,
       do: "direct"

  defp evidence_level(_subject_type, _subject_ref, _context), do: "indirect"

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

defmodule MemHouse.Model.Schema.Reasoning do
  @moduledoc """
  The structured shape for background reasoning: extraction candidates plus
  typed relations between existing knowledge.

  Reasoning reuses extraction validation, including subject allowlist,
  third-party discount, and governance. It cannot mint otherwise-invalid knowledge.

  It adds `supports`, `contradicts`, and `derived_from` edges. Contradictions never overwrite.
  """

  @behaviour MemHouse.Model.Schema

  @doc """
  The extraction schema with a required `relations` array added.
  """
  @impl true
  def json_schema do
    extraction = MemHouse.Model.Schema.Extraction.json_schema()

    extraction
    |> put_in(["properties", "relations"], %{
      "type" => "array",
      "items" => %{
        "type" => "object",
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

  Candidates go through the full extraction validation, so every rule that
  applies to extracted knowledge applies here too. Relations are read by string
  key only and accepted as a list without further checking; a missing key is
  treated as no relations, while a present but non-list value is an error.
  Returns `{:error, messages}` otherwise.
  """
  @impl true
  def cast(object, context) do
    with {:ok, items} <- MemHouse.Model.Schema.Extraction.cast(object, context),
         relations when is_list(relations) <- Map.get(object, "relations", []) do
      {:ok, %{items: items, relations: relations}}
    else
      {:error, errors} -> {:error, errors}
      _other -> {:error, ["relations must be an array"]}
    end
  end
end

defmodule MemHouse.Model.Schema.DialecticAnswer do
  @moduledoc """
  The structured shape for a grounded answer to a question.

  Requires answer text, knowledge-id citations, an explicit `abstained` status,
  and an `answer_confidence` percentage. The status is independent of citation
  presence: a cited answer may abstain from a conclusion while explaining what
  the cited evidence does support.

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
        "answer_confidence" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}
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
