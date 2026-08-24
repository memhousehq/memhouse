defmodule MemHouse.Repo.Migrations.Issue302ProjectionExpiryBound do
  @moduledoc """
  Adds fail-closed expiry, content validity, and input generations to derived projections.

  The update trigger clears `validity_version` when a writer changes projection content or its
  visibility coordinates without advancing the validity marker. Rolling-upgrade writes therefore
  become unreadable until a current worker rebuilds them. Projection-input triggers advance the
  scope generation and dirty derived rows whenever a shaping source changes. Rollback removes the
  triggers, functions, projection validity columns, and scope input generation.
  """

  use Ecto.Migration

  @doc """
  Adds projection validity columns, the scope input generation, and invalidation triggers.

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

    execute """
    CREATE FUNCTION memhouse_invalidate_projection_input()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      source_account_id uuid;
      source_scope_id uuid;
    BEGIN
      IF TG_TABLE_NAME = 'scopes' THEN
        source_account_id := NEW.account_id;
        source_scope_id := NEW.id;
      ELSIF TG_OP = 'DELETE' THEN
        source_account_id := OLD.account_id;
        source_scope_id := OLD.scope_id;
      ELSE
        source_account_id := NEW.account_id;
        source_scope_id := NEW.scope_id;
      END IF;

      UPDATE scopes
      SET projection_input_generation = projection_input_generation + 1
      WHERE account_id = source_account_id AND id = source_scope_id;

      UPDATE projections
      SET dirty = true
      WHERE account_id = source_account_id AND scope_id = source_scope_id AND dirty = false;

      IF TG_TABLE_NAME <> 'scopes'
         AND TG_OP = 'UPDATE'
         AND (OLD.account_id, OLD.scope_id) IS DISTINCT FROM (NEW.account_id, NEW.scope_id) THEN
        UPDATE scopes
        SET projection_input_generation = projection_input_generation + 1
        WHERE account_id = OLD.account_id AND id = OLD.scope_id;

        UPDATE projections
        SET dirty = true
        WHERE account_id = OLD.account_id AND scope_id = OLD.scope_id AND dirty = false;
      END IF;

      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      ELSE
        RETURN NEW;
      END IF;
    END;
    $$
    """

    execute """
    CREATE TRIGGER scopes_invalidate_projection_input
    AFTER UPDATE OF name, state ON scopes
    FOR EACH ROW
    EXECUTE FUNCTION memhouse_invalidate_projection_input()
    """

    execute """
    CREATE TRIGGER knowledge_items_invalidate_projection_input
    AFTER INSERT OR UPDATE OR DELETE ON knowledge_items
    FOR EACH ROW
    EXECUTE FUNCTION memhouse_invalidate_projection_input()
    """

    execute """
    CREATE TRIGGER entity_mentions_invalidate_projection_input
    AFTER INSERT OR UPDATE OR DELETE ON entity_mentions
    FOR EACH ROW
    EXECUTE FUNCTION memhouse_invalidate_projection_input()
    """

    execute """
    CREATE TRIGGER sessions_invalidate_projection_input
    AFTER INSERT OR UPDATE OR DELETE ON sessions
    FOR EACH ROW
    EXECUTE FUNCTION memhouse_invalidate_projection_input()
    """

    execute """
    CREATE TRIGGER messages_insert_delete_invalidate_projection_input
    AFTER INSERT OR DELETE ON messages
    FOR EACH ROW
    EXECUTE FUNCTION memhouse_invalidate_projection_input()
    """

    execute """
    CREATE TRIGGER messages_association_invalidate_projection_input
    AFTER UPDATE OF session_id, scope_id ON messages
    FOR EACH ROW
    EXECUTE FUNCTION memhouse_invalidate_projection_input()
    """
  end

  @doc """
  Removes projection-input triggers, the stale-write trigger, their functions, and validity data.

  Returns the migration operation result and raises if PostgreSQL cannot apply the DDL.
  """
  def down do
    execute "DROP TRIGGER IF EXISTS messages_association_invalidate_projection_input ON messages"

    execute "DROP TRIGGER IF EXISTS messages_insert_delete_invalidate_projection_input ON messages"

    execute "DROP TRIGGER IF EXISTS sessions_invalidate_projection_input ON sessions"

    execute "DROP TRIGGER IF EXISTS entity_mentions_invalidate_projection_input ON entity_mentions"

    execute "DROP TRIGGER IF EXISTS knowledge_items_invalidate_projection_input ON knowledge_items"

    execute "DROP TRIGGER IF EXISTS scopes_invalidate_projection_input ON scopes"
    execute "DROP FUNCTION IF EXISTS memhouse_invalidate_projection_input()"
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
