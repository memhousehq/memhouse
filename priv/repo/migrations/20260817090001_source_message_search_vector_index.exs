# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.SourceMessageSearchVectorIndex do
  @moduledoc """
  Builds the source-message full-text index without blocking message ingestion.

  A retry first removes either a valid or failed concurrent build with the same
  name, so an unrecorded partial attempt can safely run again.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_search_vector_idx"

    execute """
    CREATE INDEX CONCURRENTLY messages_source_search_vector_idx
    ON messages USING GIN (search_vector)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_search_vector_idx"
  end
end
