defmodule MemHouse.Repo.Migrations.Issue302ProjectionExpiryBound do
  @moduledoc """
  Adds fail-closed expiry, content validity, and input generations to derived projections.

  The update trigger clears `validity_version` when a writer changes projection content or its
  visibility coordinates without advancing the validity marker. Rolling-upgrade writes therefore
  become unreadable until a current worker rebuilds them. Projection-shaping Ash actions advance
  the scope generation and dirty derived rows. Rollback removes the compatibility trigger,
  function, projection validity columns, and scope input generation.
  """

  use Ecto.Migration

  @doc """
  Adds projection validity columns, the scope input generation, and the rolling-upgrade
  stale-write trigger.

  Returns the migration operation result and raises if PostgreSQL cannot apply the DDL.
  """
  def up do
    alter table(:scopes) do
      add :projection_input_generation, :bigint, null: false, default: 0
    end

    alter table(:projections) do
      add :valid_until, :utc_datetime_usec
      add :validity_version, :bigint, null: false, default: 0
    end

    execute """
    CREATE FUNCTION memhouse_invalidate_stale_projection_write()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.validity_version IS NOT DISTINCT FROM OLD.validity_version
         AND (NEW.version IS DISTINCT FROM OLD.version
              OR NEW.content IS DISTINCT FROM OLD.content
              OR NEW.source_ids IS DISTINCT FROM OLD.source_ids
              OR NEW.sensitivity IS DISTINCT FROM OLD.sensitivity
              OR NEW.valid_until IS DISTINCT FROM OLD.valid_until
              OR NEW.dirty IS DISTINCT FROM OLD.dirty) THEN
        NEW.validity_version := 0;
      END IF;

      RETURN NEW;
    END;
    $$
    """

    execute """
    CREATE TRIGGER projections_invalidate_stale_write
    BEFORE UPDATE ON projections
    FOR EACH ROW
    EXECUTE FUNCTION memhouse_invalidate_stale_projection_write()
    """
  end

  @doc """
  Removes the stale-write compatibility trigger, its function, and projection validity data.

  Returns the migration operation result and raises if PostgreSQL cannot apply the DDL.
  """
  def down do
    execute "DROP TRIGGER IF EXISTS projections_invalidate_stale_write ON projections"
    execute "DROP FUNCTION IF EXISTS memhouse_invalidate_stale_projection_write()"

    alter table(:projections) do
      remove :validity_version
      remove :valid_until
    end

    alter table(:scopes) do
      remove :projection_input_generation
    end
  end
end
