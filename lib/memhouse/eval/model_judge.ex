# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Eval.ModelJudge do
  @moduledoc """
  Optional live-model grader for evaluation answers.

  The judge must be independent from the model role that produced the answer and is never part of
  deterministic release guardrails. Results record judge identity and fail explicitly when live
  judging is unavailable.
  """

  alias MemHouse.Model.{Config, Gateway}

  # The schema handed to the provider. It is a request, not a guarantee: the gateway call
  # below returns whatever the provider produced without validating it, so
  # `normalized_score/2` is what actually rejects anything that is not an integer 1 to 5. A
  # small integer scale is used instead of a free float because models are far more
  # consistent rating on a fixed ordinal scale.
  @schema %{
    type: "object",
    properties: %{
      groundedness: %{type: "integer", minimum: 1, maximum: 5},
      context_relevance: %{type: "integer", minimum: 1, maximum: 5},
      answer_relevance: %{type: "integer", minimum: 1, maximum: 5}
    },
    required: [:groundedness, :context_relevance, :answer_relevance],
    additionalProperties: false
  }

  @doc """
  Resolves the judge's configuration and returns the identity recorded in a report.

  Returns a string-keyed map of the judge's provider, model, model version, prompt version,
  and pipeline version, plus its kind and method identity. The method string versions this
  model-judging procedure inside every report; changing the prompt, the scale, or the
  normalization means changing that string too, and a maintainer who does owes a changelog
  entry, regenerated stored evidence, and a note in the closest architecture document.

  Raises `ArgumentError` when the grading role and the answering role resolve to the same
  provider and model, since a self-graded answer is not independent evidence. Call it
  before a run to fail early rather than after producing unusable numbers.
  """
  def identity do
    judge = Config.resolve(:dream_reasoner, %{})
    answer = Config.resolve(:dialectic_agent, %{})

    if family(judge) == family(answer) do
      raise ArgumentError,
            "eval judge must use a different provider/model family from dialectic answers"
    end

    judge
    |> Config.provenance()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{"kind" => "model", "method" => "rag-triad-model-f11-1"})
  end

  @doc """
  Grades one answer with a live model and returns its scores for merging into a report.

  `question` is the question text, `answer` the produced answer, and `candidates` the
  retrieval candidates that were available to produce it; their text is joined into the
  context the grader sees. An approved target-side campaign supplies its exact
  `:campaign_identity` in the optional fourth argument; ordinary evaluation
  calls remain outside campaign admission.

  Returns a string-keyed map with `"model_groundedness"`, `"model_context_relevance"`, and
  `"model_answer_relevance"` as floats in the closed interval 0.0 to 1.0, plus
  `"model_judge"` holding the judge identity. The keys are prefixed so this map can be
  merged over the deterministic scores without displacing any of them.

  Raises `ArgumentError` when the independence check fails, when the provider call fails,
  or when a returned score is missing or outside the allowed range. It never returns a
  default in place of a real grade.
  """
  def score(question, answer, candidates, opts \\ []) do
    # Re-resolved per call so the independence check is enforced on every graded question,
    # not only once at the start of a run.
    identity = identity()

    context =
      Enum.map_join(candidates, "\n", fn candidate ->
        Map.get(candidate, "statement") || Map.get(candidate, "content") || ""
      end)

    messages = [
      %{
        role: "system",
        content:
          "Score groundedness, context relevance, and answer relevance from 1 to 5. Return only schema-valid JSON."
      },
      %{
        role: "user",
        content: "Question:\n#{question}\n\nContext:\n#{context}\n\nAnswer:\n#{answer}"
      }
    ]

    # One attempt, no retry: a judge that needed several tries to produce a parseable grade
    # is not producing a stable measurement, and silently retrying would hide that.
    gateway_opts =
      if campaign_identity = Keyword.get(opts, :campaign_identity) do
        [task: :eval_judge, campaign_identity: campaign_identity, campaign_role: "harness.judge"]
      else
        [task: :eval_judge]
      end

    case Gateway.structured_once(:dream_reasoner, messages, @schema, %{}, gateway_opts) do
      {:ok, value, _config} ->
        %{
          "model_groundedness" => normalized_score(value, :groundedness),
          "model_context_relevance" => normalized_score(value, :context_relevance),
          "model_answer_relevance" => normalized_score(value, :answer_relevance),
          "model_judge" => identity
        }

      {:error, error} ->
        raise ArgumentError, "model eval judge failed: #{inspect(error)}"
    end
  end

  # Maps the 1-to-5 rating onto 0.0-to-1.0 so it sits on the same scale as the lexical
  # baseline and the two can be read side by side: 1 becomes 0.0 and 5 becomes 1.0. The key
  # is looked up as both an atom and a string because providers differ in how they key
  # decoded JSON. Anything outside the scale raises rather than being clamped, since a
  # clamped value would silently turn a malformed response into a plausible-looking score.
  defp normalized_score(value, key) do
    score = Map.get(value, key) || Map.get(value, Atom.to_string(key))

    if is_integer(score) and score in 1..5 do
      (score - 1) / 4
    else
      raise ArgumentError, "model eval judge returned invalid #{key}: #{inspect(score)}"
    end
  end

  # Independence is judged on provider and model together. Two different models from one
  # provider count as independent; the same model under both roles does not.
  defp family(config), do: {config.provider, config.model}
end
