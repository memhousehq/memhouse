# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.DiskannScopeLabelPrefilter do
  @moduledoc false

  use Ecto.Migration

  # Replacing a DiskANN index must not hold a table lock for its full build.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    options = diskann_options!()

    execute "ALTER TABLE scopes ADD COLUMN diskann_label smallint"

    execute "ALTER TABLE knowledge_items ADD COLUMN diskann_labels smallint[] NOT NULL DEFAULT '{}'"

    execute "ALTER TABLE document_chunks ADD COLUMN diskann_labels smallint[] NOT NULL DEFAULT '{}'"

    # Labels are dense per Account, not globally. Existing scopes receive a
    # deterministic value, and the guard prevents a silent duplicate when an
    # Account cannot fit in pgvectorscale's signed-smallint label range.
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM scopes GROUP BY account_id HAVING count(*) > 65536) THEN
        RAISE EXCEPTION 'DiskANN label capacity exhausted for Account';
      END IF;
    END $$;
    """

    execute """
    WITH numbered AS (
      SELECT id,
             (-32768 + row_number() OVER (PARTITION BY account_id ORDER BY path, id) - 1)::smallint AS label
      FROM scopes
    )
    UPDATE scopes AS scope
    SET diskann_label = numbered.label
    FROM numbered
    WHERE scope.id = numbered.id
    """

    execute """
    UPDATE knowledge_items AS item
    SET diskann_labels = ARRAY[scope.diskann_label]
    FROM scopes AS scope
    WHERE scope.id = item.scope_id AND scope.account_id = item.account_id
    """

    execute """
    UPDATE document_chunks AS chunk
    SET diskann_labels = ARRAY[scope.diskann_label]
    FROM scopes AS scope
    WHERE scope.id = chunk.scope_id AND scope.account_id = chunk.account_id
    """

    execute """
    CREATE UNIQUE INDEX CONCURRENTLY scopes_account_diskann_label_idx
    ON scopes (account_id, diskann_label)
    WHERE diskann_label IS NOT NULL
    """

    execute "DROP INDEX CONCURRENTLY IF EXISTS knowledge_items_embedding_diskann_1024_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS document_chunks_embedding_diskann_1024_idx"

    execute """
    CREATE INDEX CONCURRENTLY knowledge_items_embedding_diskann_1024_idx
    ON knowledge_items
    USING diskann ((embedding::vector(1024)) vector_cosine_ops, diskann_labels)
    WITH (#{options})
    WHERE embedding IS NOT NULL AND embedding_dimensions = 1024
    """

    execute """
    CREATE INDEX CONCURRENTLY document_chunks_embedding_diskann_1024_idx
    ON document_chunks
    USING diskann ((embedding::vector(1024)) vector_cosine_ops, diskann_labels)
    WITH (#{options})
    WHERE embedding IS NOT NULL AND embedding_dimensions = 1024 AND status = 'active'
    """
  end

  def down do
    options = diskann_options!()

    execute "DROP INDEX CONCURRENTLY IF EXISTS document_chunks_embedding_diskann_1024_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS knowledge_items_embedding_diskann_1024_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS scopes_account_diskann_label_idx"

    execute """
    CREATE INDEX CONCURRENTLY knowledge_items_embedding_diskann_1024_idx
    ON knowledge_items
    USING diskann ((embedding::vector(1024)) vector_cosine_ops)
    WITH (#{options})
    WHERE embedding IS NOT NULL AND embedding_dimensions = 1024
    """

    execute """
    CREATE INDEX CONCURRENTLY document_chunks_embedding_diskann_1024_idx
    ON document_chunks
    USING diskann ((embedding::vector(1024)) vector_cosine_ops)
    WITH (#{options})
    WHERE embedding IS NOT NULL AND embedding_dimensions = 1024 AND status = 'active'
    """

    execute "ALTER TABLE document_chunks DROP COLUMN diskann_labels"
    execute "ALTER TABLE knowledge_items DROP COLUMN diskann_labels"
    execute "ALTER TABLE scopes DROP COLUMN diskann_label"
  end

  defp diskann_options! do
    config = Application.fetch_env!(:memhouse, :diskann)
    storage_layout = Keyword.fetch!(config, :storage_layout)
    num_neighbors = integer_in!(config, :num_neighbors, 10..1000)
    search_list_size = integer_in!(config, :search_list_size, 10..1000)
    num_dimensions = integer_in!(config, :num_dimensions, 0..1024)
    max_alpha = Keyword.fetch!(config, :max_alpha)

    unless storage_layout in ~w(memory_optimized plain) do
      raise "MEMHOUSE_DISKANN_STORAGE_LAYOUT must be memory_optimized or plain"
    end

    unless is_number(max_alpha) and max_alpha >= 1.0 and max_alpha <= 5.0 do
      raise "MEMHOUSE_DISKANN_MAX_ALPHA must be between 1.0 and 5.0"
    end

    "storage_layout = #{storage_layout}, num_neighbors = #{num_neighbors}, " <>
      "search_list_size = #{search_list_size}, max_alpha = #{max_alpha}, " <>
      "num_dimensions = #{num_dimensions}"
  end

  defp integer_in!(config, key, range) do
    value = Keyword.fetch!(config, key)

    if is_integer(value) and value in range do
      value
    else
      raise "#{key} must be between #{range.first} and #{range.last}"
    end
  end
end
