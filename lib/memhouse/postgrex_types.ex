# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.PostgrexVectorExtension do
  @moduledoc """
  Encodes and decodes pgvector values for Postgrex.

  The extension validates dimensions and finite float values and raises on malformed wire data.
  It changes representation only; vector identity and authorization remain domain concerns.
  """

  import Postgrex.BinaryUtils, warn: false

  @doc """
  Chooses how decoded binaries are handled, from the driver's connection options.

  Returns `:copy` unless told otherwise. Copying matters here: without it, a
  decoded vector would be a slice of the much larger network receive buffer,
  and holding one small embedding would keep that whole buffer alive. Passing
  `:reference` avoids the copy and is only sensible when the value is consumed
  immediately and discarded.

  The return value is the state threaded into the other callbacks.
  """
  def init(opts), do: Keyword.get(opts, :decode_binary, :copy)

  @doc """
  Declares which PostgreSQL type this extension handles: the pgvector `vector` type.

  Matching by name rather than by numeric type id is required, because an
  extension type is assigned a different id in every database.
  """
  def matching(_state), do: [type: "vector"]

  @doc """
  Selects the binary wire format rather than the text one.
  """
  def format(_state), do: :binary

  @doc """
  Returns the quoted clause the generated type module uses to encode a vector.

  Accepts anything the vector type can be built from — a list of floats or an
  already-built vector — and emits the length-prefixed binary payload as iodata.
  The clause raises on a value that cannot be converted, which is the intended
  outcome: a malformed embedding must not reach the database.
  """
  def encode(_state) do
    quote do
      vector ->
        {:ok, vector} = Ash.Vector.new(vector)
        data = Ash.Vector.to_binary(vector)
        [<<IO.iodata_length(data)::int32()>>, data]
    end
  end

  @doc """
  Returns the quoted clause the generated type module uses to decode a vector.

  The two variants differ only in whether the payload is copied out of the
  connection's receive buffer first; see `init/1` for why the copying variant is
  the default. Both read the four-byte length prefix and rebuild a vector from
  exactly that many bytes.
  """
  def decode(:copy) do
    quote do
      <<length::int32(), data::binary-size(length)>> ->
        data |> :binary.copy() |> Ash.Vector.from_binary()
    end
  end

  def decode(_state) do
    quote do
      <<length::int32(), data::binary-size(length)>> ->
        Ash.Vector.from_binary(data)
    end
  end
end

# Builds `MemHouse.PostgrexTypes`, the type module the repository is configured
# to use: the vector extension above plus everything Ecto's PostgreSQL adapter
# normally installs. Appending rather than replacing is essential — dropping the
# stock extensions would break every ordinary column type.
#
# This runs at compile time, in this file, because the driver's type module has
# to exist before a connection can reference it. That is also why the repository
# setting that names it is a compile-time configuration rather than a runtime one.
Postgrex.Types.define(
  MemHouse.PostgrexTypes,
  [MemHouse.PostgrexVectorExtension] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
