# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.Issue178ExtractionClaimFence do
  @moduledoc """
  Adds the optional batch claim token to each durable extraction run.

  Workers compare this token before persisting an anchor, so an expired or
  operator-requeued claim cannot commit results after ownership changes.
  """

  use Ecto.Migration

  def up do
    alter table(:pipeline_runs) do
      add :batch_claim_id, :uuid
    end
  end

  def down do
    alter table(:pipeline_runs) do
      remove :batch_claim_id
    end
  end
end
