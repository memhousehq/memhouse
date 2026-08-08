# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Reranking.Ortex do
  @moduledoc """
  Runs a local ONNX cross-encoder over query-document pairs.

  The caller supplies pinned artifacts. This module never downloads or substitutes
  a model. It returns one numeric score per pair in the original input order.
  """

  alias Tokenizers.Encoding
  alias Tokenizers.Tokenizer

  @default_input_order ~w(input_ids attention_mask token_type_ids)
  @default_max_length 512

  @doc """
  Scores `{query, document}` pairs with the configured classifier.

  Returns `{:error, {:model_artifact_missing, key}}` when an artifact is absent.
  Inference errors contain only the exception module, because an exception can
  include supplied query or document text.
  """
  def score(pairs, opts) when is_list(pairs) do
    with {:ok, model_path} <- artifact(opts, :model_path),
         {:ok, tokenizer_path} <- artifact(opts, :tokenizer_path),
         {:ok, tokenizer} <- cached_tokenizer(tokenizer_path, Keyword.get(opts, :cache_key)),
         {:ok, model} <-
           cached_model(
             model_path,
             Keyword.get(opts, :execution_providers, [:cpu]),
             Keyword.get(opts, :cache_key)
           ),
         {:ok, encoded} <- encode_pairs(tokenizer, pairs, opts) do
      {:ok, run(model, encoded, opts), token_count(encoded)}
    end
  rescue
    error -> {:error, {:ortex_inference_failed, error.__struct__}}
  end

  defp artifact(opts, key) do
    case Keyword.get(opts, key) do
      path when is_binary(path) and path != "" ->
        if File.regular?(path), do: {:ok, path}, else: {:error, {:model_artifact_missing, key}}

      _other ->
        {:error, {:model_artifact_missing, key}}
    end
  end

  defp cached_tokenizer(path, cache_key) do
    cache({__MODULE__, :tokenizer, cache_key, path}, fn -> Tokenizer.from_file(path) end)
  end

  defp cached_model(path, execution_providers, cache_key) do
    cache({__MODULE__, :model, cache_key, path, execution_providers}, fn ->
      {:ok, Ortex.load(path, execution_providers)}
    end)
  end

  # Sessions are rebuildable process-local caches. The artifact path and pinned
  # model identity make a version change load a fresh session.
  defp cache(key, loader) do
    case :persistent_term.get(key, :missing) do
      :missing ->
        with {:ok, value} <- loader.() do
          :persistent_term.put(key, value)
          {:ok, value}
        end

      value ->
        {:ok, value}
    end
  end

  defp encode_pairs(tokenizer, pairs, opts) do
    max_length = Keyword.get(opts, :max_length, @default_max_length)

    inputs = Enum.map(pairs, fn {query, document} -> {query || "", document || ""} end)

    with {:ok, encodings} <- Tokenizer.encode_batch(tokenizer, inputs) do
      target_length =
        encodings
        |> Enum.map(&min(Encoding.get_length(&1), max_length))
        |> Enum.max(fn -> 1 end)

      encodings =
        Enum.map(encodings, fn encoding ->
          encoding
          |> Encoding.truncate(target_length)
          |> Encoding.pad(target_length)
        end)

      {:ok,
       %{
         input_ids: Enum.map(encodings, &Encoding.get_ids/1),
         attention_mask: Enum.map(encodings, &Encoding.get_attention_mask/1),
         token_type_ids: Enum.map(encodings, &Encoding.get_type_ids/1)
       }}
    end
  end

  defp run(model, encoded, opts) do
    inputs =
      opts
      |> Keyword.get(:input_order, @default_input_order)
      |> Enum.map(fn name ->
        encoded
        |> Map.fetch!(input_name(name))
        |> Nx.tensor(type: :s64)
      end)
      |> List.to_tuple()

    logits =
      model
      |> Ortex.run(inputs)
      |> Tuple.to_list()
      |> Enum.at(Keyword.get(opts, :output_index, 0))
      |> Nx.backend_transfer()
      |> Nx.to_list()

    Enum.map(logits, &score_from_logits(&1, opts))
  end

  # A one-logit cross-encoder uses that logit directly. A multi-class export
  # must name its relevant class explicitly, so its ordering is never guessed.
  defp score_from_logits(value, _opts) when is_number(value), do: value * 1.0

  defp score_from_logits(values, opts) when is_list(values) do
    index = Keyword.get(opts, :positive_class_index, 0)

    case Enum.at(values, index) do
      value when is_number(value) -> value * 1.0
      _other -> raise ArgumentError, "cross-encoder output has no configured score class"
    end
  end

  defp token_count(encoded), do: encoded.attention_mask |> List.flatten() |> Enum.sum()

  defp input_name(name) when is_atom(name), do: name
  defp input_name("input_ids"), do: :input_ids
  defp input_name("attention_mask"), do: :attention_mask
  defp input_name("token_type_ids"), do: :token_type_ids
  defp input_name(_name), do: raise(ArgumentError, "unsupported cross-encoder input")
end
