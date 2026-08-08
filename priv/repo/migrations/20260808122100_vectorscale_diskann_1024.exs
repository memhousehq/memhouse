# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.VectorscaleDiskann1024 do
  @moduledoc false

  use Ecto.Migration

  # DiskANN supports concurrent builds. Vector indexes are rebuildable caches,
  # so no transaction should hold the table lock for the duration of a rebuild.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    options = diskann_options!()

    execute "DROP INDEX CONCURRENTLY IF EXISTS knowledge_items_embedding_hnsw_384_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS document_chunks_embedding_hnsw_384_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS entities_alias_embedding_hnsw_384_idx"

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

    execute """
    CREATE INDEX CONCURRENTLY entities_alias_embedding_diskann_1024_idx
    ON entities
    USING diskann ((alias_embedding::vector(1024)) vector_cosine_ops)
    WITH (#{options})
    WHERE alias_embedding IS NOT NULL AND embedding_dimensions = 1024
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS entities_alias_embedding_diskann_1024_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS document_chunks_embedding_diskann_1024_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS knowledge_items_embedding_diskann_1024_idx"

    execute """
    CREATE INDEX CONCURRENTLY knowledge_items_embedding_hnsw_384_idx
    ON knowledge_items
    USING hnsw ((embedding::vector(384)) vector_cosine_ops)
    WHERE embedding IS NOT NULL AND embedding_dimensions = 384
    """

    execute """
    CREATE INDEX CONCURRENTLY document_chunks_embedding_hnsw_384_idx
    ON document_chunks
    USING hnsw ((embedding::vector(384)) vector_cosine_ops)
    WHERE embedding_dimensions = 384 AND status = 'active'
    """

    execute """
    CREATE INDEX CONCURRENTLY entities_alias_embedding_hnsw_384_idx
    ON entities
    USING hnsw ((alias_embedding::vector(384)) vector_cosine_ops)
    WHERE alias_embedding IS NOT NULL AND embedding_dimensions = 384
    """
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
