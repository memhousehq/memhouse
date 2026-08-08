# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Documents.BlobStore do
  @moduledoc """
  Stores and retrieves original document bytes through a runtime-selected adapter.

  Objects are Account-scoped and named by SHA-256, making puts idempotent and safe before the
  database transaction. Identical documents may share an object, so erasure must check remaining
  references.

  Durable `local://` and `s3://` references select their original adapter after configuration
  changes. `legacy-db://` bytes remain inline and must be read from the version row.
  """

  @callback put(Ecto.UUID.t(), String.t(), binary(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback get(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback signed_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Stores bytes under the Account and content hash, and returns their durable reference.

  Uses the configured adapter and caller-supplied hash. Returns `{:ok, blob_ref}` or
  `{:error, reason}`; existing content is success.
  """
  def put(account_id, content_hash, bytes, opts \\ []) do
    adapter().put(account_id, content_hash, bytes, opts)
  end

  @doc """
  Reads the bytes behind a durable reference.

  Returns `{:ok, bytes}` or `{:error, reason}`. A pre-blob-store reference returns
  `{:error, :legacy_blob_requires_version_content}`: those bytes live in the version row and the
  caller must read them from there.
  """
  def get(blob_ref, opts \\ [])
  def get("legacy-db://" <> _rest, _opts), do: {:error, :legacy_blob_requires_version_content}
  def get(blob_ref, opts), do: adapter_for(blob_ref).get(blob_ref, opts)

  @doc """
  Deletes the object behind a reference, if it is still there.

  Missing and legacy-inline objects return `:ok`. Callers must first confirm no other document
  references shared content.
  """
  def delete(blob_ref, opts \\ [])
  def delete("legacy-db://" <> _rest, _opts), do: :ok
  def delete(blob_ref, opts), do: adapter_for(blob_ref).delete(blob_ref, opts)

  @doc """
  Asks the owning adapter for a time-limited direct download URL.

  Returns `{:ok, url}` or `{:error, reason}`. Local storage refuses because it cannot create an
  expiring link. Treat returned URLs as bearer capabilities.
  """
  def signed_url(blob_ref, opts \\ []), do: adapter_for(blob_ref).signed_url(blob_ref, opts)

  defp adapter do
    :memhouse
    |> Application.fetch_env!(:documents)
    |> Keyword.fetch!(:blob_adapter)
  end

  # Existing references retain their adapter across storage migrations.
  defp adapter_for("local://" <> _rest), do: MemHouse.Documents.BlobStore.Local
  defp adapter_for("s3://" <> _rest), do: MemHouse.Documents.BlobStore.S3
  defp adapter_for(_blob_ref), do: adapter()
end

defmodule MemHouse.Documents.BlobStore.Local do
  @moduledoc """
  Stores document bytes as content-addressed files on the local filesystem.

  Stores under `root/account/first-two-hash-chars/hash`. Account UUIDs and 64-character lowercase
  SHA-256 values are validated before path construction. Exclusive writes never clobber existing
  content. The blob root is durable source data, not a cache.
  """

  @behaviour MemHouse.Documents.BlobStore

  # SHA-256 format is also a path-safety boundary.
  @hash_regex ~r/\A[0-9a-f]{64}\z/

  @doc """
  Writes bytes to the content-addressed path and returns a `local://` reference.

  Returns `{:ok, reference}`, a validation error, or a `File` error. Existing objects succeed.
  """
  @impl true
  # Account and hash path segments are validated as UUID/hex below.
  # sobelow_skip ["Traversal.FileModule"]
  def put(account_id, content_hash, bytes, _opts)
      when is_binary(account_id) and is_binary(content_hash) and is_binary(bytes) do
    with :ok <- validate_account_id(account_id),
         :ok <- validate_hash(content_hash),
         path = path(account_id, content_hash),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- put_if_missing(path, bytes) do
      {:ok, "local://#{account_id}/#{content_hash}"}
    end
  end

  @doc """
  Reads the file behind a `local://` reference.

  Returns `{:ok, bytes}`, `{:error, :invalid_blob_ref | :invalid_account_id |
  :invalid_content_hash}` for a malformed reference, or `{:error, :enoent}` when the object is
  missing from the blob root.
  """
  @impl true
  # The durable reference parser accepts validated UUID/hex segments only.
  # sobelow_skip ["Traversal.FileModule"]
  def get(blob_ref, _opts) do
    with {:ok, account_id, content_hash} <- parse_ref(blob_ref) do
      File.read(path(account_id, content_hash))
    end
  end

  @doc """
  Removes the file behind a `local://` reference.

  Returns `:ok`, including for a missing file, or a validation/filesystem error.
  """
  @impl true
  # The durable reference parser accepts validated UUID/hex segments only.
  # sobelow_skip ["Traversal.FileModule"]
  def delete(blob_ref, _opts) do
    with {:ok, account_id, content_hash} <- parse_ref(blob_ref) do
      # A missing file is the desired end state, not a failure.
      case File.rm(path(account_id, content_hash)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    end
  end

  @doc """
  Always refuses: local files have no expiring URL to hand out.

  Returns `{:error, :local_blob_urls_are_not_exposed}` or a reference-validation error.
  """
  @impl true
  def signed_url(blob_ref, _opts) do
    with {:ok, _account_id, _content_hash} <- parse_ref(blob_ref) do
      {:error, :local_blob_urls_are_not_exposed}
    end
  end

  # Exclusive create prevents truncating an object another process may read; `:eexist` is success.
  # sobelow_skip ["Traversal.FileModule"]
  defp put_if_missing(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result = IO.binwrite(io, bytes)
        :ok = File.close(io)
        result

      {:error, :eexist} ->
        :ok

      error ->
        error
    end
  end

  # Revalidate stored references before filesystem access.
  defp parse_ref("local://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [account_id, content_hash] ->
        with :ok <- validate_account_id(account_id),
             :ok <- validate_hash(content_hash) do
          {:ok, account_id, content_hash}
        end

      _other ->
        {:error, :invalid_blob_ref}
    end
  end

  defp parse_ref(_blob_ref), do: {:error, :invalid_blob_ref}

  defp validate_account_id(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, ^account_id} -> :ok
      _other -> {:error, :invalid_account_id}
    end
  end

  defp validate_hash(content_hash) do
    if Regex.match?(@hash_regex, content_hash), do: :ok, else: {:error, :invalid_content_hash}
  end

  # Account separates tenants; two hash characters bound directory fan-out.
  defp path(account_id, content_hash) do
    root =
      :memhouse
      |> Application.fetch_env!(:documents)
      |> Keyword.fetch!(:blob_root)

    Path.join([root, account_id, String.slice(content_hash, 0, 2), content_hash])
  end
end

defmodule MemHouse.Documents.BlobStore.S3 do
  @moduledoc """
  Stores document bytes in any S3-compatible object store.

  Uses `prefix/account/hash` keys and durable `s3://bucket/key` references. Bucket changes require
  data migration. Credentials come from ExAws configuration; buckets must remain private and
  downloads use short-lived presigned URLs.
  """

  @behaviour MemHouse.Documents.BlobStore

  @doc """
  Uploads bytes under the content-addressed key and returns an `s3://` reference.

  Options may override configured `:bucket` and `:prefix`. Returns `{:ok, reference}`, a missing-
  bucket error, or the ExAws error. Retrying identical bytes is safe.
  """
  @impl true
  def put(account_id, content_hash, bytes, opts)
      when is_binary(account_id) and is_binary(content_hash) and is_binary(bytes) do
    with {:ok, bucket} <- bucket(opts),
         key = key(account_id, content_hash, opts),
         {:ok, _response} <- ExAws.S3.put_object(bucket, key, bytes) |> ExAws.request() do
      {:ok, "s3://#{bucket}/#{key}"}
    end
  end

  @doc """
  Downloads the object behind an `s3://` reference.

  Uses the referenced bucket. Returns `{:ok, bytes}`, a reference error, or the ExAws error.
  """
  @impl true
  def get(blob_ref, _opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref),
         {:ok, response} <- ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, Map.fetch!(response, :body)}
    end
  end

  @doc """
  Deletes the object behind an `s3://` reference.

  Returns `:ok`, a reference error, or the ExAws error. Callers must protect shared content.
  """
  @impl true
  def delete(blob_ref, _opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref),
         {:ok, _response} <- ExAws.S3.delete_object(bucket, key) |> ExAws.request() do
      :ok
    end
  end

  @doc """
  Mints a short-lived presigned GET URL for the object.

  `opts[:expires_in]` is seconds and defaults to 300 (five minutes). Returns `{:ok, url}` or an
  error. The URL is a bearer capability until expiry.
  """
  @impl true
  def signed_url(blob_ref, opts) do
    with {:ok, bucket, key} <- parse_ref(blob_ref) do
      config = ExAws.Config.new(:s3)
      ExAws.S3.presigned_url(config, :get, bucket, key, expires_in: opts[:expires_in] || 300)
    end
  end

  # Missing bucket configuration fails closed.
  defp bucket(opts) do
    value = opts[:bucket] || document_config()[:s3_bucket]
    if is_binary(value) and value != "", do: {:ok, value}, else: {:error, :s3_bucket_missing}
  end

  # Trim prefix slashes; Account separates tenants in the key space.
  defp key(account_id, content_hash, opts) do
    prefix = opts[:prefix] || document_config()[:s3_prefix] || "memhouse"
    Enum.join([String.trim(prefix, "/"), account_id, content_hash], "/")
  end

  # Preserve slashes inside the object key.
  defp parse_ref("s3://" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" -> {:ok, bucket, key}
      _other -> {:error, :invalid_blob_ref}
    end
  end

  defp parse_ref(_blob_ref), do: {:error, :invalid_blob_ref}
  defp document_config, do: Application.fetch_env!(:memhouse, :documents)
end
