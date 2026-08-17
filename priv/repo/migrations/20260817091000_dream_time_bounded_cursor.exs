# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Repo.Migrations.DreamTimeBoundedCursor do
  @moduledoc false
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
