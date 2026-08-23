# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.TestSupport.AccountCleanup do
  @moduledoc """
  Releases jobs created by tests that deliberately run outside SQL Sandbox transactions.

  Accounts use unique keys and deliberately remain as isolated test evidence. Oban owns job
  cancellation, so this helper does not introduce a raw destructive SQL exception.
  """

  import Ecto.Query, only: [from: 2]

  @doc "Cancels content-free Oban jobs for an unsandboxed test Account."
  def delete!(account_id) when is_binary(account_id) do
    Oban.cancel_all_jobs(
      from job in Oban.Job,
        where: fragment("? ->> 'tenant'", job.args) == ^account_id
    )

    :ok
  end
end
