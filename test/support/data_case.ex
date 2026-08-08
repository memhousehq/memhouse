# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.DataCase do
  @moduledoc """
  ExUnit case template for tests that reach the database through Ash, Oban, or Ecto.

    It owns exactly one thing: the SQL sandbox connection for the test. Each test checks
    a connection out of the sandbox pool, runs inside a transaction on that connection,
    and the transaction is rolled back when the test ends, so no row a test writes
    survives it.
  """

  use ExUnit.CaseTemplate

  # Injected into every module that does `use MemHouse.DataCase`. Kept to
  # aliases and imports on purpose: a case template that also seeded data would
  # make every test pay for fixtures it does not use, and would hide which test
  # created which row.
  using do
    quote do
      alias MemHouse.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MemHouse.DataCase
    end
  end

  setup tags do
    MemHouse.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Checks a sandbox connection out for the current test and schedules its return.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MemHouse.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

    The result maps each field to a list of rendered messages, with placeholders such as
    the count in "should be at least %{count} character(s)" substituted from the error
    options so assertions can match the final human-readable string.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
