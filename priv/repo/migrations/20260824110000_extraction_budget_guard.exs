# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.ExtractionBudgetGuard do
  use Ecto.Migration

  def up do
    create table(:extraction_budget_guards, primary_key: false) do
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false
      add :scope_root, :text, null: false
      add :request_cap, :bigint, null: false
      add :token_cap, :bigint, null: false
      add :usd_micros_cap, :bigint, null: false
      add :deadline_at, :utc_datetime_usec, null: false
      add :input_usd_micros_per_million, :bigint, null: false
      add :output_usd_micros_per_million, :bigint, null: false
      add :requests_reserved, :bigint, null: false, default: 0
      add :tokens_reserved, :bigint, null: false, default: 0
      add :usd_micros_reserved, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:extraction_budget_guards, [:account_id, :scope_root])
    execute "ALTER TABLE extraction_budget_guards ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE extraction_budget_guards FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY memhouse_account_wall ON extraction_budget_guards
    USING (account_id = NULLIF(current_setting('memhouse.account_id', true), '')::uuid)
    WITH CHECK (account_id = NULLIF(current_setting('memhouse.account_id', true), '')::uuid)
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS memhouse_account_wall ON extraction_budget_guards"
    drop table(:extraction_budget_guards)
  end
end
