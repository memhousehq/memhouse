# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.FinalizeMemHouseSchemaNames do
  @moduledoc false

  use Ecto.Migration

  def up do
    # API-key lookup is a documented read-only Repo exception. Rename the
    # function in place so its owner, grants, and SECURITY DEFINER settings stay
    # unchanged.
    execute """
    ALTER FUNCTION cartulary_resolve_api_key_account(uuid)
    RENAME TO memhouse_resolve_api_key_account
    """

    rename_account_wall_policies("cartulary_account_wall", "memhouse_account_wall")
  end

  def down do
    rename_account_wall_policies("memhouse_account_wall", "cartulary_account_wall")

    execute """
    ALTER FUNCTION memhouse_resolve_api_key_account(uuid)
    RENAME TO cartulary_resolve_api_key_account
    """
  end

  defp rename_account_wall_policies(from, to) do
    # Policies span the durable Account-owned tables. Discovering the reviewed
    # policy name avoids a second hard-coded table inventory that can drift from
    # the schema while still changing no policy expression or role binding.
    execute """
    DO $migration$
    DECLARE
      policy_row record;
    BEGIN
      FOR policy_row IN
        SELECT schemaname, tablename
        FROM pg_policies
        WHERE policyname = '#{from}'
      LOOP
        EXECUTE format(
          'ALTER POLICY %I ON %I.%I RENAME TO %I',
          '#{from}',
          policy_row.schemaname,
          policy_row.tablename,
          '#{to}'
        );
      END LOOP;
    END
    $migration$;
    """
  end
end
