# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Model.Embedding do
  @moduledoc """
  The embedding entry point, and the guard that keeps vector spaces from mixing.

  ## Embedding identity

  Provider, model, model version, and dimensions define a vector space. Vectors from different
  identities are not comparable, even at the same width.

  Results carry this identity. Pass existing identity as `:stored_identity`; mismatch returns an
  explicit re-embed plan. Vectors are never substituted, truncated, or padded to force a match.

  The model version deliberately covers the model artifact, the tokenizer, and
  the pooling strategy, so changing any of them requires a version bump and
  therefore triggers the re-embed path.

  ## Dimension check

  Returned vectors must match the configured width and installed indexes.

  ## Mistakes to avoid

  - Do not omit `:stored_identity` when embedding a query that will be compared
    against previously stored vectors; omitting it disables the guard.
  - Do not "handle" `{:error, {:reembed_required, plan}}` by dropping the stored
    identity and retrying. The plan says the whole corpus must be re-embedded.
  """

  alias MemHouse.Model.Config
  alias MemHouse.Model.Embedding.QueryCache
  alias MemHouse.Model.Gateway

  defmodule Result do
    @moduledoc """
    Vectors together with the identity of the embedder that produced them.

    `:vectors` is a list of float lists, one per input text and in input order.
    `:provider`, `:model`, `:version`, and `:dimensions` are the four-part
    embedding identity; store all four with the vectors, because a vector whose
    identity is unknown can never be safely reused.
    """
    defstruct [:vectors, :provider, :model, :version, :dimensions]
  end

  @doc """
  Embeds `texts` with the Account's pinned embedder.

  Pass the identity recorded next to any existing vectors as
  `opts[:stored_identity]` — a map with `:provider`, `:model`, `:version`, and
  `:dimensions`, string or atom keys — so an embedder change is caught before a
  query is compared against a corpus it does not belong to.

  Returns `{:ok, %Result{}}` on success. Failure modes a caller must handle:

  - `{:error, {:reembed_required, plan}}` — the configured embedder no longer
    matches the stored identity. The plan describes the migration and states
    that existing vectors cannot be reused.
  - `{:error, {:embedding_dimension_mismatch, expected}}` — the provider
    returned vectors of the wrong width.
  - `{:error, :embedding_dimensions_not_configured}` — the embedder role has no
    dimension pinned, so nothing can validate the result.
  - Any provider error, passed through unchanged.
  """
  def embed(texts, context, opts \\ []) when is_list(texts) do
    config = Config.resolve(:embedder, context)
    current = Config.embedding_identity(config)

    # Order matters: compatibility is checked before any tokens are spent. The
    # pin on `config` asserts the gateway embedded with the very configuration
    # whose identity was just validated and is about to be returned — a
    # different one would mean the returned identity describes the wrong space.
    with :ok <- ensure_compatible(Keyword.get(opts, :stored_identity), current) do
      embed_with_cache(texts, context, opts, config, current)
    end
  end

  defp embed_with_cache([text], %{account_id: account_id} = context, opts, config, current)
       when is_binary(text) and is_binary(account_id) do
    if Keyword.get(opts, :input_type, :passage) == :query do
      key = {account_id, query_identity(current, config), :crypto.hash(:sha256, text)}

      case QueryCache.fetch(key) do
        {:ok, vector} ->
          with :ok <- ensure_dimensions([vector], current.dimensions) do
            {:ok, result([vector], current)}
          end

        :error ->
          embed_and_cache(key, [text], context, opts, config, current)
      end
    else
      embed_with_config([text], context, opts, config, current)
    end
  end

  defp embed_with_cache(texts, context, opts, config, current),
    do: embed_with_config(texts, context, opts, config, current)

  defp embed_and_cache(key, texts, context, opts, config, current) do
    with {:ok, %Result{vectors: [vector]} = result} <-
           embed_with_config(texts, context, opts, config, current) do
      :ok = QueryCache.put(key, vector)
      {:ok, result}
    end
  end

  defp embed_with_config(texts, context, opts, config, current) do
    with {:ok, vectors, ^config} <- Gateway.embed_with_config(config, texts, context, opts),
         :ok <- ensure_dimensions(vectors, current.dimensions) do
      {:ok, result(vectors, current)}
    end
  end

  defp result(vectors, current) do
    %Result{
      vectors: vectors,
      provider: current.provider,
      model: current.model,
      version: current.version,
      dimensions: current.dimensions
    }
  end

  # Query instructions change query coordinates without changing the stored
  # corpus vector identity. Their digest keeps a changed prefix from reusing an
  # old query result while retaining the four-part stored-vector identity.
  defp query_identity(current, config) do
    {identity(current), :crypto.hash(:sha256, Map.get(config.options, "query_instruction", ""))}
  end

  @doc """
  True when stored vectors may be reused with the current embedder.

  Comparison is on all four identity parts at once; matching three of them is
  not compatibility. A `nil` stored identity means "nothing stored yet", which
  is trivially compatible.

  Accepts string or atom keys on either side, because a stored identity usually
  comes back from the database with string keys.
  """
  def compatible?(nil, _current), do: true

  def compatible?(stored, current) when is_map(stored) and is_map(current) do
    identity(stored) == identity(current)
  end

  @doc """
  `:ok` when reuse is safe, otherwise `{:error, {:reembed_required, plan}}`.

  The assertion form of `compatible?/2`, used to fail an embedding call before
  any tokens are spent producing a vector that could not legally be compared
  with the stored ones.
  """
  def ensure_compatible(nil, _current), do: :ok

  def ensure_compatible(stored, current) do
    if compatible?(stored, current) do
      :ok
    else
      {:error, {:reembed_required, reembed_plan(stored, current)}}
    end
  end

  @doc """
  Describes the migration required to move from one embedding identity to another.

  Returns a map naming the old and new identities and the required operation.
  `reuse_existing_vectors: false` is not advice — it is the rule: vectors from
  the old identity have to be regenerated, because there is no transformation
  that makes one embedder's coordinates valid in another's space.

  `pipeline_version` is the contract identity value `"f5-1"`, which versions the
  shape of this plan along with the rest of the extractor and pipeline contract;
  changing that string obliges a maintainer to add a changelog entry and refresh
  the contract evidence.
  """
  def reembed_plan(stored, current) do
    %{
      pipeline_version: "f5-1",
      from: identity(stored),
      to: identity(current),
      operation: "reembed_all",
      reuse_existing_vectors: false
    }
  end

  # Every returned vector must be exactly the configured width: the stored
  # vector columns and their indexes are built for one width, so a short or long
  # vector is a provider bug to surface, never something to pad or truncate.
  defp ensure_dimensions(vectors, dimensions) when is_integer(dimensions) do
    if Enum.all?(vectors, &(is_list(&1) and length(&1) == dimensions)) do
      :ok
    else
      {:error, {:embedding_dimension_mismatch, dimensions}}
    end
  end

  # An embedder with no pinned width cannot be validated, so it is refused
  # rather than trusted.
  defp ensure_dimensions(_vectors, nil), do: {:error, :embedding_dimensions_not_configured}

  # Normalizes either key shape into one comparable map. A stored identity read
  # back from the database has string keys; a freshly resolved one has atoms.
  defp identity(value) do
    %{
      provider: value[:provider] || value["provider"],
      model: value[:model] || value["model"],
      version: value[:version] || value["version"],
      dimensions: value[:dimensions] || value["dimensions"]
    }
  end
end
