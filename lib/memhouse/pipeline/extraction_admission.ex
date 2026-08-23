# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.ExtractionAdmission do
  @moduledoc """
  Deterministic token-budget selection and whole-request admission for extraction batches.

  MemHouse cannot assume that every hosted provider exposes the tokenizer for
  every routed model. The default admission tokenizer therefore counts UTF-8
  bytes as tokens. It is deliberately conservative, deterministic on every
  node, and versioned as `utf8-bytes-v1`. A later exact tokenizer is a new
  identity, never a silent change to an experiment.

  Batch selection counts the complete serialized anchor records, including
  their bounded evidence windows. Final admission counts the serialized system
  and user messages plus the JSON schema, then reserves configured output and
  safety-margin tokens. Provider-reported usage is accounting after the call;
  it never decides whether the call was safe to make.
  """

  @allowed_targets [128, 1_024, 4_096, 16_384]
  @tokenizer "utf8-bytes-v1"

  @type decision ::
          {:ok, %{input_tokens: non_neg_integer(), identity: String.t()}}
          | {:error,
             %{reason_class: String.t(), input_tokens: non_neg_integer(), identity: String.t()}}

  @doc "Returns the supported evaluation batch targets."
  def allowed_targets, do: @allowed_targets

  @doc "True only when the experimental adjacent-anchor execution path is enabled."
  def enabled? do
    case Keyword.fetch!(Application.fetch_env!(:memhouse, :extraction_batching), :enabled) do
      enabled when is_boolean(enabled) ->
        enabled

      invalid ->
        raise ArgumentError,
              "extraction batching enabled flag must be boolean: #{inspect(invalid)}"
    end
  end

  @doc "Returns the pinned provider-independent tokenizer identity."
  def tokenizer, do: @tokenizer

  @doc "Returns the validated batching configuration and its experiment identity."
  def config do
    configured = Application.fetch_env!(:memhouse, :extraction_batching)
    target = Keyword.fetch!(configured, :target_tokens)

    unless target in @allowed_targets do
      raise ArgumentError,
            "extraction batch target must be one of #{inspect(@allowed_targets)}, got: #{inspect(target)}"
    end

    configured
    |> Keyword.put(:tokenizer, @tokenizer)
    |> Keyword.put(:identity, identity(configured))
  end

  @doc """
  Selects an adjacent prefix toward the configured batch target.

  The first anchor is always selected so an oversized anchor can make progress;
  later anchors are added only while the target still fits. `admit/2` remains
  the final whole-request admission check.
  """
  def select_prefix(anchors, cost_fn \\ &count/1)
      when is_list(anchors) and is_function(cost_fn, 1) do
    %{target_tokens: target, max_anchors: max_anchors} = Map.new(config())

    anchors
    |> Enum.take(max_anchors)
    |> Enum.reduce_while({[], 0}, fn anchor, {selected, tokens} ->
      anchor_tokens = cost_fn.(anchor)

      cond do
        selected == [] -> {:cont, {[anchor], anchor_tokens}}
        tokens + anchor_tokens <= target -> {:cont, {[anchor | selected], tokens + anchor_tokens}}
        true -> {:halt, {selected, tokens}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "Checks the complete serialized provider request before it is sent."
  @spec admit(term(), term()) :: decision()
  def admit(messages, schema) do
    configured = Map.new(config())
    input_tokens = count(%{"messages" => messages, "schema" => schema})
    identity = configured.identity

    if input_tokens + configured.reserved_output_tokens + configured.safety_margin_tokens <=
         configured.context_limit_tokens do
      {:ok, %{input_tokens: input_tokens, identity: identity}}
    else
      {:error, %{reason_class: "oversized", input_tokens: input_tokens, identity: identity}}
    end
  end

  @doc "Counts the canonical JSON encoding with the pinned tokenizer."
  def count(value), do: value |> Jason.encode!() |> byte_size()

  defp identity(configured) do
    Enum.join(
      [
        @tokenizer,
        "target=#{Keyword.fetch!(configured, :target_tokens)}",
        "context=#{Keyword.fetch!(configured, :context_limit_tokens)}",
        "output=#{Keyword.fetch!(configured, :reserved_output_tokens)}",
        "margin=#{Keyword.fetch!(configured, :safety_margin_tokens)}"
      ],
      ":"
    )
  end
end
