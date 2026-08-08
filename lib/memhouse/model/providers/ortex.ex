# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Providers.Ortex do
  @moduledoc """
  Provider adapter for the local ONNX embedding runtime.

  Provides offline embedding only; generation and reranking fail explicitly. Role options select
  artifacts, sequence length, pooling, and execution providers. Coordinate-changing options
  require a `model_version` bump and re-embedding.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Config.Role
  alias MemHouse.Model.Embedding.Ortex
  alias MemHouse.Model.Provider.Result

  @doc """
  Not supported: this is an embedding runtime and cannot generate objects.
  """
  @impl true
  def structured(_config, _messages, _schema, _opts),
    do: {:error, :ortex_is_embedding_only}

  @doc """
  Not supported: this is an embedding runtime and cannot generate text.
  """
  @impl true
  def chat(_config, _messages, _opts), do: {:error, :ortex_is_embedding_only}

  @doc """
  Embeds texts locally and reports the tokens the tokenizer actually produced.

  Token counts come from the tokenizer, not an estimate, for capacity accounting.
  """
  @impl true
  def embed(%Role{} = config, texts, request_opts) do
    opts = embedding_opts(config)
    texts = apply_query_instruction(texts, config.options, request_opts)

    with {:ok, vectors, tokens} <- Ortex.generate(texts, opts) do
      {:ok,
       %Result{
         value: vectors,
         usage: %{embedding_tokens: tokens},
         metadata: %{vector_count: length(vectors)}
       }}
    end
  end

  @doc """
  Not supported: an embedding model has no cross-encoder to rerank with.
  """
  @impl true
  def rerank(_config, _query, _documents, _opts),
    do: {:error, :ortex_embedding_model_cannot_rerank}

  # Provider/model/version keys cached sessions; identity changes load fresh artifacts.
  defp embedding_opts(config) do
    options = config.options

    [
      dimensions: config.embedding_dimensions,
      cache_key: {config.provider, config.model, config.model_version},
      model_path: Map.get(options, "model_path"),
      tokenizer_path: Map.get(options, "tokenizer_path"),
      # Tokens per text; 256 covers typical chunks while bounding inference cost.
      max_length: Map.get(options, "max_length", 256),
      # Output tensor index; 0 fits the shipped single-output encoder.
      output_index: Map.get(options, "output_index", 0),
      # Input order must match the exported graph signature.
      input_order: Map.get(options, "input_order", ~w(input_ids attention_mask token_type_ids)),
      # Pooling must match training; changes require a version bump and re-embed.
      pooling: pooling(Map.get(options, "pooling", "cls")),
      execution_providers:
        options
        |> Map.get("execution_providers", ["cpu"])
        |> Enum.map(&execution_provider/1)
    ]
  end

  # Unknown backend strings fall back to portable CPU; known runtime atoms pass through.
  defp execution_provider("cpu"), do: :cpu
  defp execution_provider("coreml"), do: :coreml
  defp execution_provider("cuda"), do: :cuda
  defp execution_provider("tensorrt"), do: :tensorrt
  defp execution_provider(provider) when is_atom(provider), do: provider
  defp execution_provider(_provider), do: :cpu

  @doc """
  Applies the configured instruction prefix to query embeddings only.

  Stored statements and document chunks must stay unprefixed. Their vectors are
  the retrieval corpus, not queries.
  """
  def apply_query_instruction(texts, options, opts) do
    instruction = Map.get(options, "query_instruction")

    if Keyword.get(opts, :input_type, :passage) == :query and is_binary(instruction) and
         instruction != "" do
      prefix = String.replace(instruction, "\\n", "\n")
      Enum.map(texts, &(prefix <> &1))
    else
      texts
    end
  end

  # Anything except a declared pooling strategy uses the documented CLS default.
  defp pooling("mean"), do: :mean
  defp pooling(:mean), do: :mean
  defp pooling("last_token"), do: :last_token
  defp pooling(:last_token), do: :last_token
  defp pooling(_pooling), do: :cls
end
