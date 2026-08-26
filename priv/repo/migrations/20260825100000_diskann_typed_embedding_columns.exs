# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.DiskannTypedEmbeddingColumns do
  @moduledoc false

  use Ecto.Migration

  def up do
    add_generated_column("knowledge_items")
    add_generated_column("document_chunks")
    add_generated_column("messages")
    add_generated_column("recall_documents")
  end

  def down do
    execute "ALTER TABLE recall_documents DROP COLUMN IF EXISTS embedding_1024"
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS embedding_1024"
    execute "ALTER TABLE document_chunks DROP COLUMN IF EXISTS embedding_1024"
    execute "ALTER TABLE knowledge_items DROP COLUMN IF EXISTS embedding_1024"
  end

  defp add_generated_column(table) do
    execute """
    ALTER TABLE #{table}
    ADD COLUMN IF NOT EXISTS embedding_1024 vector(1024)
    GENERATED ALWAYS AS (
      CASE WHEN embedding_dimensions = 1024 THEN embedding::vector(1024) END
    ) STORED
    """
  end
end
