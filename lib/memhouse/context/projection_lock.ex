# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.ProjectionLock do
  @moduledoc """
  Serializes one scope's projection input snapshot, commit, and invalidation boundary.

  A short shared row lock makes the input generation and every projection-shaping read one coherent
  snapshot. After model work, an exclusive row lock serializes revalidation and commit. Database
  triggers bump the generation for every shaping source mutation, so either a refresh commits first
  and the later mutation invalidates it, or the mutation commits first and the refresh rejects its
  stale generation.
  """

  alias MemHouse.Repo

  @doc """
  Captures a scope's projection-input generation under a shared transaction lock.

  Call before reading projection-shaping inputs inside a transaction. Returns the non-negative
  generation and raises when the scope is absent or PostgreSQL cannot acquire the row lock. The
  shared lock is released with the transaction.
  """
  @spec capture!(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def capture!(account_id, scope_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT projection_input_generation
        FROM scopes
        WHERE account_id = $1 AND id = $2
        FOR SHARE
        """,
        dump_ids(account_id, scope_id)
      )

    generation!(result)
  end

  @doc """
  Acquires the exclusive Account/scope projection lock for the current transaction.

  Call only inside a transaction. Blocks until the scope row is available, returns its current
  non-negative projection-input generation, and raises when the scope is absent or PostgreSQL
  cannot acquire the row lock. The lock is released with the transaction.
  """
  @spec acquire!(Ecto.UUID.t(), Ecto.UUID.t()) :: non_neg_integer()
  def acquire!(account_id, scope_id) do
    result =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT projection_input_generation
        FROM scopes
        WHERE account_id = $1 AND id = $2
        FOR UPDATE
        """,
        dump_ids(account_id, scope_id)
      )

    generation!(result)
  end

  defp dump_ids(account_id, scope_id) do
    [Ecto.UUID.dump!(account_id), Ecto.UUID.dump!(scope_id)]
  end

  defp generation!(result) do
    case result do
      %{rows: [[generation]]} -> generation
      %{rows: []} -> raise Ecto.NoResultsError, queryable: MemHouse.Topology.Scope
    end
  end
end
