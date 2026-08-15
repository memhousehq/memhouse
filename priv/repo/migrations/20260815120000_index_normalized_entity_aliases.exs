# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.IndexNormalizedEntityAliases do
  @moduledoc "Adds the normalized entity-name index used by retrieval."

  use Ecto.Migration

  @doc "Creates an immutable normalizer and its rebuildable GIN expression index."
  def up do
    # Entity aliases are a rebuildable private cache. Normalize them in one immutable function so
    # the query expression exactly matches the indexed expression without a per-row unnest scan.
    execute """
    CREATE FUNCTION memhouse_normalized_entity_aliases(text[], text)
    RETURNS text[]
    LANGUAGE sql
    IMMUTABLE
    PARALLEL SAFE
    STRICT
    AS $$
      SELECT COALESCE(
        array_agg(DISTINCT lower(value) ORDER BY lower(value)),
        ARRAY[]::text[]
      )
      FROM unnest($1 || ARRAY[$2]) AS value
      WHERE value <> ''
    $$
    """

    execute """
    CREATE INDEX entities_normalized_aliases_gin_idx
    ON entities
    USING gin (memhouse_normalized_entity_aliases(aliases, canonical_name))
    """
  end

  @doc "Drops the normalized entity-name index and its helper function."
  def down do
    execute "DROP INDEX IF EXISTS entities_normalized_aliases_gin_idx"
    execute "DROP FUNCTION IF EXISTS memhouse_normalized_entity_aliases(text[], text)"
  end
end
