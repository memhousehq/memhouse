# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Database.AppRoleTest do
  @moduledoc """
  Pins the database half of cross-Account isolation: the node's connections must run as a role
  that PostgreSQL row-level security actually applies to.

  `MemHouse.Database.RoleProvisioner` and `MemHouse.Database.RoleGuard` already ran as part
  of this node's own boot before this suite started, over the same test database these tests
  run against. So the interesting assertion here is not "can provisioning be made to work in
  isolation" — it is "did it actually happen, on the very connection every other test in this
  suite depends on". A regression that reintroduces a superuser connection would make every
  test in this file fail, not just the row-level-security ones in `F1AshDomainBackboneTest`.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.Database.AppRole
  alias MemHouse.Repo

  test "the running node's own connection cannot bypass row-level security" do
    assert :ok = AppRole.assert_enforced!()
  end

  test "the configured role name is provisioned as NOSUPERUSER NOBYPASSRLS" do
    role = AppRole.role_name!()

    assert %{rows: [[^role, false, false]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = $1",
               [role]
             )
  end

  test "the role is granted data-manipulation rights but no elevated attribute" do
    role = AppRole.role_name!()

    assert %{rows: [[^role, false, false, false, false]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT rolname, rolcreatedb, rolcreaterole, rolcanlogin, rolbypassrls
               FROM pg_roles
               WHERE rolname = $1
               """,
               [role]
             )

    assert %{rows: rows} =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT DISTINCT privilege_type
               FROM information_schema.role_table_grants
               WHERE grantee = $1 AND table_name = 'accounts'
               ORDER BY privilege_type
               """,
               [role]
             )

    assert Enum.map(rows, &hd/1) == ~w(DELETE INSERT SELECT UPDATE)
  end

  test "provisioning is idempotent" do
    assert :ok = AppRole.with_privileged_repo(&AppRole.provision!/1)
    assert :ok = AppRole.with_privileged_repo(&AppRole.provision!/1)
  end

  test "role_name! rejects a name that is not a plain lowercase identifier" do
    original = Application.fetch_env!(:memhouse, :database)

    Application.put_env(
      :memhouse,
      :database,
      Keyword.put(original, :app_role, "not-a-valid-identifier; DROP TABLE accounts")
    )

    assert_raise RuntimeError, ~r/lowercase SQL identifier/, fn -> AppRole.role_name!() end
  after
    original = Application.fetch_env!(:memhouse, :database)
    Application.put_env(:memhouse, :database, Keyword.put(original, :app_role, "memhouse_app"))
  end
end
