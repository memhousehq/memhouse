# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.MigrationRetrySafetyTest do
  @moduledoc """
  Pins transactional schema/RLS work apart from retry-safe concurrent index builds.
  """

  use ExUnit.Case, async: true

  @migration_dir Path.expand("../../priv/repo/migrations", __DIR__)

  @transactional_migrations ~w(
    20260817090000_governed_source_message_search.exs
    20260817100000_recall_document_dual_lane.exs
    20260824125256_issue_302_projection_expiry_bound.exs
  )

  @concurrent_index_migrations ~w(
    20260817090001_source_message_search_vector_index.exs
    20260817090002_source_message_embedding_diskann_index.exs
    20260817090003_source_message_scope_time_index.exs
    20260817100001_recall_document_scope_lane_index.exs
    20260817100002_recall_document_embedding_diskann_index.exs
    20260824125257_projection_validity_scope_index.exs
  )

  test "schema, backfill, and forced RLS migrations remain transactional" do
    Enum.each(@transactional_migrations, fn migration ->
      source = read_migration(migration)
      refute source =~ "@disable_ddl_transaction true"
      refute source =~ "CREATE INDEX CONCURRENTLY"
    end)

    recall = read_migration("20260817100000_recall_document_dual_lane.exs")
    assert recall =~ "ALTER TABLE recall_documents ENABLE ROW LEVEL SECURITY"
    assert recall =~ "ALTER TABLE recall_documents FORCE ROW LEVEL SECURITY"
    assert recall =~ "CREATE POLICY memhouse_account_wall"

    projection = read_migration("20260824125256_issue_302_projection_expiry_bound.exs")
    assert projection =~ "BEFORE UPDATE ON projections"
    assert projection =~ "NEW.validity_version IS NOT DISTINCT FROM OLD.validity_version"
    assert projection =~ "NEW.valid_until IS DISTINCT FROM OLD.valid_until"
    assert projection =~ "NEW.dirty IS DISTINCT FROM OLD.dirty"
    assert projection =~ "NEW.validity_version := 0"
  end

  test "each non-transactional migration owns one retry-safe concurrent index" do
    Enum.each(@concurrent_index_migrations, fn migration ->
      source = read_migration(migration)
      assert source =~ "@disable_ddl_transaction true"
      assert source =~ "@disable_migration_lock true"
      assert count(source, "CREATE INDEX CONCURRENTLY") == 1
      assert count(source, "DROP INDEX CONCURRENTLY IF EXISTS") == 2

      assert index_of(source, "DROP INDEX CONCURRENTLY IF EXISTS") <
               index_of(source, "CREATE INDEX CONCURRENTLY")
    end)
  end

  defp read_migration(name), do: File.read!(Path.join(@migration_dir, name))

  defp count(source, needle), do: length(String.split(source, needle)) - 1

  defp index_of(source, needle) do
    {index, _length} = :binary.match(source, needle)
    index
  end
end
