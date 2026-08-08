# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.CreateMemoryPoc do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    Oban.Migration.up(version: 12)

    create table(:accounts, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :key, :text, null: false
      add :name, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:accounts, [:key])

    create table(:peers, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :name, :text, null: false
      add :kind, :text, null: false, default: "human"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:peers, [:account_id, :key])

    create table(:scopes, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false
      add :parent_id, references(:scopes, type: :uuid, on_delete: :nilify_all)
      add :key, :text, null: false
      add :name, :text, null: false
      add :path, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scopes, [:account_id, :path])

    create table(:sessions, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false
      add :scope_id, references(:scopes, type: :uuid, on_delete: :delete_all), null: false
      add :peer_id, references(:peers, type: :uuid, on_delete: :delete_all), null: false
      add :external_id, :text, null: false
      add :status, :text, null: false, default: "open"
      add :summary, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sessions, [:account_id, :external_id])

    create table(:messages, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false
      add :session_id, references(:sessions, type: :uuid, on_delete: :delete_all), null: false
      add :scope_id, references(:scopes, type: :uuid, on_delete: :delete_all), null: false
      add :peer_id, references(:peers, type: :uuid, on_delete: :delete_all), null: false
      add :role, :text, null: false
      add :content, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:messages, [:account_id, :session_id])

    create table(:knowledge_items, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false
      add :scope_id, references(:scopes, type: :uuid, on_delete: :delete_all), null: false
      add :subject_peer_id, references(:peers, type: :uuid, on_delete: :nilify_all)
      add :subject_scope_id, references(:scopes, type: :uuid, on_delete: :nilify_all)
      add :statement, :text, null: false
      add :kind, :text, null: false, default: "fact"
      add :confidence, :float, null: false, default: 0.5
      add :sensitivity, :text, null: false, default: "internal"
      add :state, :text, null: false, default: "proposed"
      add :expires_at, :utc_datetime_usec
      add :revalidate_after, :utc_datetime_usec
      add :relevant_from, :utc_datetime_usec
      add :relevant_until, :utc_datetime_usec
      add :source_message_ids, {:array, :uuid}, null: false, default: []
      add :extracting_model, :text
      add :pipeline_version, :text, null: false, default: "poc-0"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:knowledge_items, [:account_id, :scope_id, :state])

    execute """
    ALTER TABLE knowledge_items
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(statement, ''))) STORED
    """

    execute "CREATE INDEX knowledge_items_search_vector_idx ON knowledge_items USING GIN (search_vector)"

    create table(:knowledge_lifecycle_events, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false

      add :knowledge_item_id, references(:knowledge_items, type: :uuid, on_delete: :delete_all),
        null: false

      add :from_state, :text
      add :to_state, :text, null: false
      add :reason, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:knowledge_lifecycle_events, [:account_id, :knowledge_item_id])
  end

  def down do
    drop table(:knowledge_lifecycle_events)
    execute "DROP INDEX IF EXISTS knowledge_items_search_vector_idx"
    execute "ALTER TABLE knowledge_items DROP COLUMN IF EXISTS search_vector"
    drop table(:knowledge_items)
    drop table(:messages)
    drop table(:sessions)
    drop table(:scopes)
    drop table(:peers)
    drop table(:accounts)

    Oban.Migration.down(version: 12)
  end
end
