# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.DropUnusedEntityAliasEmbeddingIndex do
  @moduledoc "Removes the entity alias vector index that has no SQL reader."

  use Ecto.Migration

  # Entity candidate comparison runs in memory. The database index has no SQL
  # reader, so avoid its write and storage cost without removing the vectors.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @doc "Drops the unused entity alias DiskANN index without blocking writes."
  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS entities_alias_embedding_diskann_1024_idx"
  end

  @doc "Restores the entity alias DiskANN index from the current index settings."
  def down do
    # Concurrent creation can commit before Ecto removes the migration marker.
    # Replace either a complete or partial build when rollback retries.
    execute "DROP INDEX CONCURRENTLY IF EXISTS entities_alias_embedding_diskann_1024_idx"

    execute """
    CREATE INDEX CONCURRENTLY entities_alias_embedding_diskann_1024_idx
    ON entities
    USING diskann ((alias_embedding::vector(1024)) vector_cosine_ops)
    WITH (#{diskann_options!()})
    WHERE alias_embedding IS NOT NULL AND embedding_dimensions = 1024
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
