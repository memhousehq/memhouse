# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.RemoveInventedTemporalValues do
  use Ecto.Migration

  def up do
    # Extraction had no expiry policy. Every expiry from an extraction prompt is therefore
    # unsupported, including rows that governance later promoted.
    execute """
    UPDATE knowledge_items
    SET expires_at = NULL
    WHERE expires_at IS NOT NULL
      AND prompt_version LIKE 'extract-%'
    """

    # Equal boundaries were model-generated one-instant windows. They do not prove that a claim
    # became false, so retain neither boundary.
    execute """
    UPDATE knowledge_items
    SET relevant_from = NULL, relevant_until = NULL
    WHERE relevant_from IS NOT NULL
      AND relevant_from = relevant_until
      AND prompt_version LIKE 'extract-%'
    """

    # Earlier pipeline writes copied message belief time into an otherwise empty event window.
    # Limit cleanup to extracted rows with no end and an exact source-message timestamp match.
    execute """
    UPDATE knowledge_items AS knowledge
    SET relevant_from = NULL
    WHERE knowledge.relevant_from IS NOT NULL
      AND knowledge.relevant_until IS NULL
      AND knowledge.prompt_version LIKE 'extract-%'
      AND EXISTS (
        SELECT 1
        FROM messages AS message
        WHERE message.account_id = knowledge.account_id
          AND message.id = ANY(knowledge.source_message_ids)
          AND message.occurred_at = knowledge.relevant_from
      )
    """
  end

  def down do
    # The removed values have no trustworthy source and cannot be reconstructed.
    :ok
  end
end
