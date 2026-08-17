# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.SourceMessageScopeTimeIndex do
  @moduledoc """
  Builds the Account/scope/time source-message index without blocking ingestion.

  A retry drops an unrecorded prior build before recreating the one index owned
  by this migration.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_scope_time_idx"

    execute """
    CREATE INDEX CONCURRENTLY messages_source_scope_time_idx
    ON messages (account_id, scope_id, occurred_at DESC, id)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS messages_source_scope_time_idx"
  end
end
