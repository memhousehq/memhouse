# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Schema.CompactExtraction do
  @moduledoc """
  Experimental explicit-fact extraction contract.

  The provider supplies only the claim, exact supporting text, subject/source
  references, and nullable exact text for each validity boundary. Trusted code
  derives every policy-bearing field and then delegates to `Extraction`, so the
  accepted extractor's evidence, subject, hostile-output, temporal, resource,
  and governance-admission checks remain the authority.

  Omitted fields deliberately become more restrictive: sensitivity is always
  `restricted`, a peer claim targets only that peer, a scope claim targets only
  the current scope, kind is the neutral `fact`, and explicit confidence is
  discounted by the ordinary source-to-subject rule.
  """

  @behaviour MemHouse.Model.Schema

  alias MemHouse.Model.Schema.Extraction

  import MemHouse.Model.Schema.ExtractionSupport,
    only: [beginning_of_day: 1, fetch: 2, first_person?: 1, non_empty_string: 2]

  @fields ~w(supporting_span statement subject_ref source_message_ids relevant_from_evidence relevant_until_evidence)
  @field_set MapSet.new(@fields)

  @impl true
  def json_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "items" => %{
          "type" => "array",
          "items" => candidate_json_schema(),
          "maxItems" => 24
        }
      },
      "required" => ["items"]
    }
  end

  @doc """
  Returns the minimal candidate JSON Schema for the compact extraction experiment.

  It contains only statement, exact support, subject/source references, and
  explicit valid-time evidence. Trusted code derives confidence, sensitivity,
  target level, and other policy fields before invoking the ordinary validator.
  """
  def candidate_json_schema do
    nullable_evidence = %{
      "description" =>
        "shortest exact source text naming this validity boundary; null when no boundary is explicit",
      "anyOf" => [%{"type" => "string", "minLength" => 1}, %{"type" => "null"}]
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "supporting_span" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "shortest exact source text that entails the statement"
        },
        "statement" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "one explicit, durable, self-contained atomic claim"
        },
        "subject_ref" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "one supplied participant key or the exact current scope path"
        },
        "source_message_ids" => %{
          "type" => "array",
          "items" => %{"type" => "string", "format" => "uuid"},
          "minItems" => 1,
          "uniqueItems" => true
        },
        "relevant_from_evidence" => nullable_evidence,
        "relevant_until_evidence" => nullable_evidence
      },
      "propertyOrdering" => @fields,
      "required" => @fields
    }
  end

  @impl true
  def cast(object, context) when is_map(object) and is_map(context) do
    case fetch(object, "items") do
      items when is_list(items) -> cast_items(items, context)
      _other -> {:error, ["items must be an array"]}
    end
  end

  def cast(_object, _context), do: {:error, ["response must be an object"]}

  @impl true
  def recover_after_repairs(object, context) when is_map(object) and is_map(context) do
    case fetch(object, "items") do
      items when is_list(items) ->
        {valid, invalid_count} =
          Enum.reduce(items, {[], 0}, fn item, {valid, invalid_count} ->
            case cast_items([item], context) do
              {:ok, [casted]} -> {[casted | valid], invalid_count}
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

  defp cast_items(items, context) do
    items
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {item, index}, {converted, errors} ->
      case convert(item, context) do
        {:ok, candidate} -> {[candidate | converted], errors}
        {:error, item_errors} -> {converted, errors ++ prefix(item_errors, index)}
      end
    end)
    |> case do
      {_converted, errors} when errors != [] ->
        {:error, errors}

      {converted, []} ->
        Extraction.cast(%{"items" => Enum.reverse(converted)}, context)
    end
  end

  defp convert(item, context) when is_map(item) do
    with :ok <- exact_candidate_keys(item),
         {:ok, supporting_span} <- non_empty_string(item, "supporting_span"),
         {:ok, statement} <- non_empty_string(item, "statement"),
         {:ok, subject_ref} <- non_empty_string(item, "subject_ref"),
         {:ok, subject_type} <- subject_type(supporting_span, subject_ref, context),
         {:ok, source_message_ids} <- source_ids(item),
         {:ok, relevant_from} <-
           valid_time(item, "relevant_from_evidence", source_message_ids, context),
         {:ok, relevant_until} <-
           valid_time(item, "relevant_until_evidence", source_message_ids, context) do
      {:ok,
       %{
         "supporting_span" => supporting_span,
         "statement" => statement,
         "confidence_level" => "stated_explicitly",
         "kind" => "fact",
         "subject_type" => subject_type,
         "subject_ref" => subject_ref,
         "sensitivity" => "restricted",
         "target_level" => if(subject_type == "scope", do: "scope", else: "peer"),
         "source_message_ids" => source_message_ids,
         "relevant_from" => encode_datetime(relevant_from),
         "relevant_until" => encode_datetime(relevant_until)
       }}
    end
  end

  defp convert(_item, _context), do: {:error, ["candidate must be an object"]}

  defp exact_candidate_keys(item) do
    keys =
      Enum.map(Map.keys(item), fn
        key when is_binary(key) -> key
        key when is_atom(key) -> Atom.to_string(key)
        _key -> :invalid
      end)

    if MapSet.new(keys) == @field_set,
      do: :ok,
      else: {:error, ["candidate contains unsupported fields or omits required fields"]}
  end

  defp source_ids(item) do
    case fetch(item, "source_message_ids") do
      ids when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &is_binary/1) and length(ids) == length(Enum.uniq(ids)),
          do: {:ok, ids},
          else: {:error, ["source_message_ids must be a non-empty unique string array"]}

      _other ->
        {:error, ["source_message_ids must be a non-empty unique string array"]}
    end
  end

  defp valid_time(item, field, source_ids, context) do
    case fetch(item, field) do
      nil ->
        {:ok, nil}

      evidence when is_binary(evidence) ->
        evidence = String.trim(evidence)

        with :ok <- exact_temporal_evidence(evidence, source_ids, context) do
          resolve_temporal_evidence(evidence, Map.get(context, :occurred_at))
        end

      _other ->
        {:error, ["#{field} must be exact source text or null"]}
    end
  end

  defp exact_temporal_evidence("", _source_ids, _context),
    do: {:error, ["valid-time evidence is unsupported"]}

  defp exact_temporal_evidence(evidence, source_ids, context) do
    texts =
      context
      |> Map.get(:window_messages, [])
      |> Enum.filter(&(fetch(&1, "id") in source_ids))
      |> Enum.map(&fetch(&1, "content"))

    if texts != [] and Enum.all?(texts, &is_binary/1) and
         Enum.any?(texts, &String.contains?(&1, evidence)) do
      :ok
    else
      {:error, ["valid-time evidence must be exact text from a cited source"]}
    end
  end

  defp resolve_temporal_evidence(evidence, occurred_at) do
    with :error <- resolve_iso_datetime(evidence),
         :error <- resolve_iso_date(evidence),
         :error <-
           MemHouse.Model.Schema.ExtractionSupport.resolve_relative_datetime(
             evidence,
             occurred_at
           ) do
      {:error, ["valid-time evidence is unsupported"]}
    end
  end

  defp resolve_iso_datetime(evidence) do
    case DateTime.from_iso8601(evidence) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp resolve_iso_date(evidence) do
    case Date.from_iso8601(evidence) do
      {:ok, date} -> {:ok, beginning_of_day(date)}
      {:error, _reason} -> :error
    end
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(datetime), do: DateTime.to_iso8601(datetime)

  defp subject_type(supporting_span, subject_ref, context) do
    scope? = subject_ref == Map.get(context, :scope_path)

    cond do
      first_person?(supporting_span) and scope? ->
        {:error, ["subject_ref must not name the scope for first-person evidence"]}

      first_person?(supporting_span) ->
        {:ok, "peer"}

      scope? ->
        {:ok, "scope"}

      true ->
        {:ok, "peer"}
    end
  end

  defp prefix(errors, index), do: Enum.map(errors, &"items[#{index}].#{&1}")
end

defmodule MemHouse.Model.Schema.CompactExtractionBatch do
  @moduledoc """
  Per-anchor wrapper for the compact extraction candidate.

  Batch ownership and attribution remain in `ExtractionBatch`; this module only
  selects the smaller inner contract.
  """

  @behaviour MemHouse.Model.Schema

  alias MemHouse.Model.Schema.CompactExtraction
  alias MemHouse.Model.Schema.ExtractionBatch

  @impl true
  def json_schema, do: ExtractionBatch.json_schema(CompactExtraction)

  @impl true
  def cast(object, context) do
    ExtractionBatch.cast(object, Map.put(context, :candidate_schema, CompactExtraction))
  end

  @impl true
  def recover_after_repairs(object, context) do
    ExtractionBatch.recover_after_repairs(
      object,
      Map.put(context, :candidate_schema, CompactExtraction)
    )
  end
end
