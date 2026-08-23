# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.RecallDocumentDualLane do
  @moduledoc """
  Creates the Account-isolated, rebuildable recall projection for independently
  bounded direct and derived knowledge lanes.

  Existing eligible knowledge is backfilled before forced RLS is installed, and
  the table, backfill, and Account wall commit atomically. Concurrent query
  indexes live in following one-index migrations so failed builds are retry-safe.
  """

  use Ecto.Migration

  @doc "Creates and backfills the Account-isolated dual-lane recall projection."
  def up do
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
  end

  @doc "Removes the dual-lane recall projection and its Account isolation policy."
  def down do
    execute "DROP TABLE IF EXISTS recall_documents"
  end
end
