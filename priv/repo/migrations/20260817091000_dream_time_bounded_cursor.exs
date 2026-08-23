# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.DreamTimeBoundedCursor do
  @moduledoc """
  Adds the exact input-row cursor used to bound and replay a dream-time pass.

  The cursor complements the timestamp watermark so equal-timestamp inputs are
  resumed deterministically rather than skipped or processed twice.
  """
  use Ecto.Migration

  def up do
    alter table(:dream_time_watermarks) do
      add :input_watermark_id, :uuid
    end
  end

  def down do
    alter table(:dream_time_watermarks) do
      remove :input_watermark_id
    end
  end
end
