# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.Changes.ClampAskPreference do
  @moduledoc """
  Lets peers tighten, but never loosen, their interruption limits.

  The peer-callable `:restrict` action clamps counts between zero and their stored values and
  accepts only later pauses. Missing or invalid arguments leave fields unchanged. Administrators
  raise limits through `:configure`.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> clamp(:max_per_session, 0, changeset.data.max_per_session)
    |> clamp(:max_per_day, 0, changeset.data.max_per_day)
    |> clamp_pause()
  end

  # The stored value is the ceiling, enforcing tighten-only updates.
  defp clamp(changeset, name, floor, ceiling) do
    case Ash.Changeset.get_argument(changeset, name) do
      value when is_integer(value) ->
        Ash.Changeset.force_change_attribute(changeset, name, value |> max(floor) |> min(ceiling))

      _other ->
        changeset
    end
  end

  # Pauses may be created or extended, never shortened.
  defp clamp_pause(changeset) do
    case Ash.Changeset.get_argument(changeset, :paused_until) do
      %DateTime{} = paused_until ->
        current = changeset.data.paused_until

        if is_nil(current) || DateTime.compare(paused_until, current) == :gt do
          Ash.Changeset.force_change_attribute(changeset, :paused_until, paused_until)
        else
          changeset
        end

      _other ->
        changeset
    end
  end
end
