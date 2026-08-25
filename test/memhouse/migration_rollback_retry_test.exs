# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.MigrationRollbackRetryTest do
  @moduledoc "Verifies durable retry state for non-transactional rollback migrations."

  use ExUnit.Case, async: false

  @migration_dir Path.expand("../../priv/repo/migrations", __DIR__)
  @boundary_migration Path.join(
                        @migration_dir,
                        "20260814070000_remove_invented_temporal_values.exs"
                      )
  @migration Path.join(
               @migration_dir,
               "20260814120000_drop_unused_entity_alias_embedding_index.exs"
             )
  @boundary_version 20_260_814_070_000
  @version 20_260_814_120_000

  test "entity alias index rollback can retry after the index was recreated" do
    MemHouse.Database.AppRole.with_privileged_repo(fn privileged ->
      try do
        migrations = load_migrations!()

        assert [@version, @boundary_version] = rollback_to_boundary(migrations, privileged)

        query!(privileged, """
        INSERT INTO schema_migrations (version, inserted_at)
        VALUES (#{@boundary_version}, now()), (#{@version}, now())
        """)

        assert [@version, @boundary_version] = rollback_to_boundary(migrations, privileged)

        migrated_versions =
          Ecto.Migrator.migrated_versions(MemHouse.Repo, dynamic_repo: privileged)

        refute @version in migrated_versions
        refute @boundary_version in migrated_versions

        assert [[true, true]] =
                 query!(privileged, """
                 SELECT indisvalid, indisready
                 FROM pg_index
                 WHERE indexrelid = 'entities_alias_embedding_diskann_1024_idx'::regclass
                 """).rows

        assert [[definition]] =
                 query!(privileged, """
                 SELECT pg_get_indexdef('entities_alias_embedding_diskann_1024_idx'::regclass)
                 """).rows

        assert definition =~ "USING diskann"
        assert definition =~ "vector(1024)"
        assert definition =~ "storage_layout=memory_optimized"
        assert definition =~ "num_neighbors='50'"
        assert definition =~ "search_list_size='100'"
        assert definition =~ "max_alpha='1.2'"
        assert definition =~ "num_dimensions='0'"
        assert definition =~ "alias_embedding IS NOT NULL"
        assert definition =~ "embedding_dimensions = 1024"
      after
        query!(
          privileged,
          "DROP INDEX CONCURRENTLY IF EXISTS entities_alias_embedding_diskann_1024_idx"
        )

        query!(privileged, """
        INSERT INTO schema_migrations (version, inserted_at)
        VALUES (#{@boundary_version}, now()), (#{@version}, now())
        ON CONFLICT (version) DO NOTHING
        """)
      end
    end)
  end

  defp rollback_to_boundary(migrations, repo) do
    Ecto.Migrator.run(MemHouse.Repo, migrations, :down,
      to: @boundary_version,
      dynamic_repo: repo,
      log: false
    )
  end

  defp load_migrations! do
    Code.require_file(@boundary_migration)
    Code.require_file(@migration)

    [
      {@boundary_version, MemHouse.Repo.Migrations.RemoveInventedTemporalValues},
      {@version, MemHouse.Repo.Migrations.DropUnusedEntityAliasEmbeddingIndex}
    ]
  end

  defp query!(repo, sql), do: Ecto.Adapters.SQL.query!(repo, sql, [])
end
