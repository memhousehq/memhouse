# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.RecallDocumentDualLane do
  @moduledoc false

  use Ecto.Migration

  # This is an empty, rebuildable table at deploy time. Its DiskANN index is
  # still concurrent so a replay or retry cannot block ordinary ingestion.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    options = diskann_options!()

    execute """
    CREATE TABLE recall_documents (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      knowledge_item_id uuid NOT NULL REFERENCES knowledge_items(id) ON DELETE CASCADE,
      scope_id uuid NOT NULL REFERENCES scopes(id) ON DELETE CASCADE,
      subject_peer_id uuid REFERENCES peers(id) ON DELETE SET NULL,
      subject_scope_id uuid REFERENCES scopes(id) ON DELETE SET NULL,
      statement text NOT NULL,
      derivation_lane text NOT NULL,
      operation text NOT NULL,
      provenance_ids uuid[] NOT NULL DEFAULT '{}',
      embedding vector,
      embedding_provider text,
      embedding_model text,
      embedding_version text,
      embedding_dimensions bigint,
      diskann_labels smallint[] NOT NULL DEFAULT '{}',
      source_updated_at timestamp(6) without time zone NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL DEFAULT now(),
      updated_at timestamp(6) without time zone NOT NULL DEFAULT now(),
      CONSTRAINT recall_documents_lane_check
        CHECK (derivation_lane IN ('direct', 'derived')),
      CONSTRAINT recall_documents_operation_check
        CHECK (operation IN ('extraction', 'consolidation', 'deduction'))
    )
    """

    execute """
    CREATE UNIQUE INDEX recall_documents_knowledge_item_index
    ON recall_documents (account_id, knowledge_item_id)
    """

    execute """
    INSERT INTO recall_documents (
      account_id, knowledge_item_id, scope_id, subject_peer_id,
      subject_scope_id, statement, derivation_lane, operation,
      provenance_ids, embedding, embedding_provider, embedding_model,
      embedding_version, embedding_dimensions, diskann_labels,
      source_updated_at
    )
    SELECT k.account_id,
           k.id,
           k.scope_id,
           k.subject_peer_id,
           k.subject_scope_id,
           k.statement,
           CASE
             WHEN k.deduction_key IS NOT NULL
               OR k.extracting_model = 'system:dream-time-consolidator'
               THEN 'derived'
             ELSE 'direct'
           END,
           CASE
             WHEN k.deduction_key IS NOT NULL THEN 'deduction'
             WHEN k.extracting_model = 'system:dream-time-consolidator'
               THEN 'consolidation'
             ELSE 'extraction'
           END,
           coalesce(array_agg(p.id ORDER BY p.id)
             FILTER (WHERE p.id IS NOT NULL), ARRAY[]::uuid[]),
           k.embedding,
           k.embedding_provider,
           k.embedding_model,
           k.embedding_version,
           k.embedding_dimensions,
           k.diskann_labels,
           k.updated_at
    FROM knowledge_items AS k
    LEFT JOIN provenances AS p
      ON p.account_id = k.account_id AND p.knowledge_item_id = k.id
    WHERE k.state IN ('active', 'provisional')
      AND k.deleted_at IS NULL
      AND (k.expires_at IS NULL OR k.expires_at > now())
      AND k.embedding IS NOT NULL
    GROUP BY k.id
    """

    # Backfill runs before FORCE RLS because an external-PostgreSQL migration
    # owner may be non-superuser and has no single Account setting that can
    # represent this cross-Account rebuild. The new table has no public grants;
    # install the wall before creating its query indexes and exposing it to the
    # application at migration completion.
    execute "ALTER TABLE recall_documents ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE recall_documents FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY memhouse_account_wall ON recall_documents
      USING (
        account_id = NULLIF(current_setting('memhouse.account_id', true), '')::uuid
      )
      WITH CHECK (
        account_id = NULLIF(current_setting('memhouse.account_id', true), '')::uuid
      )
    """

    execute """
    CREATE INDEX CONCURRENTLY recall_documents_scope_lane_idx
    ON recall_documents (account_id, scope_id, derivation_lane, source_updated_at, knowledge_item_id)
    """

    execute """
    CREATE INDEX CONCURRENTLY recall_documents_embedding_diskann_1024_idx
    ON recall_documents
    USING diskann ((embedding::vector(1024)) vector_cosine_ops, diskann_labels)
    WITH (#{options})
    WHERE embedding IS NOT NULL AND embedding_dimensions = 1024
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS recall_documents_embedding_diskann_1024_idx"
    execute "DROP INDEX CONCURRENTLY IF EXISTS recall_documents_scope_lane_idx"
    execute "DROP TABLE IF EXISTS recall_documents"
  end

  defp diskann_options! do
    config = Application.fetch_env!(:memhouse, :diskann)
    storage_layout = Keyword.fetch!(config, :storage_layout)
    num_neighbors = integer_in!(config, :num_neighbors, 10..1000)
    search_list_size = integer_in!(config, :search_list_size, 10..1000)
    num_dimensions = integer_in!(config, :num_dimensions, 0..1024)
    max_alpha = Keyword.fetch!(config, :max_alpha)

    unless storage_layout in ~w(memory_optimized plain) do
      raise "MEMHOUSE_DISKANN_STORAGE_LAYOUT must be memory_optimized or plain"
    end

    unless is_number(max_alpha) and max_alpha >= 1.0 and max_alpha <= 5.0 do
      raise "MEMHOUSE_DISKANN_MAX_ALPHA must be between 1.0 and 5.0"
    end

    "storage_layout = #{storage_layout}, num_neighbors = #{num_neighbors}, " <>
      "search_list_size = #{search_list_size}, max_alpha = #{max_alpha}, " <>
      "num_dimensions = #{num_dimensions}"
  end

  defp integer_in!(config, key, range) do
    value = Keyword.fetch!(config, key)

    if is_integer(value) and value in range do
      value
    else
      raise "#{key} must be between #{range.first} and #{range.last}"
    end
  end
end
