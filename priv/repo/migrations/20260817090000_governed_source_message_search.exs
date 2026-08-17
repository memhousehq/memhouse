# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.GovernedSourceMessageSearch do
  @moduledoc """
  Adds rebuildable lexical and semantic search fields to immutable source messages.

  All columns and the label backfill commit atomically. Concurrent indexes live
  in following one-index migrations so a failed build can be retried without
  replaying partially committed schema changes.
  """

  use Ecto.Migration

  def up do
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
  end

  def down do
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS search_vector"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS source_indexed_at"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS diskann_labels"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_dimensions"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_version"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_model"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_provider"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding"
  end
end
