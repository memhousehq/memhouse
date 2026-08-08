# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Portability.Changes.RestoreAttributes do
  @moduledoc """
  Restores archived attributes through the private import action.

  It force-writes known values, including ids and timestamps, only for an internal pipeline or
  system actor. This bypass is for verified fresh-target restore, never ordinary mutation.
  """

  use Ash.Resource.Change

  @doc """
  Forces the `:attributes` argument's values onto the changeset.

  `:attributes` is a map of archived attribute names (strings) to values.
  Unknown names are ignored. Returns the changeset with every recognised
  attribute force-changed, bypassing the action's accept list and any default
  that would otherwise generate a new value.
  """
  @impl true
  def change(changeset, _opts, _context) do
    # Archive keys are strings, so the resource's attribute names are indexed by
    # their string form. Looking names up this way — rather than converting
    # archive keys to atoms — means an archive can never create atoms from
    # untrusted input.
    attributes =
      changeset.resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(&{Atom.to_string(&1.name), &1.name})

    changeset
    |> Ash.Changeset.get_argument(:attributes)
    |> Enum.reduce(changeset, fn {key, value}, restored ->
      case Map.fetch(attributes, to_string(key)) do
        {:ok, attribute} -> Ash.Changeset.force_change_attribute(restored, attribute, value)
        :error -> restored
      end
    end)
  end
end
