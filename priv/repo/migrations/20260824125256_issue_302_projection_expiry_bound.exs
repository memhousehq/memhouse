defmodule MemHouse.Repo.Migrations.Issue302ProjectionExpiryBound do
  @moduledoc """
  Adds fail-closed expiry, content validity, and input generations to derived projections.

  Existing projections receive validity marker `0` and remain unreadable until a current worker
  rebuilds them. Projection-shaping writes advance the scope generation and dirty derived rows
  through their application-owned Ash actions. Rollback removes the projection validity columns
  and scope input generation.
  """

  use Ecto.Migration

  @doc """
  Adds projection validity columns and the scope input generation.

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
  end

  @doc """
  Removes projection validity data and the scope input generation.

  Returns the migration operation result and raises if PostgreSQL cannot apply the DDL.
  """
  def down do
    alter table(:projections) do
      remove :validity_version
      remove :valid_until
    end

    alter table(:scopes) do
      remove :projection_input_generation
    end
  end
end
