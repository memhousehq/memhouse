# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Embedding.Ortex do
  @moduledoc """
  Runs a local ONNX sentence-embedding model: tokenize, infer, pool, normalize.

  ## Offline by construction

  Operator-supplied model and tokenizer paths must name regular files. Nothing is downloaded or
  substituted, and embedded text never leaves the machine.

  ## What the pipeline does, and why each step matters

  1. **Tokenize as a batch.** Truncate at the configured maximum and pad only to the longest
     sequence in the batch.
  2. **Run the graph** with the input tensors in the order the export expects.
  3. **Pool** rank-3 token states by first token, masked mean, or last unmasked token; use rank-2
     vectors as-is. Pooling must match training, and masked pooling excludes padding.
  4. **L2-normalize** so dot product equals cosine similarity.

  ## Caching

  `:persistent_term` caches tokenizer and model by artifact path and `:cache_key`. It is
  rebuildable; the provider includes model version in the key so version changes reload files.

  ## Mistakes to avoid

  - Do not change pooling, sequence length, or artifacts without bumping the
    embedder's model version. All of them change the coordinates, and vectors
    are only reusable when the full identity matches.
  - Do not add a network fetch for a missing artifact. Failing is the feature.
  """

  use AshAi.EmbeddingModel

  alias Tokenizers.Encoding
  alias Tokenizers.Tokenizer

  # Tokens per text. Longer inputs are truncated. Bounds inference cost, which
  # grows with sequence length, while comfortably covering a typical statement.
  @default_max_length 256

  # Input tensor order for the standard encoder export. Must match the graph's
  # own signature; a model exported with different inputs configures its own.
  @default_input_order ~w(input_ids attention_mask token_type_ids)

  @doc """
  The vector width, taken from the caller's options.

  Raises `KeyError` when no width was supplied: silently guessing a width would
  produce vectors that do not fit the stored columns and their indexes.
  """
  @impl true
  def dimensions(opts), do: Keyword.fetch!(opts, :dimensions)

  @doc """
  Embeds a list of texts, returning `{:ok, vectors}` in input order.

  Options: `:model_path` and `:tokenizer_path` (both required, and both must
  point at existing files), `:cache_key`, `:execution_providers`, `:max_length`,
  `:input_order`, `:output_index`, and `:pooling`.

  Every returned vector is L2-normalized. Failure modes:
  `{:error, {:model_artifact_missing, key}}` when an artifact path is absent or
  does not exist, `{:error, {:ortex_inference_failed, exception_module}}` when
  the runtime raises — only the exception's module name is reported, never its
  message, since a runtime message can quote the text being embedded.
  """
  @impl true
  def generate(texts, opts) when is_list(texts) do
    with {:ok, model_path} <- artifact(opts, :model_path),
         {:ok, tokenizer_path} <- artifact(opts, :tokenizer_path),
         cache_key = Keyword.get(opts, :cache_key),
         {:ok, tokenizer} <- cached_tokenizer(tokenizer_path, cache_key),
         {:ok, model} <-
           cached_model(
             model_path,
             Keyword.get(opts, :execution_providers, [:cpu]),
             cache_key
           ),
         {:ok, encoded} <- encode(tokenizer, texts, opts) do
      run(model, encoded, opts)
    end
  rescue
    error -> {:error, {:ortex_inference_failed, error.__struct__}}
  end

  @doc """
  Counts the tokens the same encoding pass would produce for `texts`.

  Sums the attention masks, so padding is excluded and the number reflects real
  tokens rather than padded tensor width. Takes the same options as
  `generate/2`, but only reads the tokenizer, so its one artifact failure is
  `{:error, {:model_artifact_missing, :tokenizer_path}}`. Otherwise returns
  `{:ok, count}`.

  Reported to the usage ledger so local embedding spend is measured, not
  estimated, even though local tokens cost nothing to buy.
  """
  def token_count(texts, opts) do
    with {:ok, tokenizer_path} <- artifact(opts, :tokenizer_path),
         {:ok, tokenizer} <- cached_tokenizer(tokenizer_path, Keyword.get(opts, :cache_key)),
         {:ok, encoded} <- encode(tokenizer, texts, opts) do
      {:ok, encoded.attention_mask |> List.flatten() |> Enum.sum()}
    end
  end

  # Requires an existing regular file. A missing artifact is an error, never an
  # occasion to download one or fall back to a different model: the vectors a
  # substitute produced would be silently incomparable with the stored corpus.
  defp artifact(opts, key) do
    case Keyword.get(opts, key) do
      path when is_binary(path) and path != "" ->
        if File.regular?(path), do: {:ok, path}, else: {:error, {:model_artifact_missing, key}}

      _other ->
        {:error, {:model_artifact_missing, key}}
    end
  end

  defp cached_tokenizer(path, model_key) do
    cache({__MODULE__, :tokenizer, model_key, path}, fn -> Tokenizer.from_file(path) end)
  end

  defp cached_model(path, execution_providers, model_key) do
    cache({__MODULE__, :model, model_key, path, execution_providers}, fn ->
      {:ok, Ortex.load(path, execution_providers)}
    end)
  end

  # Rebuildable process-wide cache for expensive-to-load artifacts.
  #
  # `:persistent_term` is right here because these values are written once and
  # read on every embedding call; it holds nothing durable, so losing it on
  # restart costs only a reload. Cache keys include the artifact path and the
  # caller's `:cache_key`, which carries the model version, so nothing stale is
  # served after a version bump. A failed load is not cached, leaving the next
  # call free to retry.
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

  # Tokenizes a batch into equal-length sequences.
  #
  # ONNX Runtime needs a rectangular tensor, so every sequence is truncated and
  # padded to one target length. That length is the longest sequence present,
  # capped at the maximum — padding to the cap unconditionally would make a
  # batch of short texts as expensive as a batch of long ones. `Enum.max/2` is
  # given a fallback so an empty batch yields length 1 rather than raising.
  #
  # Nil texts are coerced to empty strings; a caller passing a nil should get an
  # embedding of nothing, not a crash deep inside the tokenizer.
  defp encode(tokenizer, texts, opts) do
    max_length = Keyword.get(opts, :max_length, @default_max_length)

    with {:ok, encodings} <- Tokenizer.encode_batch(tokenizer, Enum.map(texts, &(&1 || ""))) do
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

  # Runs inference and reduces the output to one normalized vector per text.
  #
  # Input tensors are built in the configured order because ONNX inputs are
  # positional, and they are s64 because token ids and masks are integers.
  # `backend_transfer` pulls the result out of the runtime's own memory before
  # it is read.
  #
  # Output rank decides what happens next: rank 2 is already one vector per
  # text, rank 3 is per-token hidden states that must be pooled. Any other rank
  # means the configured artifact is not a sentence-embedding export, which
  # raises rather than being guessed at.
  defp run(model, encoded, opts) do
    inputs =
      opts
      |> Keyword.get(:input_order, @default_input_order)
      |> Enum.map(fn name ->
        encoded
        |> Map.fetch!(normalize_input_name(name))
        |> Nx.tensor(type: :s64)
      end)
      |> List.to_tuple()

    output =
      model
      |> Ortex.run(inputs)
      |> Tuple.to_list()
      |> Enum.at(Keyword.get(opts, :output_index, 0))
      |> Nx.backend_transfer()

    vectors =
      case Nx.shape(output) do
        {_batch, _dimensions} ->
          Nx.to_list(output)

        {_batch, _sequence, _dimensions} ->
          pool(Nx.to_list(output), encoded.attention_mask, Keyword.get(opts, :pooling, :cls))

        shape ->
          raise ArgumentError, "unsupported embedding output rank #{tuple_size(shape)}"
      end

    {:ok, Enum.map(vectors, &normalize/1)}
  end

  # Averages token vectors, counting only unmasked positions.
  #
  # Skipping masked positions is the whole point: including padding would pull
  # every short text's vector toward the padding token's embedding and make
  # similarity depend on batch composition. The divisor is floored at 1 so an
  # all-masked row yields zeros instead of dividing by zero.
  defp mean_pool(hidden_batches, masks) do
    Enum.zip_with(hidden_batches, masks, fn hidden, mask ->
      dimensions = hidden |> List.first([]) |> length()

      {sum, count} =
        Enum.zip(hidden, mask)
        |> Enum.reduce({List.duplicate(0.0, dimensions), 0}, fn
          {token, 1}, {sum, count} ->
            {Enum.zip_with(sum, token, &(&1 + &2)), count + 1}

          {_token, _masked}, acc ->
            acc
        end)

      divisor = max(count, 1)
      Enum.map(sum, &(&1 / divisor))
    end)
  end

  # CLS pooling takes the first token's vector, which is what models trained
  # with a sentence-level classification token expect. Which strategy is correct
  # is a property of the model, not a tuning knob.
  defp pool(hidden_batches, _masks, :cls), do: Enum.map(hidden_batches, &List.first/1)
  defp pool(hidden_batches, masks, :mean), do: mean_pool(hidden_batches, masks)
  defp pool(hidden_batches, masks, :last_token), do: last_token_pool(hidden_batches, masks)

  @doc """
  Returns each batch row's final unmasked token vector.

  Decoder embedding models use this pooling rule. Selecting the final padded
  position would return a valid-shaped but semantically wrong vector.
  """
  def last_token_pool(hidden_batches, masks) do
    Enum.zip_with(hidden_batches, masks, fn hidden, mask ->
      hidden
      |> Enum.zip(mask)
      |> Enum.reduce(nil, fn
        {token, 1}, _last -> token
        {_token, _masked}, last -> last
      end)
      |> case do
        nil -> List.duplicate(0.0, hidden |> List.first([]) |> length())
        token -> token
      end
    end)
  end

  # L2-normalizes to unit length so that a dot product equals cosine similarity.
  # Retrieval scoring assumes this; skipping it would make similarity depend on
  # vector magnitude and quietly favour longer texts. A zero vector is returned
  # unchanged because it has no direction to preserve.
  defp normalize(vector) do
    magnitude = vector |> Enum.reduce(0.0, &(&2 + &1 * &1)) |> :math.sqrt()
    if magnitude == 0.0, do: vector, else: Enum.map(vector, &(&1 / magnitude))
  end

  # Only the three known encoder input names are recognized as strings, and no
  # atom is created from configuration. An unrecognized string raises rather
  # than being skipped, because a silently missing input tensor would produce
  # vectors that look fine and mean nothing. An atom passes through and then
  # fails on the `Map.fetch!` above if it names no encoded tensor.
  defp normalize_input_name(name) when is_atom(name), do: name
  defp normalize_input_name("input_ids"), do: :input_ids
  defp normalize_input_name("attention_mask"), do: :attention_mask
  defp normalize_input_name("token_type_ids"), do: :token_type_ids

  defp normalize_input_name(name),
    do: raise(ArgumentError, "unsupported ONNX embedding input #{inspect(name)}")
end

defmodule MemHouse.Model.Embedding.ReqLLM do
  @moduledoc """
  An `AshAi.EmbeddingModel` backed by an HTTP endpoint, delegating both
  callbacks straight to the library's own adapter.

  It exists so the API-backed option is named next to the local ONNX one.
  Nothing in the current build selects it: the model layer reaches an HTTP
  embedding endpoint through `MemHouse.Model.Providers.ReqLLM` instead, and no
  resource declares an `AshAi` vectorized attribute.

  Embedding through an endpoint means embedded text leaves the machine, and it
  is a change of embedding identity: moving between local and hosted embedders
  requires a version bump and a full re-embed, because their vectors are not
  comparable.
  """

  use AshAi.EmbeddingModel

  @doc """
  The vector width for the configured endpoint's model.
  """
  @impl true
  defdelegate dimensions(opts), to: AshAi.EmbeddingModels.ReqLLM

  @doc """
  Embeds texts through the configured endpoint, returning vectors in input order.
  """
  @impl true
  defdelegate generate(texts, opts), to: AshAi.EmbeddingModels.ReqLLM
end
