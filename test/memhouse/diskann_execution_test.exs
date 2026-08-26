# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.DiskannExecutionTest.Provider do
  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result

  @impl true
  def embed(_config, texts, _opts) do
    vector = [1.0, 0.0] ++ List.duplicate(0.0, 1022)
    {:ok, %Result{value: Enum.map(texts, fn _text -> vector end), metadata: %{fixture: true}}}
  end

  @impl true
  def structured(_config, _messages, _schema, _opts), do: {:error, :provider_calls_forbidden}

  @impl true
  def chat(_config, _messages, _opts), do: {:error, :provider_calls_forbidden}

  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :provider_calls_forbidden}
end

defmodule MemHouse.DiskannExecutionTest do
  use MemHouse.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias MemHouse.{DataLayer, Memory, Repo}
  alias MemHouse.Retrieval.{Query, Store}

  @account_key "diskann-execution"
  @scope_path "/diskann-execution"
  @identity %{
    provider: "offline-diskann-test",
    model: "known-angle-vectors",
    version: "v1",
    dimensions: 1024
  }
  @query_vector [1.0, 0.0] ++ List.duplicate(0.0, 1022)

  setup do
    original_provider = Application.get_env(:memhouse, :model_provider)
    original_roles = Application.fetch_env!(:memhouse, :model_roles)

    roles =
      Keyword.update!(original_roles, :embedder, fn role ->
        role
        |> Map.put(:provider, @identity.provider)
        |> Map.put(:model, @identity.model)
        |> Map.put(:model_version, @identity.version)
        |> Map.put(:embedding_dimensions, @identity.dimensions)
        |> Map.put(:options, %{})
      end)

    Application.put_env(:memhouse, :model_provider, MemHouse.DiskannExecutionTest.Provider)
    Application.put_env(:memhouse, :model_roles, roles)

    on_exit(fn ->
      Application.put_env(:memhouse, :model_roles, original_roles)

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end
    end)

    :ok
  end

  test "1024-dimensional DiskANN executes at an internal limit of 150" do
    assert_diskann_indexes_use_real_attributes!()
    fixture = seed_known_vectors!()
    assert_unconstrained_vector_preserved!(fixture)

    internal =
      DataLayer.in_account_transaction(fixture.account_id, fn ->
        SQL.query!(Repo, "SAVEPOINT diskann_execution_settings", [])

        try do
          SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])
          SQL.query!(Repo, "SET LOCAL enable_sort = off", [])

          query = %Query{
            account_id: fixture.account_id,
            actor: fixture.actor,
            text: "known query",
            target: :knowledge,
            scope_ids: [fixture.scope_id],
            max_candidates: 150,
            internal_reader?: true
          }

          {rows, log} = with_log(fn -> Store.semantic(query, @query_vector, @identity, 150) end)
          refute log =~ "retrying with index scans disabled"

          assert diskann_settings() == %{search_list: "300", rescore: "150"}
          assert length(rows) == 150

          {exact_ids, plan} = exact_reference_and_plan!(fixture)
          ann_ids = Enum.map(rows, & &1["id"])
          overlap = MapSet.intersection(MapSet.new(ann_ids), MapSet.new(exact_ids))

          assert MapSet.size(overlap) >= 149

          encoded_plan = Jason.encode!(plan)
          assert encoded_plan =~ "knowledge_items_embedding_diskann_1024_idx"
          assert encoded_plan =~ "Index Scan"

          %{returned: length(rows), tail: Enum.slice(ann_ids, 100, 50)}
        after
          SQL.query!(Repo, "ROLLBACK TO SAVEPOINT diskann_execution_settings", [])
          SQL.query!(Repo, "RELEASE SAVEPOINT diskann_execution_settings", [])
        end
      end)

    assert internal.returned == 150
    assert length(internal.tail) == 50

    for {requested, expected} <- [{50, 50}, {100, 100}, {100_000, 100}] do
      result = public_search_with_settings_rollback(requested)
      assert length(result["candidates"]) == expected
      refute result["degraded"]
      assert [%{status: "completed", component: "semantic"}] = result["retrieval_outcomes"]
    end

    assert DataLayer.in_account_transaction(fixture.account_id, &diskann_settings/0) == %{
             search_list: "100",
             rescore: "50"
           }
  end

  defp seed_known_vectors! do
    DataLayer.with_account_key(@account_key, [role: :system], fn account, actor ->
      account_db = Ecto.UUID.dump!(account.id)

      %{rows: [[scope_db]]} =
        SQL.query!(
          Repo,
          """
          INSERT INTO scopes
            (account_id, key, name, path, state, diskann_label, inserted_at, updated_at)
          VALUES ($1, 'diskann-execution', 'DiskANN execution', $2, 'active', 2340, now(), now())
          RETURNING id
          """,
          [account_db, @scope_path]
        )

      SQL.query!(
        Repo,
        """
        INSERT INTO knowledge_items
          (account_id, scope_id, statement, kind, confidence, sensitivity, state,
           source_message_ids, pipeline_version, inserted_at, updated_at, statement_hash,
           target_level, verification, corroboration_count, embedding_provider,
           embedding_model, embedding_version, embedding, embedding_dimensions,
           evidence_level, diskann_labels, contributor_ids)
        SELECT $1, $2, 'known-vector-rank-' || lpad(i::text, 3, '0'), 'fact', 1.0,
               'internal', 'active', ARRAY[]::uuid[], 'diskann-execution-v1', now(), now(),
               encode(digest('known-vector-rank-' || i::text, 'sha256'), 'hex'),
               'scope', 'verified', 1, $3, $4, $5,
               ((ARRAY[cos(i * 0.005)::real, sin(i * 0.005)::real]) ||
                array_fill(0::real, ARRAY[1022]))::vector,
               1024, 'direct', ARRAY[2340]::smallint[], ARRAY[]::uuid[]
        FROM generate_series(1, 300) AS i
        """,
        [account_db, scope_db, @identity.provider, @identity.model, @identity.version]
      )

      SQL.query!(Repo, "ANALYZE knowledge_items", [])

      %{
        account_id: account.id,
        scope_id: Ecto.UUID.load!(scope_db),
        scope_db: scope_db,
        actor: actor
      }
    end)
  end

  defp assert_diskann_indexes_use_real_attributes! do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT index_class.relname, attribute.attname
        FROM pg_index AS idx
        JOIN pg_class AS index_class ON index_class.oid = idx.indexrelid
        JOIN pg_attribute AS attribute
          ON attribute.attrelid = idx.indrelid
         AND attribute.attnum = idx.indkey[0]
        WHERE index_class.relname = ANY($1)
        ORDER BY index_class.relname
        """,
        [
          [
            "document_chunks_embedding_diskann_1024_idx",
            "knowledge_items_embedding_diskann_1024_idx",
            "messages_source_embedding_diskann_1024_idx",
            "recall_documents_embedding_diskann_1024_idx"
          ]
        ]
      )

    assert rows == [
             ["document_chunks_embedding_diskann_1024_idx", "embedding_1024"],
             ["knowledge_items_embedding_diskann_1024_idx", "embedding_1024"],
             ["messages_source_embedding_diskann_1024_idx", "embedding_1024"],
             ["recall_documents_embedding_diskann_1024_idx", "embedding_1024"]
           ]
  end

  defp exact_reference_and_plan!(fixture) do
    sql = """
    SELECT k.id, k.statement
    FROM knowledge_items AS k
    WHERE k.account_id = $1
      AND k.scope_id = ANY($2)
      AND k.state = 'active'
      AND k.deleted_at IS NULL
      AND (k.expires_at IS NULL OR k.expires_at > now())
      AND k.embedding IS NOT NULL
      AND k.embedding_1024 IS NOT NULL
      AND k.embedding_provider = $4
      AND k.embedding_model = $5
      AND k.embedding_version = $6
      AND k.embedding_dimensions = 1024
      AND k.diskann_labels && $7::smallint[]
    ORDER BY k.embedding_1024 <=> $3::text::vector(1024)
    LIMIT $8
    """

    params = [
      Ecto.UUID.dump!(fixture.account_id),
      [fixture.scope_db],
      vector_literal(@query_vector),
      @identity.provider,
      @identity.model,
      @identity.version,
      [2340],
      150
    ]

    plan = SQL.query!(Repo, "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <> sql, params)
    SQL.query!(Repo, "SET LOCAL enable_indexscan = off", [])
    exact = SQL.query!(Repo, sql, params)

    exact_ids = Enum.map(exact.rows, fn [id, _statement] -> Ecto.UUID.load!(id) end)
    {exact_ids, plan.rows |> hd() |> hd()}
  end

  defp assert_unconstrained_vector_preserved!(fixture) do
    %{rows: [[3, true]]} =
      SQL.query!(
        Repo,
        """
        INSERT INTO knowledge_items
          (account_id, scope_id, statement, kind, confidence, sensitivity, state,
           source_message_ids, pipeline_version, inserted_at, updated_at, statement_hash,
           target_level, verification, corroboration_count, embedding_provider,
           embedding_model, embedding_version, embedding, embedding_dimensions,
           evidence_level, diskann_labels, contributor_ids)
        VALUES ($1, $2, 'non-indexed-width', 'fact', 1.0, 'internal', 'active',
                ARRAY[]::uuid[], 'diskann-execution-v1', now(), now(),
                encode(digest('non-indexed-width', 'sha256'), 'hex'), 'scope',
                'verified', 1, $3, $4, $5, '[1,2,3]'::vector, 3, 'direct',
                ARRAY[2340]::smallint[], ARRAY[]::uuid[])
        RETURNING vector_dims(embedding), embedding_1024 IS NULL
        """,
        [
          Ecto.UUID.dump!(fixture.account_id),
          fixture.scope_db,
          @identity.provider,
          @identity.model,
          @identity.version
        ]
      )
  end

  defp public_search_with_settings_rollback(requested) do
    {:error, result} =
      Repo.transaction(fn ->
        result =
          Memory.search(%{
            "account_key" => @account_key,
            "scope_path" => @scope_path,
            "query" => "known query",
            "limit" => Integer.to_string(requested),
            "strategies" => ["semantic"],
            "deadline" => "disabled",
            "_retrieval_target" => "knowledge"
          })

        Repo.rollback(result)
      end)

    result
  end

  defp diskann_settings do
    %{rows: [[search_list, rescore]]} =
      SQL.query!(
        Repo,
        """
        SELECT current_setting('diskann.query_search_list_size', true),
               current_setting('diskann.query_rescore', true)
        """,
        []
      )

    %{search_list: search_list, rescore: rescore}
  end

  defp vector_literal(values), do: "[" <> Enum.join(values, ",") <> "]"
end
