# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.SourceSearch do
  @moduledoc """
  Governed exact and semantic recall over immutable source messages.

  The caller supplies an authority tuple produced by `MemHouse.Memory`: an
  Account actor and an already-authorized scope list. Every SQL statement
  repeats those filters before ranking. Results contain stable citation data
  and a bounded excerpt, never the unbounded source body.
  """

  alias MemHouse.DataLayer
  alias MemHouse.Model.Embedding
  alias MemHouse.Repo
  alias MemHouse.Retrieval.DiskannLabels

  @default_limit 12
  @max_limit 100
  @default_excerpt_chars 480
  @max_excerpt_chars 2_000

  @type authority :: %{
          required(:account_id) => Ecto.UUID.t(),
          required(:actor) => MemHouse.Actor.t(),
          required(:scope_ids) => [Ecto.UUID.t()]
        }

  @doc """
  Searches only scopes already authorized by `MemHouse.Memory`.

  `:exact` is generated full-text search and performs no model call. `:semantic`
  embeds the query outside any database transaction, then compares only rows
  carrying the same four-part embedding identity. The returned status is one
  of `ready`, `stale`, `empty`, `unavailable`, or `failed` and never includes a
  hidden corpus count.
  """
  def search(authority, text, opts \\ []) when is_binary(text) do
    mode = normalize_mode(Keyword.get(opts, :mode, :semantic))
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)

    excerpt_chars =
      opts
      |> Keyword.get(:excerpt_chars, @default_excerpt_chars)
      |> clamp(80, @max_excerpt_chars)

    started_at = System.monotonic_time(:millisecond)

    result =
      case {mode, String.trim(text)} do
        {_mode, ""} ->
          %{mode: mode, status: :empty, results: [], degraded: false, failure_class: nil}

        {:exact, text} ->
          exact(authority, text, limit, excerpt_chars)

        {:semantic, text} ->
          semantic(authority, text, limit, excerpt_chars)
      end

    latency_ms = System.monotonic_time(:millisecond) - started_at

    :telemetry.execute(
      [:memhouse, :retrieval, :source_search],
      %{latency_ms: latency_ms, result_count: length(result.results)},
      %{mode: mode, status: result.status, failure_class: result.failure_class}
    )

    result
    |> Map.put(:latency_ms, latency_ms)
    |> stringify()
  end

  defp exact(authority, text, limit, excerpt_chars) do
    {rows, status} =
      in_account(authority, fn ->
        sql = """
        WITH term AS (SELECT websearch_to_tsquery('simple', $3) AS query)
        SELECT message.id, message.session_id, message.scope_id,
               message.peer_id, peer.key AS speaker_key,
               peer.name AS speaker_name, message.role, message.occurred_at,
               left(message.content, $5) AS excerpt,
               ts_rank_cd(message.search_vector, term.query)::float8 AS score
        FROM messages AS message
        JOIN peers AS peer
          ON peer.id = message.peer_id AND peer.account_id = message.account_id
        CROSS JOIN term
        WHERE message.account_id = $1
          AND message.scope_id = ANY($2)
          AND message.search_vector @@ term.query
        ORDER BY score DESC, message.occurred_at DESC, message.id ASC
        LIMIT $4
        """

        rows = all(sql, params(authority, [text, limit, excerpt_chars]))
        status = if visible_message?(authority), do: :ready, else: :empty
        {rows, status}
      end)

    %{mode: :exact, status: status, results: rank(rows), degraded: false, failure_class: nil}
  end

  defp semantic(authority, text, limit, excerpt_chars) do
    context = %{account_id: authority.account_id, actor: authority.actor}

    case Embedding.embed([text], context, input_type: :query) do
      {:ok, %{vectors: [vector]} = identity} ->
        {rows, status} =
          in_account(authority, fn ->
            labels = DiskannLabels.for_scope_ids!(authority.account_id, authority.scope_ids)
            sql = semantic_sql(identity.dimensions)

            query_params =
              params(authority, [
                vector_literal(vector),
                identity.provider,
                identity.model,
                identity.version,
                identity.dimensions,
                labels,
                limit,
                excerpt_chars
              ])

            rows = all(sql, query_params)
            {rows, semantic_status(authority, identity)}
          end)

        %{
          mode: :semantic,
          status: status,
          results: rank(rows),
          degraded: status in [:stale, :unavailable],
          failure_class: nil
        }

      {:error, error} ->
        %{
          mode: :semantic,
          status: :failed,
          results: [],
          degraded: true,
          failure_class: classify_error(error)
        }
    end
  end

  defp semantic_sql(1024) do
    """
    SELECT message.id, message.session_id, message.scope_id,
           message.peer_id, peer.key AS speaker_key,
           peer.name AS speaker_name, message.role, message.occurred_at,
           left(message.content, $10) AS excerpt,
           (1.0 - (message.embedding::vector(1024) <=> $3::text::vector(1024)))::float8 AS score
    FROM messages AS message
    JOIN peers AS peer
      ON peer.id = message.peer_id AND peer.account_id = message.account_id
    WHERE message.account_id = $1
      AND message.scope_id = ANY($2)
      AND message.embedding IS NOT NULL
      AND message.embedding_provider = $4
      AND message.embedding_model = $5
      AND message.embedding_version = $6
      AND message.embedding_dimensions = $7
      AND message.diskann_labels && $8::smallint[]
    ORDER BY message.embedding::vector(1024) <=> $3::text::vector(1024),
             message.occurred_at DESC, message.id ASC
    LIMIT $9
    """
  end

  defp semantic_sql(_dimensions) do
    """
    SELECT message.id, message.session_id, message.scope_id,
           message.peer_id, peer.key AS speaker_key,
           peer.name AS speaker_name, message.role, message.occurred_at,
           left(message.content, $10) AS excerpt,
           (1.0 - (message.embedding <=> $3::text::vector))::float8 AS score
    FROM messages AS message
    JOIN peers AS peer
      ON peer.id = message.peer_id AND peer.account_id = message.account_id
    WHERE message.account_id = $1
      AND message.scope_id = ANY($2)
      AND message.embedding IS NOT NULL
      AND message.embedding_provider = $4
      AND message.embedding_model = $5
      AND message.embedding_version = $6
      AND message.embedding_dimensions = $7
      AND message.diskann_labels && $8::smallint[]
    ORDER BY message.embedding <=> $3::text::vector,
             message.occurred_at DESC, message.id ASC
    LIMIT $9
    """
  end

  # Produces only a class, never counts. A mixed or outdated visible corpus is
  # stale; an entirely unembedded visible corpus is unavailable.
  defp semantic_status(authority, identity) do
    sql = """
    SELECT CASE
      WHEN count(*) = 0 THEN 'empty'
      WHEN count(*) FILTER (
        WHERE embedding IS NOT NULL
          AND embedding_provider = $3
          AND embedding_model = $4
          AND embedding_version = $5
          AND embedding_dimensions = $6
      ) = 0 THEN 'unavailable'
      WHEN count(*) FILTER (
        WHERE embedding IS NOT NULL
          AND embedding_provider = $3
          AND embedding_model = $4
          AND embedding_version = $5
          AND embedding_dimensions = $6
      ) < count(*) THEN 'stale'
      ELSE 'ready'
    END AS status
    FROM messages
    WHERE account_id = $1 AND scope_id = ANY($2)
    """

    [row] =
      all(sql, [
        db_uuid!(authority.account_id),
        db_uuids!(authority.scope_ids),
        identity.provider,
        identity.model,
        identity.version,
        identity.dimensions
      ])

    String.to_existing_atom(row["status"])
  end

  defp visible_message?(authority) do
    sql = """
    SELECT EXISTS(
      SELECT 1 FROM messages
      WHERE account_id = $1 AND scope_id = ANY($2)
    ) AS present
    """

    [%{"present" => present}] =
      all(sql, [db_uuid!(authority.account_id), db_uuids!(authority.scope_ids)])

    present
  end

  defp in_account(authority, fun) do
    DataLayer.with_actor(authority.actor, fn _account, _actor -> fun.() end)
  end

  defp params(authority, rest) do
    [db_uuid!(authority.account_id), db_uuids!(authority.scope_ids) | rest]
  end

  defp all(sql, values) do
    result = Ecto.Adapters.SQL.query!(Repo, sql, values)

    Enum.map(result.rows, fn row ->
      result.columns
      |> Enum.zip(row)
      |> Map.new()
      |> normalize_uuids()
    end)
  end

  defp normalize_uuids(row) do
    Enum.reduce(~w(id session_id scope_id peer_id), row, fn key, acc ->
      case Map.get(acc, key) do
        <<_::128>> = value ->
          {:ok, uuid} = Ecto.UUID.load(value)
          Map.put(acc, key, uuid)

        _other ->
          acc
      end
    end)
  end

  defp rank(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} -> Map.put(row, "rank", rank) end)
  end

  defp vector_literal(values), do: "[#{Enum.join(values, ",")}]"
  defp db_uuids!(values), do: Enum.map(values, &db_uuid!/1)
  defp db_uuid!(<<_::128>> = value), do: value
  defp db_uuid!(value), do: Ecto.UUID.dump!(value)

  defp normalize_mode(mode) when mode in [:exact, "exact"], do: :exact
  defp normalize_mode(mode) when mode in [:semantic, "semantic"], do: :semantic

  defp normalize_mode(mode),
    do: raise(ArgumentError, "unknown source search mode: #{inspect(mode)}")

  defp clamp(value, minimum, maximum) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, minimum, _maximum), do: minimum

  defp classify_error({kind, _}) when is_atom(kind), do: Atom.to_string(kind)
  defp classify_error(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp classify_error(_), do: "provider_error"

  defp stringify(map) do
    Map.new(map, fn {key, value} ->
      value =
        if is_atom(value) and not is_boolean(value) and not is_nil(value),
          do: Atom.to_string(value),
          else: value

      {Atom.to_string(key), value}
    end)
  end
end
