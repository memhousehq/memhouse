# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.Durability do
  @moduledoc """
  Classifies extracted statements for a content-safe durability audit.

  The audit receives statements only after the ordinary ingest and extraction
  path has produced them. It returns aggregate counts, never statements,
  identifiers, prompts, or model responses. A deterministic mode supports
  repeatable local checks. A model mode is for the issue-160 evidence run and
  requires the configured reasoning model to differ from the extractor.
  """

  alias MemHouse.Model.{Config, Gateway}

  @categories ~w(
    durable
    greeting_or_small_talk
    question
    speech_act_transcription
    subjectless_generic
    other_non_durable
  )

  @model_schema %{
    type: "object",
    properties: %{
      classification: %{type: "string", enum: @categories}
    },
    required: [:classification],
    additionalProperties: false
  }

  @doc """
  Audits one list of extracted statements per source message.

  Options are `:judge` (`"deterministic"` or `"model"`), `:sample`, and
  `:seed`. Sampling uses a stable hash of the statement id and seed. The result
  contains counts only, so it is safe to store with evaluation evidence.
  """
  def audit(extractions, opts \\ []) when is_list(extractions) do
    judge = Keyword.get(opts, :judge, "deterministic")
    seed = Keyword.get(opts, :seed, "durability-audit-v1")

    items =
      extractions
      |> List.flatten()
      |> Enum.filter(&(is_binary(Map.get(&1, "id")) and is_binary(Map.get(&1, "statement"))))
      |> sample(Keyword.get(opts, :sample), seed)

    categories =
      items
      |> Enum.map(&classify(&1["statement"], judge))
      |> Enum.frequencies()
      |> complete_categories()

    durable = Map.fetch!(categories, "durable")

    %{
      "method" => method(judge),
      "judge" => judge_identity(judge),
      "available" => extractions |> List.flatten() |> length(),
      "sampled" => length(items),
      "sample_seed" => seed,
      "categories" => categories,
      "durable" => durable,
      "noise" => length(items) - durable,
      "messages" => message_yield(extractions)
    }
  end

  @doc """
  Returns the supported audit category names.
  """
  def categories, do: @categories

  defp classify(statement, "deterministic"), do: deterministic_classification(statement)

  defp classify(statement, "model") do
    ensure_independent_model!()

    messages = [
      %{
        role: "system",
        content: """
        Classify one stored memory statement. Durable means a stable fact,
        preference, relationship, possession, skill, commitment, plan, or an
        event with a lasting consequence. Greetings, reactions, questions,
        speech-act transcriptions, and claims without a subject are noise.
        Return only the requested JSON classification.
        """
      },
      %{role: "user", content: statement}
    ]

    case Gateway.structured_once(:dream_reasoner, messages, @model_schema, %{},
           task: :durability_audit
         ) do
      {:ok, value, _config} ->
        classification = Map.get(value, :classification) || Map.get(value, "classification")

        if classification in @categories do
          classification
        else
          raise ArgumentError, "durability judge returned an invalid classification"
        end

      {:error, error} ->
        raise ArgumentError, "durability judge failed: #{inspect(error)}"
    end
  end

  defp classify(_statement, judge),
    do: raise(ArgumentError, "unknown durability judge: #{inspect(judge)}")

  defp deterministic_classification(statement) do
    cond do
      String.contains?(statement, "?") ->
        "question"

      String.match?(
        statement,
        ~r/\b(?:said|says|told|asked|greeted|replied|mentioned|wrote|texted)\b/iu
      ) ->
        "speech_act_transcription"

      String.match?(statement, ~r/\A(?:Hi|Hello|Hey|Thanks|Thank you|Great job|Nice work)\b/iu) ->
        "greeting_or_small_talk"

      String.match?(statement, ~r/\A(?:Running|Exercise|Sleep|Travel|Work)\s+(?:can|is|does)\b/u) ->
        "subjectless_generic"

      true ->
        "durable"
    end
  end

  defp sample(items, nil, _seed), do: items

  defp sample(items, limit, seed) when is_integer(limit) and limit > 0 do
    items
    |> Enum.sort_by(&sample_key(&1, seed))
    |> Enum.take(limit)
  end

  defp sample(items, _limit, _seed), do: items

  defp sample_key(item, seed) do
    :crypto.hash(:sha256, "#{seed}:#{item["id"]}")
  end

  defp complete_categories(counts) do
    Map.new(@categories, &{&1, Map.get(counts, &1, 0)})
  end

  defp message_yield(extractions) do
    counts =
      Enum.frequencies_by(extractions, fn items ->
        case items do
          [] -> "zero"
          [_item] -> "one"
          _items -> "multiple"
        end
      end)

    %{
      "zero" => Map.get(counts, "zero", 0),
      "one" => Map.get(counts, "one", 0),
      "multiple" => Map.get(counts, "multiple", 0)
    }
  end

  defp method("deterministic"), do: "deterministic-durability-f11-1"
  defp method("model"), do: "model-durability-f11-1"

  defp judge_identity("deterministic"),
    do: %{"kind" => "deterministic", "method" => method("deterministic")}

  defp judge_identity("model") do
    config = Config.resolve(:dream_reasoner, %{})

    config
    |> Config.provenance()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{"kind" => "model", "method" => method("model")})
  end

  defp ensure_independent_model! do
    judge = Config.resolve(:dream_reasoner, %{})
    extractor = Config.resolve(:ingest_extractor, %{})

    if {judge.provider, judge.model} == {extractor.provider, extractor.model} do
      raise ArgumentError,
            "durability judge must use a different provider/model family from ingest extraction"
    end
  end
end
