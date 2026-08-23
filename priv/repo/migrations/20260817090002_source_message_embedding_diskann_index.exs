# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.SourceMessageEmbeddingDiskannIndex do
  @moduledoc """
  Builds the 1024-dimensional source-message DiskANN index concurrently.

  A retry removes an unrecorded valid or invalid build before recreating it;
  no other schema work shares this non-transactional migration.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @doc "Creates the 1024-dimensional source-message DiskANN index concurrently."
  def up do
    options = diskann_options!()
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_embedding_diskann_1024_idx"

    execute """
    CREATE INDEX CONCURRENTLY messages_source_embedding_diskann_1024_idx
    ON messages
    USING diskann ((embedding::vector(1024)) vector_cosine_ops, diskann_labels)
    WITH (#{options})
    WHERE embedding IS NOT NULL AND embedding_dimensions = 1024
    """
  end

  @doc "Removes the source-message DiskANN index concurrently."
  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_embedding_diskann_1024_idx"
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
