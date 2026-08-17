# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.GovernedSourceMessageSearch do
  @moduledoc """
  Adds rebuildable lexical and semantic search fields and indexes to immutable
  source messages.

  Vector and lexical indexes are created concurrently so deploying the derived
  retrieval cache does not block ordinary message ingestion.
  """

  use Ecto.Migration

  # The vector cache can be rebuilt, so index creation must not lock source
  # ingestion for the duration of a production build.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    options = diskann_options!()

    execute "ALTER TABLE messages ADD COLUMN embedding vector"
    execute "ALTER TABLE messages ADD COLUMN embedding_provider text"
    execute "ALTER TABLE messages ADD COLUMN embedding_model text"
    execute "ALTER TABLE messages ADD COLUMN embedding_version text"
    execute "ALTER TABLE messages ADD COLUMN embedding_dimensions bigint"
    execute "ALTER TABLE messages ADD COLUMN diskann_labels smallint[] NOT NULL DEFAULT '{}'"
    execute "ALTER TABLE messages ADD COLUMN source_indexed_at timestamp(6) without time zone"

    execute """
    ALTER TABLE messages
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', coalesce(content, ''))) STORED
    """

    execute """
    UPDATE messages AS message
    SET diskann_labels = ARRAY[scope.diskann_label]
    FROM scopes AS scope
    WHERE scope.id = message.scope_id
      AND scope.account_id = message.account_id
      AND scope.diskann_label IS NOT NULL
    """

    execute """
    CREATE INDEX CONCURRENTLY messages_source_search_vector_idx
    ON messages USING GIN (search_vector)
    """

    execute """
    CREATE INDEX CONCURRENTLY messages_source_embedding_diskann_1024_idx
    ON messages
    USING diskann ((embedding::vector(1024)) vector_cosine_ops, diskann_labels)
    WITH (#{options})
    WHERE embedding IS NOT NULL AND embedding_dimensions = 1024
    """

    execute """
    CREATE INDEX CONCURRENTLY messages_source_scope_time_idx
    ON messages (account_id, scope_id, occurred_at DESC, id)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_scope_time_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_embedding_diskann_1024_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_search_vector_idx"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS search_vector"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS source_indexed_at"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS diskann_labels"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_dimensions"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_version"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_model"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_provider"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding"
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
