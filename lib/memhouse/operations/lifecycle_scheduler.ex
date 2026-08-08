# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Operations.LifecycleScheduler do
  @moduledoc """
  Starts durable lifecycle sweeps from the hourly Cron slot.

  Cron only starts this worker. The worker never changes knowledge directly:
  it enters the configured community Account and creates the ordinary
  dream-time, expiry, and revalidation pipeline runs in that Account
  transaction. The scheduled
  timestamp is the replay watermark, so a late or retried Cron job cannot
  create duplicate sweeps.
  """

  use Oban.Worker, queue: :lifecycle, max_attempts: 5

  alias MemHouse.DataLayer
  alias MemHouse.Pipeline

  @impl Oban.Worker
  @doc """
  Creates the current slot's lifecycle runs for the provisioned community Account.

  An unprovisioned installation has no Account to sweep. It is a normal
  pre-bootstrap state, so the Cron job completes without creating data.
  """
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    DataLayer.with_existing_free_account(fn account, actor ->
      {:ok, _runs} = Pipeline.enqueue_lifecycle_sweeps(account.id, actor, scheduled_at)
    end)

    :ok
  rescue
    Ecto.NoResultsError -> :ok
  end
end
