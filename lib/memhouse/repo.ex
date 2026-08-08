# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo do
  @moduledoc """
  The shared PostgreSQL repository for both deployment modes.

  Database location may change; schema and behavior may not. Durable writes belong in
  Ash actions so tenancy, policies, audit, and job effects remain attached. Direct Repo
  access is limited to reviewed infrastructure and read-only query helpers.
  """

  use AshPostgres.Repo,
    otp_app: :memhouse,
    adapter: Ecto.Adapters.Postgres,
    warn_on_missing_ash_functions?: false

  @doc """
  Returns the oldest PostgreSQL version supported by the schema.
  """
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end

  @doc """
  Returns the required PostgreSQL extensions in AshPostgres format.

  Changing this list is a schema change and requires regenerated migrations.
  """
  def installed_extensions, do: ["pgcrypto", "vector", "citext", "vectorscale"]
end
