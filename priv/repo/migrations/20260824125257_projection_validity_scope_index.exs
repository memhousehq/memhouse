# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.ProjectionValidityScopeIndex do
  @moduledoc """
  Builds the partial Account/scope index used to reconcile legacy projections.

  A retry drops an unrecorded prior build before recreating the one index owned
  by this migration.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @doc "Creates the legacy-projection scope index concurrently."
  def up do
    execute "DROP INDEX CONCURRENTLY IF EXISTS projections_legacy_validity_scope_idx"

    execute """
    CREATE INDEX CONCURRENTLY projections_legacy_validity_scope_idx
    ON projections (account_id, scope_id, updated_at DESC, id DESC)
    WHERE validity_version <> version AND dirty = false
    """
  end

  @doc "Removes the legacy-projection scope index concurrently."
  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS projections_legacy_validity_scope_idx"
  end
end
