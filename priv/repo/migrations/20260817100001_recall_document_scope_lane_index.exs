# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.RecallDocumentScopeLaneIndex do
  @moduledoc """
  Builds the recall projection's Account/scope/lane cursor index concurrently.

  A retry removes an unrecorded prior build before recreating this one index;
  the table and its forced-RLS wall are already committed transactionally.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS recall_documents_scope_lane_idx"

    execute """
    CREATE INDEX CONCURRENTLY recall_documents_scope_lane_idx
    ON recall_documents (account_id, scope_id, derivation_lane, source_updated_at, knowledge_item_id)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS recall_documents_scope_lane_idx"
  end
end
