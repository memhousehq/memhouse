# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.TestSupport.AccountCleanup do
  @moduledoc """
  Cleans up Accounts created by tests that deliberately run outside SQL Sandbox transactions.

  This narrow test-only seam owns the two bound writes needed when a provider-boundary test
  must observe `Repo.in_transaction?/0 == false`. Production code must use Ash actions instead.
  """

  alias MemHouse.Repo

  @doc "Deletes an unsandboxed test Account and its content-free Oban jobs."
  def delete!(account_id) when is_binary(account_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM oban_jobs WHERE args ->> 'tenant' = $1",
      [account_id]
    )

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM accounts WHERE id = $1", [
      Ecto.UUID.dump!(account_id)
    ])

    :ok
  end
end
