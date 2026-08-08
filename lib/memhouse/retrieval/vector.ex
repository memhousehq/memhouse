# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Retrieval.Vector do
  @moduledoc """
  Computes in-process cosine similarity for entity resolution.

  Stored-record search uses PostgreSQL indexes. Missing, mismatched, or zero-magnitude vectors
  return 0.0 so one unusable entity does not abort resolution.
  """

  @doc """
  Returns the cosine similarity of two vectors as a float, normally in the
  range -1.0 to 1.0, where 1.0 means identical direction.

  Accepts stored vectors or number lists. Empty, mismatched, or zero-magnitude inputs return 0.0.
  """
  def cosine(left, right) do
    left = to_list(left)
    right = to_list(right)

    if left == [] or length(left) != length(right) do
      0.0
    else
      left_tensor = Nx.tensor(left, type: {:f, 32})
      right_tensor = Nx.tensor(right, type: {:f, 32})

      # Outside `defn`, tensors require Nx arithmetic functions.
      denominator = Nx.multiply(Nx.LinAlg.norm(left_tensor), Nx.LinAlg.norm(right_tensor))

      if Nx.to_number(denominator) == 0.0 do
        0.0
      else
        Nx.to_number(Nx.divide(Nx.dot(left_tensor, right_tensor), denominator))
      end
    end
  end

  @doc """
  Coerces a vector to a plain list of numbers.

  Accepts a stored vector or list; other values become `[]`.
  """
  def to_list(%Ash.Vector{} = vector), do: Ash.Vector.to_list(vector)
  def to_list(vector) when is_list(vector), do: vector
  def to_list(_vector), do: []
end
