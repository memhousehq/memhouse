# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Store do
  @moduledoc """
  Implements read-only retrieval SQL that cannot be expressed through Ash.

  Every query must filter Account, authorized scopes, active lifecycle, soft deletion, and the
  reader before candidates leave this boundary. Scope joins also match Account.

  `visible_knowledge/2` builds that reader filter and every knowledge query interpolates it.
  A peer-facing reader sees anything not personal, its own statements, scope-subject statements,
  and anything promoted to scope or account level; with no reader peer it sees public statements
  only. An internal reader sees the whole corpus and is the only way past this, which is why the
  flag is passed explicitly and never derived from request input.

  Knowledge queries share one result shape; chunk queries synthesize compatible fields. Scores
  are strategy-local. SQL is static and all caller values are bound parameters. Durable writes
  remain resource-action-only.
  """

  alias MemHouse.Repo

  # Shared caller-facing knowledge shape; only scope path comes from the joined scope.
  #
  # The validity window travels with every candidate. A statement is written to read on its
  # own, but a reader that has to date one — "when did this happen" — needs the window rather
  # than the prose, and a candidate without it can only be dated against the reader's own clock.
  #
  # The window is stored UTC-in-naive, and raw SQL returns it that way. `AT TIME ZONE 'UTC'`
  # makes it a `timestamptz`, so it reaches a caller as an instant with an offset instead of a
  # bare wall-clock reading they would have to guess a zone for.
  @knowledge_columns """
  k.id, k.scope_id, s.path AS scope_path, k.statement, k.kind, k.confidence,
  k.sensitivity, k.state, k.source_message_ids, k.extracting_model,
  k.extracting_provider, k.pipeline_version, k.corroboration_count,
  k.relevant_from AT TIME ZONE 'UTC' AS relevant_from,
  k.relevant_until AT TIME ZONE 'UTC' AS relevant_until
  """

  alias MemHouse.Retrieval.LexicalQueryAnalyzer

  # How many base-ranked rows stay eligible for the proximity bonus. The bonus is a second
  # `tsquery` evaluated per row, roughly an order of magnitude dearer than the base rank, so it
  # runs over a shortlist rather than the whole match set. Five times the caller's limit leaves
  # room for a proximate answer to climb without letting a broad query pay for thousands of rows.
  @lexical_shortlist_multiplier 5

  # Weight of the proximity bonus relative to the base cover-density rank. One extra covered term
  # is worth about `0.1`, so `0.2` lets a tight subject-and-intent match outrank a looser row
  # without overturning a row that genuinely covers more of the query.
  @proximity_weight 0.2

  # Outer projection over the shortlist CTE, which has already dropped the `k.` qualifier.
  @knowledge_shortlist_columns """
  id, scope_id, scope_path, statement, kind, confidence,
  sensitivity, state, source_message_ids, extracting_model,
  extracting_provider, pipeline_version, corroboration_count,
  relevant_from, relevant_until
  """

  @doc """
  Returns durable-content and operational-history bytes for one Account.

  The fixed read-only query measures content bytes for durable data and row bytes for retained
  ledgers and Account-owned Oban jobs. It must run inside an Account-scoped transaction.
  """
  # sobelow_skip ["SQL.Query"]
  def storage_bytes(account_id) do
    sql = """
    SELECT
      COALESCE((SELECT sum(octet_length(content)) FROM messages WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(octet_length(statement)) FROM knowledge_items WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(byte_size) FROM document_versions WHERE account_id = $1), 0),
      COALESCE((SELECT sum(pg_column_size(row)) FROM pipeline_runs AS row WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(pg_column_size(row)) FROM usage_events AS row WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(pg_column_size(row)) FROM gate_decisions AS row WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(pg_column_size(row)) FROM knowledge_lifecycle_events AS row WHERE account_id = $1), 0) +
      COALESCE((SELECT sum(pg_column_size(row)) FROM oban_jobs AS row WHERE args->>'tenant' = $2), 0)
    """

    case Ecto.Adapters.SQL.query(Repo, sql, [Ecto.UUID.dump!(account_id), account_id]) do
      {:ok, %{rows: [[durable, operational]]}} ->
        %{durable: integer(durable), operational: integer(operational)}

      {:error, error} ->
        raise error

      {:ok, result} ->
        raise "unexpected storage query result: #{inspect(result)}"
    end
  end

  defp integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer(value) when is_integer(value), do: value

  @doc """
  Full-text search over governed statements and document chunks.

  Searches requested targets and ranks with `ts_rank_cd`, then merges and truncates to `limit`.

  A query spelling a websearch operator keeps the documented `websearch` parse. Any other query is
  normalized by `MemHouse.Retrieval.LexicalQueryAnalyzer` and matches the disjunction of the
  resulting terms, because `websearch_to_tsquery` joins bare terms with `AND` and a one-sentence
  statement rarely carries every content word of a question. `ts_rank_cd` still orders by how many
  query terms a row covers and how densely.

  A normalized query also earns a bounded proximity bonus when two of its terms fall near each
  other. Only the top `#{@lexical_shortlist_multiplier}x limit` rows by base rank compete for it,
  so a row ranked below that window cannot be promoted.

  Returns a list of column-keyed maps with a `score` and a `candidate_type`.
  Raises `Postgrex.Error` if the statement fails.
  """
  def lexical(query, limit) do
    internal_reader? = query.internal_reader?
    analysis = LexicalQueryAnalyzer.analyze(query.text)
    shortlist = limit * @lexical_shortlist_multiplier

    knowledge =
      if query.target in [:knowledge, :all] do
        tsquery = tsquery(analysis, "$4")
        proximity_tsquery = proximity_tsquery("$5")

        sql = """
        WITH shortlist AS (
          SELECT #{@knowledge_columns}, k.search_vector, k.inserted_at,
                 ts_rank_cd(k.search_vector, #{tsquery}) AS base_score
          FROM knowledge_items AS k
          JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
          WHERE k.account_id = $1
            AND k.scope_id = ANY($2)
        #{visible_knowledge("$3", internal_reader?)}
            AND k.deleted_at IS NULL
            AND (k.expires_at IS NULL OR k.expires_at > now())
            AND k.search_vector @@ #{tsquery}
          ORDER BY base_score DESC, k.confidence DESC, k.inserted_at DESC
          LIMIT $6
        )
        SELECT #{@knowledge_shortlist_columns},
               base_score +
                 #{@proximity_weight} * coalesce(ts_rank_cd(search_vector, #{proximity_tsquery}), 0) AS score,
               'knowledge' AS candidate_type
        FROM shortlist
        ORDER BY score DESC, confidence DESC, inserted_at DESC
        LIMIT $7
        """

        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          db_uuid(query.actor.peer_id),
          analysis.matching_text,
          analysis.proximity_text,
          shortlist,
          limit
        ])
      else
        []
      end

    # Chunks synthesize knowledge fields. `f7-1` is the caller-visible retrieval/context contract;
    # changing it requires a documented contract transition.
    documents =
      if query.target in [:documents, :all] do
        tsquery = tsquery(analysis, "$3")
        proximity_tsquery = proximity_tsquery("$4")

        sql = """
        WITH shortlist AS (
          SELECT c.id, c.scope_id, s.path AS scope_path, c.text AS statement, c.status,
                 c.document_id, c.document_version_id, c.position, c.search_vector,
                 ts_rank_cd(c.search_vector, #{tsquery}) AS base_score
          FROM document_chunks AS c
          JOIN scopes AS s ON s.id = c.scope_id AND s.account_id = c.account_id
          WHERE c.account_id = $1
            AND c.scope_id = ANY($2)
            AND c.status = 'active'
            AND c.search_vector @@ #{tsquery}
          ORDER BY base_score DESC, c.position ASC
          LIMIT $5
        )
        SELECT id, scope_id, scope_path, statement,
               'document_chunk' AS kind, 1.0::float8 AS confidence,
               'internal' AS sensitivity, status AS state,
               ARRAY[]::uuid[] AS source_message_ids,
               NULL::text AS extracting_model, 'f7-1' AS pipeline_version,
               base_score +
                 #{@proximity_weight} * coalesce(ts_rank_cd(search_vector, #{proximity_tsquery}), 0) AS score,
               'document_chunk' AS candidate_type,
               document_id, document_version_id, position
        FROM shortlist
        ORDER BY score DESC, position ASC
        LIMIT $6
        """

        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          analysis.matching_text,
          analysis.proximity_text,
          shortlist,
          limit
        ])
      else
        []
      end

    top(knowledge ++ documents, limit)
  end

  @doc """
  Approximate nearest-neighbour search over stored embeddings.

  Filters by provider, model, version, and dimensions; incompatible rows require re-embedding.

  The 1024-dimensional variant matches its indexed cast; other dimensions scan correctly. Scores
  are `1 - cosine distance`.

  Returns column-keyed maps with `score` and `candidate_type`, merged across
  knowledge and document chunks and truncated to `limit`. Raises
  `Postgrex.Error` if the statement fails.
  """
  def semantic(query, embedding, identity, limit) do
    {:ok, rows} =
      Repo.transaction(fn ->
        configure_diskann_query!(limit)
        semantic_query(query, embedding, identity, limit)
      end)

    rows
  end

  defp semantic_query(query, embedding, identity, limit) do
    internal_reader? = query.internal_reader?
    vector = vector_literal(embedding)
    labels = MemHouse.Retrieval.DiskannLabels.for_scope_ids!(query.account_id, query.scope_ids)

    knowledge =
      if query.target in [:knowledge, :all] do
        sql =
          if identity.dimensions == 1024 do
            """
            SELECT #{@knowledge_columns},
                   1.0 - (k.embedding::vector(1024) <=> $4::text::vector(1024)) AS score,
                   'knowledge' AS candidate_type
            FROM knowledge_items AS k
            JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
            WHERE k.account_id = $1
              AND k.scope_id = ANY($2)
              #{visible_knowledge("$3", internal_reader?)}
              AND k.deleted_at IS NULL
              AND (k.expires_at IS NULL OR k.expires_at > now())
              AND k.embedding IS NOT NULL
              AND k.embedding_provider = $5
              AND k.embedding_model = $6
              AND k.embedding_version = $7
              AND k.embedding_dimensions = $8
              AND k.diskann_labels && $9::smallint[]
            ORDER BY k.embedding::vector(1024) <=> $4::text::vector(1024)
            LIMIT $10
            """
          else
            """
            SELECT #{@knowledge_columns},
                   1.0 - (k.embedding <=> $4::text::vector) AS score,
                   'knowledge' AS candidate_type
            FROM knowledge_items AS k
            JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
            WHERE k.account_id = $1
              AND k.scope_id = ANY($2)
              #{visible_knowledge("$3", internal_reader?)}
              AND k.deleted_at IS NULL
              AND (k.expires_at IS NULL OR k.expires_at > now())
              AND k.embedding IS NOT NULL
              AND k.embedding_provider = $5
              AND k.embedding_model = $6
              AND k.embedding_version = $7
              AND k.embedding_dimensions = $8
              AND k.diskann_labels && $9::smallint[]
            ORDER BY k.embedding <=> $4::text::vector
            LIMIT $10
            """
          end

        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          db_uuid(query.actor.peer_id),
          vector,
          identity.provider,
          identity.model,
          identity.version,
          identity.dimensions,
          labels,
          limit
        ])
      else
        []
      end

    documents =
      if query.target in [:documents, :all] do
        sql =
          if identity.dimensions == 1024 do
            """
            SELECT c.id, c.scope_id, s.path AS scope_path, c.text AS statement,
                   'document_chunk' AS kind, 1.0::float8 AS confidence,
                   'internal' AS sensitivity, c.status AS state,
                   ARRAY[]::uuid[] AS source_message_ids,
                   NULL::text AS extracting_model, 'f7-1' AS pipeline_version,
                   1.0 - (c.embedding::vector(1024) <=> $3::text::vector(1024)) AS score,
                   'document_chunk' AS candidate_type,
                   c.document_id, c.document_version_id, c.position
            FROM document_chunks AS c
            JOIN scopes AS s ON s.id = c.scope_id AND s.account_id = c.account_id
            WHERE c.account_id = $1
              AND c.scope_id = ANY($2)
              AND c.status = 'active'
              AND c.embedding_provider = $4
              AND c.embedding_model = $5
              AND c.embedding_version = $6
              AND c.embedding_dimensions = $7
              AND c.diskann_labels && $8::smallint[]
            ORDER BY c.embedding::vector(1024) <=> $3::text::vector(1024)
            LIMIT $9
            """
          else
            """
            SELECT c.id, c.scope_id, s.path AS scope_path, c.text AS statement,
                   'document_chunk' AS kind, 1.0::float8 AS confidence,
                   'internal' AS sensitivity, c.status AS state,
                   ARRAY[]::uuid[] AS source_message_ids,
                   NULL::text AS extracting_model, 'f7-1' AS pipeline_version,
                   1.0 - (c.embedding <=> $3::text::vector) AS score,
                   'document_chunk' AS candidate_type,
                   c.document_id, c.document_version_id, c.position
            FROM document_chunks AS c
            JOIN scopes AS s ON s.id = c.scope_id AND s.account_id = c.account_id
            WHERE c.account_id = $1
              AND c.scope_id = ANY($2)
              AND c.status = 'active'
              AND c.embedding_provider = $4
              AND c.embedding_model = $5
              AND c.embedding_version = $6
              AND c.embedding_dimensions = $7
              AND c.diskann_labels && $8::smallint[]
            ORDER BY c.embedding <=> $3::text::vector
            LIMIT $9
            """
          end

        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          vector,
          identity.provider,
          identity.model,
          identity.version,
          identity.dimensions,
          labels,
          limit
        ])
      else
        []
      end

    top(knowledge ++ documents, limit)
  end

  @doc "Returns the transaction-local DiskANN query settings for a candidate limit."
  def diskann_query_settings(limit) when is_integer(limit) and limit > 0 do
    config = Application.fetch_env!(:memhouse, :diskann)

    [
      query_search_list_size: max(Keyword.fetch!(config, :query_search_list_size), limit * 2),
      query_rescore: max(Keyword.fetch!(config, :query_rescore), limit)
    ]
  end

  defp configure_diskann_query!(limit) do
    settings = diskann_query_settings(limit)

    for {setting, value} <- [
          {"diskann.query_search_list_size", settings[:query_search_list_size]},
          {"diskann.query_rescore", settings[:query_rescore]}
        ] do
      Ecto.Adapters.SQL.query!(Repo, "SELECT set_config($1, $2, true)", [
        setting,
        to_string(value)
      ])
    end
  end

  @doc """
  Ranks dated, text-matching statements by distance from a point in time.

  Uses `as_of` or now. A window that covers that instant ranks first. Other
  windows decay with the distance from their nearest boundary. Undated and
  text-unrelated rows do not consume the candidate limit.

  Knowledge only — document chunks carry no validity period. Returns
  column-keyed maps, or an empty list when the query targets documents. Raises
  `Postgrex.Error` if the statement fails.
  """
  def temporal(query, limit) do
    internal_reader? = query.internal_reader?
    as_of = query.as_of || MemHouse.Clock.utc_now()

    sql = """
    SELECT #{@knowledge_columns},
           (1.0 / (1.0 + EXTRACT(EPOCH FROM
             CASE
               WHEN (k.relevant_from IS NULL OR k.relevant_from <= $4)
                AND (k.relevant_until IS NULL OR k.relevant_until >= $4)
                 THEN interval '0 seconds'
               WHEN k.relevant_from > $4 THEN k.relevant_from - $4
               ELSE $4 - k.relevant_until
             END
           ) / 86400.0))::float8 AS score,
           'knowledge' AS candidate_type
    FROM knowledge_items AS k
    JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
    WHERE k.account_id = $1
      AND k.scope_id = ANY($2)
    #{visible_knowledge("$3", internal_reader?)}
      AND k.deleted_at IS NULL
      AND (k.relevant_from IS NOT NULL OR k.relevant_until IS NOT NULL)
      AND to_tsvector('english', k.statement) @@ websearch_to_tsquery('english', $5)
      AND k.inserted_at <= $4
      AND (k.expires_at IS NULL OR k.expires_at > $4)
    ORDER BY score DESC, k.inserted_at DESC
    LIMIT $6
    """

    if query.target in [:knowledge, :all] do
      all(sql, [
        db_uuid!(query.account_id),
        db_uuids!(query.scope_ids),
        db_uuid(query.actor.peer_id),
        as_of,
        query.text,
        limit
      ])
    else
      []
    end
  end

  @doc """
  Ranks statements by durable importance rather than by resemblance to the
  query text.

  Multiplies confidence, logarithmically dampened corroboration, and exponential recency. The
  decay divisor is 2,592,000 seconds (30 days), leaving about 37% after one month.

  It needs no query text and no model, which makes it the fallback that keeps a
  cheap request useful when embedding is unavailable. Expired statements are
  excluded.

  Knowledge only. Returns column-keyed maps, or an empty list when the query
  targets documents. Raises `Postgrex.Error` if the statement fails.
  """
  def salience_recency(query, limit) do
    internal_reader? = query.internal_reader?

    sql = """
    SELECT #{@knowledge_columns},
           (
             k.confidence
             * (1.0 + ln(1 + k.corroboration_count))
             * exp(-extract(epoch FROM (now() - k.updated_at)) / 2592000.0)
           )::float8 AS score,
           'knowledge' AS candidate_type
    FROM knowledge_items AS k
    JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
    WHERE k.account_id = $1
      AND k.scope_id = ANY($2)
    #{visible_knowledge("$3", internal_reader?)}
      AND k.deleted_at IS NULL
      AND (k.expires_at IS NULL OR k.expires_at > now())
    ORDER BY score DESC, k.updated_at DESC
    LIMIT $4
    """

    if query.target in [:knowledge, :all] do
      all(sql, [
        db_uuid!(query.account_id),
        db_uuids!(query.scope_ids),
        db_uuid(query.actor.peer_id),
        limit
      ])
    else
      []
    end
  end

  @doc """
  Finds statements that mention an entity named in the query text.

  The query is split into lowercase terms and matched case-insensitively
  against each entity's canonical name and aliases. Letters and digits plus
  `@`, `.`, `_`, and `-` are kept together so email addresses, hostnames, and
  hyphenated names survive as single terms.

  Entity rows locate statements but never appear in results. Account, scope, lifecycle, and
  provisional filters still apply before candidates leave the query.

  A statement scores by how much the entities it shares with the query narrow
  the scope, not by how sure the extractor was. Each matched entity is weighted
  by inverse frequency over the authorized scopes' visible statements, and a
  statement's score is the share of that weight its own mentions carry, times
  its confidence. The result stays in `0..1`, which `min_score` filtering and
  the `low_score` disagreement hint both depend on.

  Frequency is measured per request rather than cached on the entity row.
  Entities are Account-global while rebuilds are per-scope, so a stored figure
  would be stale for every scope but the last one rebuilt.

  Knowledge only. Returns an empty list when the query targets documents,
  yields no usable terms, or names only entities above the frequency ceiling —
  the last case is a real finding, not a failure, and is what allows
  `query_dependent_empty` to report that nothing resolved the question. Raises
  `Postgrex.Error` if the statement fails.
  """
  def entity_match(query, limit) do
    internal_reader? = query.internal_reader?
    terms = entity_terms(query.text)

    sql = """
    WITH visible AS (
      SELECT k.id
      FROM knowledge_items AS k
      WHERE k.account_id = $1
        AND k.scope_id = ANY($2)
    #{visible_knowledge("$3", internal_reader?)}
        AND k.deleted_at IS NULL
        AND (k.expires_at IS NULL OR k.expires_at > now())
    ),
    corpus AS (
      SELECT greatest(count(*), 1)::float8 AS statements FROM visible
    ),
    matched AS (
      SELECT e.id
      FROM entities AS e
      WHERE e.account_id = $1
        AND EXISTS (
          SELECT 1
          FROM unnest(e.aliases || ARRAY[e.canonical_name]) AS alias
          WHERE lower(alias) = ANY($4)
        )
    ),
    -- One row per entity and statement. An entity named twice in one statement is one
    -- mention here, or it would inflate both the frequency and the statement's own score.
    mention AS (
      SELECT m.entity_id, m.knowledge_item_id, max(m.confidence)::float8 AS confidence
      FROM entity_mentions AS m
      JOIN matched ON matched.id = m.entity_id
      JOIN visible ON visible.id = m.knowledge_item_id
      WHERE m.account_id = $1
      GROUP BY m.entity_id, m.knowledge_item_id
    ),
    -- Smoothed inverse frequency: `ln(1 + N/n)` stays positive when an entity covers the
    -- whole corpus, so a scope too small to measure keeps its recall instead of collapsing
    -- to no candidates. The ceiling below, not a zero weight, is what drops a hub entity.
    weighted AS (
      SELECT mention.entity_id,
             mention.knowledge_item_id,
             mention.confidence,
             count(*) OVER (PARTITION BY mention.entity_id) / corpus.statements AS frequency,
             ln(1 + corpus.statements / count(*) OVER (PARTITION BY mention.entity_id)) AS idf,
             corpus.statements
      FROM mention CROSS JOIN corpus
    ),
    selective AS (
      SELECT * FROM weighted
      WHERE statements < $5 OR frequency <= $6
    ),
    -- Constant per request: the weight a statement would carry if it mentioned every
    -- selective entity the query named. Dividing by it is what bounds the score at 1.
    mass AS (
      SELECT greatest(sum(idf), 1e-9) AS total_idf
      FROM (SELECT DISTINCT entity_id, idf FROM selective) AS per_entity
    ),
    scored AS (
      SELECT selective.knowledge_item_id,
             (sum(selective.idf * selective.confidence) / mass.total_idf)::float8 AS entity_score
      FROM selective CROSS JOIN mass
      GROUP BY selective.knowledge_item_id, mass.total_idf
    ),
    -- Each entity contributes its own best statements only. A hub entity that clears the
    -- ceiling would otherwise fill the list alone and crowd fusion's other inputs out.
    capped AS (
      SELECT DISTINCT ranked.knowledge_item_id
      FROM (
        SELECT selective.knowledge_item_id,
               row_number() OVER (
                 PARTITION BY selective.entity_id
                 ORDER BY scored.entity_score DESC, selective.knowledge_item_id
               ) AS per_entity_rank
        FROM selective
        JOIN scored ON scored.knowledge_item_id = selective.knowledge_item_id
      ) AS ranked
      WHERE ranked.per_entity_rank <= $7
    )
    SELECT #{@knowledge_columns},
           (scored.entity_score * k.confidence)::float8 AS score,
           'knowledge' AS candidate_type
    FROM knowledge_items AS k
    JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
    JOIN scored ON scored.knowledge_item_id = k.id
    JOIN capped ON capped.knowledge_item_id = k.id
    WHERE k.account_id = $1
    ORDER BY score DESC, k.updated_at DESC
    LIMIT $8
    """

    if query.target in [:knowledge, :all] and terms != [] do
      all(sql, [
        db_uuid!(query.account_id),
        db_uuids!(query.scope_ids),
        db_uuid(query.actor.peer_id),
        terms,
        retrieval_config(:entity_match_ceiling_min_statements),
        retrieval_config(:entity_match_frequency_ceiling),
        retrieval_config(:entity_match_per_entity_cap),
        limit
      ])
    else
      []
    end
  end

  @doc """
  Widens a result set by one hop from the seed statements the first retrieval
  phase found.

  Three kinds of edge are followed and unioned:

  * **structural** — explicit recorded relations between two statements, in
    either direction, scored by the edge's own confidence;
  * **shared entity** — two statements that mention the same entity, scored by
    the weaker of the two mention confidences;
  * **scope relation** — statements in a scope explicitly related to a seed's
    scope, scored 1.0.

  Expansion is exactly one hop. Scope links require both endpoints authorized. Shared-entity
  expansion ignores entities that cover too much of the visible corpus and caps neighbours per
  seed. The outer query applies scope, lifecycle, soft-delete, and provisional-subject filters to
  every expanded id.

  Knowledge only. Returns an empty list when the query targets documents or has
  no seed ids. Raises `Postgrex.Error` if the statement fails.
  """
  def relation_expand(query, limit) do
    internal_reader? = query.internal_reader?

    sql = """
    WITH visible AS (
      SELECT k.id
      FROM knowledge_items AS k
      WHERE k.account_id = $1
        AND k.scope_id = ANY($2)
    #{visible_knowledge("$3", internal_reader?)}
        AND k.deleted_at IS NULL
        AND (k.expires_at IS NULL OR k.expires_at > now())
    ),
    corpus AS (
      SELECT greatest(count(*), 1)::float8 AS statements FROM visible
    ),
    mention_frequency AS (
      SELECT m.entity_id,
             count(DISTINCT m.knowledge_item_id) / corpus.statements AS frequency,
             corpus.statements
      FROM entity_mentions AS m
      JOIN visible ON visible.id = m.knowledge_item_id
      CROSS JOIN corpus
      WHERE m.account_id = $1
      GROUP BY m.entity_id, corpus.statements
    ),
    eligible_entity AS (
      SELECT entity_id
      FROM mention_frequency
      WHERE statements < $6 OR frequency <= $7
    ),
    structural AS (
      SELECT
        CASE
          WHEN r.source_knowledge_id = ANY($4) THEN r.target_knowledge_id
          ELSE r.source_knowledge_id
        END AS knowledge_id,
        r.confidence AS edge_score
      FROM knowledge_relations AS r
      WHERE r.account_id = $1
        AND (r.source_knowledge_id = ANY($4) OR r.target_knowledge_id = ANY($4))
    ),
    seed_mention AS (
      SELECT seed.knowledge_item_id, seed.entity_id, max(seed.confidence)::float8 AS confidence
      FROM entity_mentions AS seed
      JOIN eligible_entity ON eligible_entity.entity_id = seed.entity_id
      WHERE seed.account_id = $1
        AND seed.knowledge_item_id = ANY($4)
      GROUP BY seed.knowledge_item_id, seed.entity_id
    ),
    shared_entity AS (
      SELECT neighbour.knowledge_id, neighbour.edge_score
      FROM (SELECT DISTINCT knowledge_item_id FROM seed_mention) AS seed
      CROSS JOIN LATERAL (
        SELECT other.knowledge_item_id AS knowledge_id,
               max(least(seed_entity.confidence, other.confidence))::float8 AS edge_score
        FROM seed_mention AS seed_entity
        JOIN entity_mentions AS other
          ON other.account_id = $1
         AND other.entity_id = seed_entity.entity_id
         AND other.knowledge_item_id <> seed.knowledge_item_id
        JOIN visible ON visible.id = other.knowledge_item_id
        WHERE seed_entity.knowledge_item_id = seed.knowledge_item_id
        GROUP BY other.knowledge_item_id
        ORDER BY edge_score DESC, other.knowledge_item_id
        LIMIT $8
      ) AS neighbour
    ),
    scope_expanded AS (
      SELECT related.id AS knowledge_id, 1.0::float8 AS edge_score
      FROM knowledge_items AS seed
      JOIN scope_relations AS relation
        ON relation.account_id = seed.account_id
       AND (
         relation.source_scope_id = seed.scope_id
         OR relation.target_scope_id = seed.scope_id
       )
      JOIN knowledge_items AS related
        ON related.account_id = seed.account_id
       AND related.scope_id = CASE
         WHEN relation.source_scope_id = seed.scope_id THEN relation.target_scope_id
         ELSE relation.source_scope_id
       END
      WHERE seed.account_id = $1
        AND seed.id = ANY($4)
        AND relation.source_scope_id = ANY($2)
        AND relation.target_scope_id = ANY($2)
    ),
    expanded AS (
      SELECT * FROM structural
      UNION ALL
      SELECT * FROM shared_entity
      UNION ALL
      SELECT * FROM scope_expanded
    )
    SELECT #{@knowledge_columns},
           max(expanded.edge_score * k.confidence)::float8 AS score,
           'knowledge' AS candidate_type
    FROM expanded
    JOIN knowledge_items AS k ON k.id = expanded.knowledge_id AND k.account_id = $1
    JOIN scopes AS s ON s.id = k.scope_id AND s.account_id = k.account_id
    WHERE k.scope_id = ANY($2)
    #{visible_knowledge("$3", internal_reader?)}
      AND k.deleted_at IS NULL
      AND (k.expires_at IS NULL OR k.expires_at > now())
    GROUP BY k.id, s.path
    ORDER BY score DESC, k.updated_at DESC
    LIMIT $5
    """

    if query.target in [:knowledge, :all] and query.seed_ids != [] do
      all(sql, [
        db_uuid!(query.account_id),
        db_uuids!(query.scope_ids),
        db_uuid(query.actor.peer_id),
        db_uuids!(query.seed_ids),
        limit,
        retrieval_config(:relation_expand_ceiling_min_statements),
        retrieval_config(:relation_expand_frequency_ceiling),
        retrieval_config(:relation_expand_per_seed_cap)
      ])
    else
      []
    end
  end

  # The reader filter every knowledge query interpolates. `peer` is the SQL parameter holding the
  # reader's peer id; `internal_reader?` is the caller's own posture, never a value from a request.
  #
  # An internal reader is reading on nobody's behalf — a projection rebuild, dream-time, an
  # evaluation run — and must see the corpus as it is, so only lifecycle narrows it.
  #
  # A peer-facing reader with a peer sees anything not personal, its own statements, statements
  # about the scope rather than about a person, and anything promoted to scope or account level.
  # Promotion is the consent record: an above-peer proposal parks in `held` until its subject
  # agrees, so an `active` row at scope level has already been agreed to.
  #
  # A reader with no peer identifies nobody and sees public statements only.
  defp visible_knowledge(peer, true) do
    """
    AND k.state IN ('active', 'provisional')
        -- An internal reader ignores the reader peer, but the parameter is still bound.
        -- The cast is what gives PostgreSQL its type; nothing else here refers to it.
        AND (#{peer}::uuid IS NULL OR TRUE)\
    """
  end

  defp visible_knowledge(peer, false) do
    """
    AND (
          k.state = 'active'
          OR (k.state = 'provisional'
              AND #{peer}::uuid IS NOT NULL AND k.subject_peer_id = #{peer})
        )
        #{readable_by(peer)}\
    """
  end

  # The reader half alone, for the query that already spells its own lifecycle filter.
  defp co_mention_sensitivity(_peer, true), do: ""
  defp co_mention_sensitivity(peer, false), do: readable_by(peer)

  # Parenthesised in full rather than relying on `AND` binding tighter than `OR`. This is the
  # clause that decides who reads whose memory; it must be right by reading, not by precedence.
  defp readable_by(peer) do
    """
    AND (
          (k.sensitivity = 'public')
          OR (
            #{peer}::uuid IS NOT NULL
            AND (
              k.sensitivity = 'internal'
              OR k.subject_peer_id IS NULL
              OR k.subject_peer_id = #{peer}
              OR k.target_level IN ('scope', 'account')
            )
          )
        )\
    """
  end

  # Builds static `tsquery` SQL for the analyzer's bound values. The analyzer never generates SQL;
  # a long question can increase only parameter size, never the shape of this authorized query.
  #
  # Only the disjunctive branch reaches for the lexemes directly: `to_tsvector` normalizes them
  # the same way the stored `search_vector` was normalized, `tsquery` input is taken verbatim
  # rather than stemmed a second time, and `quote_literal` stops a lexeme holding `&`, `|`, or a
  # quote from being read as an operator. Text with no lexemes aggregates to NULL, which matches
  # nothing — the same outcome `websearch_to_tsquery` gives for stopwords alone.
  defp tsquery(%{mode: :websearch}, parameter),
    do: "websearch_to_tsquery('english', #{parameter})"

  defp tsquery(%{mode: :normalized}, parameter) do
    "(SELECT string_agg(quote_literal(lexeme), ' | ') " <>
      "FROM unnest(to_tsvector('english', #{parameter})))::tsquery"
  end

  # A websearch query, and any query with fewer than two retained terms, has no proximity
  # representation and binds NULL here. `to_tsquery` is strict, so the rank collapses to NULL and
  # the caller's `coalesce` scores it zero. Passing an empty string instead would make PostgreSQL
  # raise a "query doesn't contain lexemes" notice on every such search.
  defp proximity_tsquery(parameter), do: "to_tsquery('english', #{parameter}::text)"

  @doc """
  Summarizes the Account's private entity-resolution cache without returning
  an entity, mention, name, alias, surface form, or identifier.

  The alias histogram counts observed spellings per entity. The singleton rate
  is the share of entities linked to exactly one statement mention. Mention
  percentiles use discrete values so every reported number describes an
  actual entity in the cache.

  This query is for the account-administrator console only. Its caller must
  establish that authorization before entering this reviewed read-only store.
  Returns a content-free map. Raises `Postgrex.Error` if the statement fails.
  """
  def entity_resolution_metrics(account_id) do
    sql = """
    WITH per_entity AS (
      SELECT e.id,
             cardinality(e.aliases)::bigint AS alias_count,
             count(m.id)::bigint AS mention_count
      FROM entities AS e
      LEFT JOIN entity_mentions AS m
        ON m.account_id = e.account_id AND m.entity_id = e.id
      WHERE e.account_id = $1
      GROUP BY e.id, e.aliases
    )
    SELECT count(*)::bigint AS entity_count,
           coalesce(sum(mention_count), 0)::bigint AS mention_count,
           coalesce(
             count(*) FILTER (WHERE mention_count = 1)::float8 /
               nullif(count(*), 0),
             0.0
           )::float8 AS singleton_entity_rate,
           coalesce(
             percentile_disc(0.50) WITHIN GROUP (ORDER BY mention_count),
             0
           )::bigint AS mentions_per_entity_p50,
           coalesce(
             percentile_disc(0.95) WITHIN GROUP (ORDER BY mention_count),
             0
           )::bigint AS mentions_per_entity_p95,
           count(*) FILTER (WHERE alias_count = 0)::bigint AS aliases_0,
           count(*) FILTER (WHERE alias_count = 1)::bigint AS aliases_1,
           count(*) FILTER (WHERE alias_count BETWEEN 2 AND 3)::bigint AS aliases_2_3,
           count(*) FILTER (WHERE alias_count BETWEEN 4 AND 7)::bigint AS aliases_4_7,
           count(*) FILTER (WHERE alias_count >= 8)::bigint AS aliases_8_plus
    FROM per_entity
    """

    [row] = all(sql, [db_uuid!(account_id)])

    %{
      entity_count: row["entity_count"],
      mention_count: row["mention_count"],
      singleton_entity_rate: row["singleton_entity_rate"],
      mentions_per_entity_p50: row["mentions_per_entity_p50"],
      mentions_per_entity_p95: row["mentions_per_entity_p95"],
      aliases_per_entity: [
        %{range: "0", entity_count: row["aliases_0"]},
        %{range: "1", entity_count: row["aliases_1"]},
        %{range: "2–3", entity_count: row["aliases_2_3"]},
        %{range: "4–7", entity_count: row["aliases_4_7"]},
        %{range: "8+", entity_count: row["aliases_8_plus"]}
      ]
    }
  end

  @doc """
  Counts other visible statements sharing an entity with one seed and returns
  up to `limit` of their ids.

  Account, authorized scope, lifecycle, soft-delete, and reader filters are
  applied before an id is counted or leaves this boundary. The result contains
  only the total and statement ids; no entity or mention identity is returned.
  An empty authorized-scope list fails closed.

  `internal_reader?` carries the caller's posture and has no default: a browser
  read and a rebuild must each say which one it is.
  """
  def co_mentioned_knowledge(
        account_id,
        knowledge_id,
        scope_ids,
        visible_states,
        peer_id,
        internal_reader?,
        limit
      )
      when is_list(scope_ids) and is_list(visible_states) and is_boolean(internal_reader?) and
             is_integer(limit) and limit > 0 do
    sql = """
    WITH seed_entities AS (
      SELECT DISTINCT entity_id
      FROM entity_mentions
      WHERE account_id = $1 AND knowledge_item_id = $2
    ), visible AS (
      SELECT DISTINCT k.id
      FROM seed_entities AS seed
      JOIN entity_mentions AS mention
        ON mention.account_id = $1 AND mention.entity_id = seed.entity_id
      JOIN knowledge_items AS k
        ON k.account_id = mention.account_id AND k.id = mention.knowledge_item_id
      WHERE k.id <> $2
        AND k.scope_id = ANY($3)
        AND (k.state = ANY($4) OR ($5::uuid IS NOT NULL AND k.subject_peer_id = $5))
        AND (k.state <> 'provisional' OR ($5::uuid IS NOT NULL AND k.subject_peer_id = $5))
        #{co_mention_sensitivity("$5", internal_reader?)}
        AND k.deleted_at IS NULL
        AND (k.expires_at IS NULL OR k.expires_at > now())
    )
    SELECT id, count(*) OVER()::bigint AS total_count
    FROM visible
    ORDER BY id
    LIMIT $6
    """

    rows =
      all(sql, [
        db_uuid!(account_id),
        db_uuid!(knowledge_id),
        db_uuids!(scope_ids),
        visible_states,
        db_uuid(peer_id),
        limit
      ])

    count = if rows == [], do: 0, else: rows |> hd() |> Map.fetch!("total_count")

    %{count: count, ids: Enum.map(rows, &Map.fetch!(&1, "id"))}
  end

  def co_mentioned_knowledge(
        _account_id,
        _knowledge_id,
        _scope_ids,
        _states,
        _peer_id,
        _internal_reader?,
        _limit
      ),
      do: %{count: 0, ids: []}

  @doc """
  Groups statements that share an entity, without naming the entity.

  `knowledge_ids` must already be authorized by the caller: this query does no
  lifecycle, scope, or subject filtering and will link any id it is handed. It
  exists to describe a set the caller has already decided to show, so passing an
  unfiltered set would disclose membership the caller never checked.

  A group needs at least two members, because a single-member group carries no
  relationship and would only report that some private cache row exists. Groups
  with identical membership are collapsed, so two entities shared by the same
  statements read as one link rather than hinting at how many entities resolved.

  Returns `%{count:, clusters:}` where `count` is the number of distinct groups
  before `limit`. Each cluster is `%{members:, entity_ids:}`: a sorted list of
  statement ids, and the entity ids that produced exactly that membership.

  `entity_ids` is a private cache coordinate for the caller's own lookups, such
  as finding a group's entity card. It must not reach a payload, and a group
  holding more than one id must not disclose that count. Callers that cannot
  honour both rules should ignore the field.
  """
  def shared_entity_clusters(account_id, knowledge_ids, limit)
      when is_list(knowledge_ids) and is_integer(limit) and limit > 0 and knowledge_ids != [] do
    sql = """
    WITH grouped AS (
      SELECT m.entity_id,
             array_agg(DISTINCT m.knowledge_item_id::text
                       ORDER BY m.knowledge_item_id::text) AS members
      FROM entity_mentions AS m
      WHERE m.account_id = $1 AND m.knowledge_item_id = ANY($2)
      GROUP BY m.entity_id
      HAVING count(DISTINCT m.knowledge_item_id) >= 2
    ), distinct_groups AS (
      SELECT members,
             array_agg(DISTINCT entity_id::text ORDER BY entity_id::text) AS entity_ids
      FROM grouped
      GROUP BY members
    )
    SELECT members, entity_ids, count(*) OVER()::bigint AS total_count
    FROM distinct_groups
    ORDER BY members
    LIMIT $3
    """

    rows = all(sql, [db_uuid!(account_id), db_uuids!(knowledge_ids), limit])
    count = if rows == [], do: 0, else: rows |> hd() |> Map.fetch!("total_count")

    clusters =
      Enum.map(rows, fn row ->
        %{members: Map.fetch!(row, "members"), entity_ids: Map.fetch!(row, "entity_ids")}
      end)

    %{count: count, clusters: clusters}
  end

  def shared_entity_clusters(_account_id, _knowledge_ids, _limit),
    do: %{count: 0, clusters: []}

  @doc """
  Pairs the entities that are named together inside one statement.

  Co-mention is not a semantic relation. It says two referents appeared in the same sentence, not
  that they are related, and there is no entity-relation table behind it. A caller that renders
  these must say so.

  `knowledge_ids` must already be authorized, exactly as for `shared_entity_clusters/3`: both ends
  of every pair come from one statement in that set, which is what makes an edge disclose nothing
  the caller has not already decided to show.

  `entity_ids` narrows the result to entities the caller can already draw. Passing the full set
  would return pairs whose endpoints have no node, and an edge to nowhere reports that an unseen
  entity exists.

  Returns a list of `{left, right}` tuples, each ordered and deduplicated, so one pair appears
  once however many statements produced it. Returns `[]` when either list is empty.
  """
  def co_mentioned_entity_pairs(account_id, knowledge_ids, entity_ids)
      when is_list(knowledge_ids) and is_list(entity_ids) and knowledge_ids != [] and
             entity_ids != [] do
    # The strict inequality does both jobs: it drops the self-pair a join of a row against itself
    # would produce, and it keeps only one direction of each pair.
    sql = """
    SELECT DISTINCT left_side.entity_id::text AS left_id,
                    right_side.entity_id::text AS right_id
    FROM entity_mentions AS left_side
    JOIN entity_mentions AS right_side
      ON right_side.account_id = left_side.account_id
     AND right_side.knowledge_item_id = left_side.knowledge_item_id
     AND right_side.entity_id > left_side.entity_id
    WHERE left_side.account_id = $1
      AND left_side.knowledge_item_id = ANY($2)
      AND left_side.entity_id = ANY($3)
      AND right_side.entity_id = ANY($3)
    ORDER BY left_id, right_id
    """

    sql
    |> all([db_uuid!(account_id), db_uuids!(knowledge_ids), db_uuids!(entity_ids)])
    |> Enum.map(&{Map.fetch!(&1, "left_id"), Map.fetch!(&1, "right_id")})
  end

  def co_mentioned_entity_pairs(_account_id, _knowledge_ids, _entity_ids), do: []

  @doc """
  Counts, per scope, how much of the retrievable corpus is actually indexed.

  Embeddings and entity mentions are written by a background rebuild, so a scope
  can hold every governed statement and still answer nothing semantically. This
  is the query that makes that state visible.

  The visible set is the one the indexer covers — active plus provisional, minus
  soft deletions — narrowed by the same reader rule every other query here
  applies, so a caller never learns the count of statements it could not read.
  `internal_reader?` lifts that narrowing for the rebuild that has to cover the
  whole corpus; a peer-facing caller with a nil `peer_id` counts only public
  statements.

  Returns one map per scope that has at least one visible statement, carrying
  `scope_id`, `statement_count`, `embedded_count`, `mention_count`,
  `mentioned_statement_count`, and
  `embedding_identities` (the distinct provider/model/version/dimensions tuples
  in use; more than one means part of the scope needs re-embedding). Scopes with
  nothing visible are absent rather than zero-filled. Raises `Postgrex.Error` if
  the statement fails.
  """
  def index_coverage(account_id, scope_ids, peer_id, internal_reader?)
      when is_boolean(internal_reader?) do
    sql = """
    WITH visible AS (
      SELECT k.id, k.scope_id,
             (k.embedding IS NOT NULL) AS embedded,
             k.embedding_provider, k.embedding_model,
             k.embedding_version, k.embedding_dimensions
      FROM knowledge_items AS k
      WHERE k.account_id = $1
        AND k.scope_id = ANY($2)
        #{visible_knowledge("$3", internal_reader?)}
        AND k.deleted_at IS NULL
    ),
    mentions AS (
      SELECT visible.scope_id,
             count(*) AS mention_count,
             count(DISTINCT visible.id) AS mentioned_statement_count
      FROM entity_mentions AS m
      JOIN visible ON visible.id = m.knowledge_item_id
      WHERE m.account_id = $1
      GROUP BY visible.scope_id
    )
    SELECT visible.scope_id,
           count(*)::bigint AS statement_count,
           count(*) FILTER (WHERE visible.embedded)::bigint AS embedded_count,
           coalesce(max(mentions.mention_count), 0)::bigint AS mention_count,
           coalesce(max(mentions.mentioned_statement_count), 0)::bigint
             AS mentioned_statement_count,
           coalesce(
             jsonb_agg(DISTINCT jsonb_build_object(
               'provider', visible.embedding_provider,
               'model', visible.embedding_model,
               'version', visible.embedding_version,
               'dimensions', visible.embedding_dimensions
             )) FILTER (WHERE visible.embedded),
             '[]'::jsonb
           ) AS embedding_identities
    FROM visible
    LEFT JOIN mentions ON mentions.scope_id = visible.scope_id
    GROUP BY visible.scope_id
    """

    all(sql, [db_uuid!(account_id), db_uuids!(scope_ids), db_uuid(peer_id)])
  end

  @doc """
  Classifies whether query terms resolve through the private entity cache.

  Returns only `:query_resolved_no_entity`,
  `:entity_found_no_authorized_statements`, or `:entity_found`. The first means
  no canonical name or alias matched. The second means an Account-local entity
  matched but no statement survived the supplied scope, lifecycle, and subject
  filters. No entity or statement identity leaves this boundary.
  """
  def entity_match_status(query) do
    internal_reader? = query.internal_reader?
    terms = entity_terms(query.text)

    sql = """
    WITH matched_entities AS (
      SELECT e.id
      FROM entities AS e
      WHERE e.account_id = $1
        AND EXISTS (
          SELECT 1
          FROM unnest(e.aliases || ARRAY[e.canonical_name]) AS alias
          WHERE lower(alias) = ANY($4)
        )
    ), authorized AS (
      SELECT 1
      FROM matched_entities AS e
      JOIN entity_mentions AS m ON m.entity_id = e.id AND m.account_id = $1
      JOIN knowledge_items AS k ON k.id = m.knowledge_item_id AND k.account_id = $1
      WHERE k.scope_id = ANY($2)
        #{visible_knowledge("$3", internal_reader?)}
        AND k.deleted_at IS NULL
        AND (k.expires_at IS NULL OR k.expires_at > now())
      LIMIT 1
    )
    SELECT EXISTS(SELECT 1 FROM matched_entities) AS entity_found,
           EXISTS(SELECT 1 FROM authorized) AS authorized_found
    """

    if query.target in [:knowledge, :all] and terms != [] do
      [row] =
        all(sql, [
          db_uuid!(query.account_id),
          db_uuids!(query.scope_ids),
          db_uuid(query.actor.peer_id),
          terms
        ])

      cond do
        row["authorized_found"] -> :entity_found
        row["entity_found"] -> :entity_found_no_authorized_statements
        true -> :query_resolved_no_entity
      end
    else
      :query_resolved_no_entity
    end
  end

  @doc """
  Finds active scopes whose corpus has no derived entity mentions.

  Returns scope ids with a content-free watermark derived from the statement
  count and latest update. It is for the Account reconciler, which already runs
  under a system actor and row-level security.
  """
  def scopes_missing_mentions(account_id, limit \\ 100) do
    sql = """
    SELECT k.scope_id,
           count(*)::bigint AS statement_count,
           max(k.updated_at) AS latest_statement_at
    FROM knowledge_items AS k
    LEFT JOIN entity_mentions AS m
      ON m.knowledge_item_id = k.id AND m.account_id = k.account_id
    WHERE k.account_id = $1
      AND k.state = 'active'
      AND k.deleted_at IS NULL
      AND (k.expires_at IS NULL OR k.expires_at > now())
    GROUP BY k.scope_id
    HAVING count(m.id) = 0
    ORDER BY max(k.updated_at), k.scope_id
    LIMIT $2
    """

    all(sql, [db_uuid!(account_id), limit])
  end

  @doc """
  Finds the latest Oban job state for each idempotency key.

  Queries the `oban_jobs` infrastructure table by replay keys and returns the
  most recent state per key. An empty key list returns an empty map without
  querying.

  Returns a map from idempotency key to job state string (`"pending"`,
  `"available"`, `"executing"`, `"completed"`, `"cancelled"`, `"discarded"`).
  Raises `Postgrex.Error` if the statement fails.
  """
  def latest_oban_job_states([]), do: %{}

  def latest_oban_job_states(keys) when is_list(keys) do
    sql = """
    SELECT DISTINCT ON (args->>'idempotency_key')
           args->>'idempotency_key' AS idempotency_key, state
    FROM oban_jobs
    WHERE args->>'idempotency_key' = ANY($1)
    ORDER BY args->>'idempotency_key', id DESC
    """

    rows = all(sql, [keys])
    Map.new(rows, fn row -> {row["idempotency_key"], row["state"]} end)
  end

  # Merge only halves scored by the same function, then restore the shared cap.
  defp top(rows, limit),
    do: rows |> Enum.sort_by(&(&1["score"] || 0.0), :desc) |> Enum.take(limit)

  defp entity_terms(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]@._-]+/u, trim: true)
    |> Enum.uniq()
  end

  # Build pgvector text as a bound parameter; coerce integers before `Float.to_string/1`.
  defp vector_literal(values) do
    "[" <> Enum.map_join(values, ",", &Float.to_string(&1 * 1.0)) <> "]"
  end

  # These settings change ranking, so a missing key must fail rather than default.
  defp retrieval_config(key) do
    :memhouse
    |> Application.fetch_env!(:retrieval_profiles)
    |> Keyword.fetch!(key)
  end

  # SQL is static and parameterized inside this reviewed data-layer boundary.
  # sobelow_skip ["SQL.Query"]
  defp all(sql, params) do
    %{columns: columns, rows: rows} = Ecto.Adapters.SQL.query!(Repo, sql, params)

    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {column, value} -> {column, normalize_db_value(column, value)} end)
    end)
  end

  # Restore raw 16-byte UUID columns to caller-facing strings.
  defp normalize_db_value(column, value)
       when column == "id" or
              (byte_size(column) >= 3 and
                 binary_part(column, byte_size(column) - 3, 3) == "_id") do
    normalize_uuid(value)
  end

  defp normalize_db_value("source_message_ids", values) when is_list(values),
    do: Enum.map(values, &normalize_uuid/1)

  defp normalize_db_value(_column, value), do: value

  defp normalize_uuid(<<_::128>> = value), do: Ecto.UUID.load!(value)
  defp normalize_uuid(value), do: value

  # Accept string or dumped UUIDs; nil is only for optional peer id, and malformed ids raise.
  defp db_uuids!(values), do: Enum.map(values, &db_uuid!/1)
  defp db_uuid(nil), do: nil
  defp db_uuid(value), do: db_uuid!(value)
  defp db_uuid!(<<_::128>> = value), do: value
  defp db_uuid!(value), do: Ecto.UUID.dump!(value)
end
