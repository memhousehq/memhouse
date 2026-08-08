# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Documents.Parser do
  @moduledoc """
  Extracts normalized text from document bytes in-process.

  Markdown is parsed and re-rendered canonically; valid UTF-8 text, CSV, and JSON pass through;
  other formats use native extraction. Results report a content-safe parser name. Never put
  extracted text in telemetry, audit, or job arguments. Failures return error tuples for retry.
  """

  @markdown_types ~w(text/markdown text/x-markdown)
  # These valid UTF-8 formats already contain their final text.
  @plain_types ~w(text/plain text/csv application/json)

  @doc """
  Extracts text from `bytes` according to `media_type`.

  Returns `{:ok, %{text: text, metadata: metadata, format: :markdown | :plaintext}}`. The
  `format` is what the chunker uses to pick boundary rules, and `metadata` always carries a
  `"parser"` key naming the route taken.

  Returns `{:error, :invalid_utf8_markdown}` for Markdown that is not valid UTF-8, the parser's
  own error for Markdown that will not parse or render, and
  `{:error, {:document_extraction_failed, reason}}` when the native extractor fails.

  Note that a declared plain-text type whose bytes are *not* valid UTF-8 does not fail here: it
  falls through to the native extractor, which is better placed to guess an encoding.
  """
  def extract(bytes, media_type) when is_binary(bytes) and is_binary(media_type) do
    cond do
      media_type in @markdown_types ->
        extract_markdown(bytes)

      media_type in @plain_types and String.valid?(bytes) ->
        {:ok, %{text: bytes, metadata: %{"parser" => "text"}, format: :plaintext}}

      true ->
        extract_native(bytes, media_type)
    end
  end

  # Round-trip for canonical Markdown; node count is a content-free structural size.
  defp extract_markdown(bytes) do
    with true <- String.valid?(bytes),
         {:ok, document} <- MDEx.parse_document(bytes),
         {:ok, markdown} <- MDEx.to_markdown(document) do
      {:ok,
       %{
         text: markdown,
         metadata: %{"parser" => "mdex", "ast_node_count" => length(document.nodes)},
         format: :markdown
       }}
    else
      false -> {:error, :invalid_utf8_markdown}
      {:error, error} -> {:error, error}
    end
  end

  # Native extraction sniffs all remaining formats.
  defp extract_native(bytes, media_type) do
    # Character cap bounds per-document extraction memory; increasing it raises peak use.
    max_length =
      :memhouse
      |> Application.fetch_env!(:documents)
      |> Keyword.fetch!(:max_extract_length)

    case ExtractousEx.extract_from_bytes(bytes, max_length: max_length) do
      {:ok, result} ->
        {:ok,
         %{
           text: result.content,
           metadata:
             result.metadata
             |> stringify_keys()
             |> Map.put("parser", "extractous_ex")
             |> Map.put("media_type", media_type),
           format: :plaintext
         }}

      {:error, error} ->
        {:error, {:document_extraction_failed, error}}
    end
  end

  # Normalize extractor metadata to JSON-safe string-keyed values.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)

  defp normalize_value(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp normalize_value(nil), do: nil
  defp normalize_value(value), do: inspect(value)
end

defmodule MemHouse.Documents.Chunker do
  @moduledoc """
  Splits extracted text and embeds each retrievable chunk.

  Chunks and vectors are rebuildable caches and excluded from exports. Embeddings go through the
  Account model role and retain provider, model, version, and dimensions; identity mismatches
  require re-embedding. Failures return error tuples before durable writes.
  """

  alias MemHouse.Model.Embedding
  alias MemHouse.Pipeline.Idempotency

  @doc """
  Splits `text` into chunks and embeds them in one batch.

  `format` is `:markdown` or `:plaintext`, as reported by the parser, and selects the boundary
  rules. `context` carries the Account, scope, and actor the embedding call is made under.

  Returns `{:ok, chunks}`, where each chunk is a map with `:position`, `:start_byte`,
  `:end_byte`, `:text`, `:content_hash`, `:embedding`, and the four embedding-identity fields —
  exactly the shape the chunk resource's upsert accepts. Text that yields no chunks returns
  `{:ok, []}`.

  Returns `{:error, {:chunking_failed, reason}}` when splitting fails, and passes through any
  error from the embedding call unchanged.
  """
  def chunk_and_embed(text, format, context)
      when is_binary(text) and format in [:markdown, :plaintext] and is_map(context) do
    # Size and overlap are character counts; changes apply only after rebuild.
    config = Application.fetch_env!(:memhouse, :documents)

    chunks =
      TextChunker.split(text,
        chunk_size: Keyword.fetch!(config, :chunk_size),
        chunk_overlap: Keyword.fetch!(config, :chunk_overlap),
        format: format
      )

    case chunks do
      {:error, error} ->
        {:error, {:chunking_failed, error}}

      [] ->
        {:ok, []}

      chunks ->
        # Drop blanks before assigning dense upsert positions.
        ingestions =
          chunks
          |> Enum.reject(&(String.trim(&1.text) == ""))
          |> Enum.with_index()
          |> Enum.map(fn {chunk, position} ->
            %{
              position: position,
              start_byte: chunk.start_byte,
              end_byte: chunk.end_byte,
              text: chunk.text,
              content_hash: Idempotency.content_hash(chunk.text)
            }
          end)

        texts = Enum.map(ingestions, & &1.text)

        # Pin the exact embedded batch so vectors cannot be paired with different text.
        with {:ok, embedding} <- Embedding.embed(texts, context),
             embedded <-
               Rag.Embedding.generate_embeddings_batch(
                 ingestions,
                 fn ^texts, [] -> {:ok, embedding.vectors} end,
                 text_key: :text,
                 embedding_key: :embedding
               ) do
          # Store embedding identity so later model changes can detect incompatibility.
          {:ok,
           Enum.map(embedded, fn chunk ->
             Map.merge(chunk, %{
               embedding_provider: embedding.provider,
               embedding_model: embedding.model,
               embedding_version: embedding.version,
               embedding_dimensions: embedding.dimensions
             })
           end)}
        end
    end
  end
end
