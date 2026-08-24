# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.ProjectionWriteLockTest do
  @moduledoc """
  Proves that current projection writers serialize the final transaction per Account and scope.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MemHouse.Context.Builder
  alias MemHouse.Repo

  test "overlapping final writes for one scope enter one at a time" do
    account_id = Ash.UUID.generate()
    scope_id = Ash.UUID.generate()
    parent = self()

    first =
      Task.async(fn ->
        with_connection(fn ->
          Repo.transaction(fn ->
            Builder.serialize_projection_writes!(account_id, scope_id, fn ->
              send(parent, {:entered, :first})

              receive do
                :release -> :first
              end
            end)
          end)
        end)
      end)

    assert_receive {:entered, :first}

    second =
      Task.async(fn ->
        with_connection(fn ->
          Repo.transaction(fn ->
            send(parent, {:attempting, :second})

            Builder.serialize_projection_writes!(account_id, scope_id, fn ->
              send(parent, {:entered, :second})
              :second
            end)
          end)
        end)
      end)

    assert_receive {:attempting, :second}
    refute_receive {:entered, :second}, 100

    send(first.pid, :release)

    assert_receive {:entered, :second}
    assert {:ok, :first} = Task.await(first)
    assert {:ok, :second} = Task.await(second)
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end
end
