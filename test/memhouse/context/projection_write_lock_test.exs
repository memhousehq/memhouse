# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.ProjectionWriteLockTest do
  @moduledoc """
  Proves that current projection writers serialize the final transaction per Account and scope.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MemHouse.Context.{ProjectionInputs, ProjectionLock}
  alias MemHouse.DataLayer
  alias MemHouse.Repo
  alias MemHouse.Topology.Scope

  require Ash.Query

  test "overlapping final writes for one scope enter one at a time" do
    {account_id, scope_id} = create_scope!()
    parent = self()

    first =
      Task.async(fn ->
        with_connection(fn ->
          DataLayer.with_account_id(account_id, fn _account, _actor ->
            backend_pid = backend_pid!()
            ProjectionLock.acquire!(account_id, scope_id)
            send(parent, {:entered, :first, backend_pid})

            receive do
              :release -> :first
            end
          end)
        end)
      end)

    assert_receive {:entered, :first, first_backend_pid}, 5_000

    second =
      Task.async(fn ->
        with_connection(fn ->
          DataLayer.with_account_id(account_id, fn _account, _actor ->
            backend_pid = backend_pid!()
            send(parent, {:attempting, :second, backend_pid})
            ProjectionLock.acquire!(account_id, scope_id)
            send(parent, {:entered, :second})
            :second
          end)
        end)
      end)

    assert_receive {:attempting, :second, second_backend_pid}, 5_000
    refute first_backend_pid == second_backend_pid
    assert_blocked_by!(second_backend_pid, first_backend_pid)

    send(first.pid, :release)

    assert_receive {:entered, :second}, 5_000
    assert :first = Task.await(first)
    assert :second = Task.await(second)
  end

  test "a real scope mutation cannot cross final projection-input validation" do
    {account_id, scope_id} = create_scope!()
    parent = self()

    validator =
      Task.async(fn ->
        with_connection(fn ->
          DataLayer.with_account_id(account_id, fn _account, _actor ->
            backend_pid = backend_pid!()
            ProjectionInputs.serialize_account!(account_id)
            send(parent, {:validated, backend_pid})

            receive do
              :release -> :validated
            end
          end)
        end)
      end)

    assert_receive {:validated, validator_backend_pid}, 5_000

    mutation =
      Task.async(fn ->
        with_connection(fn ->
          DataLayer.with_account_id(account_id, fn _account, actor ->
            scope =
              Scope
              |> Ash.Query.filter(id == ^scope_id)
              |> Ash.Query.set_tenant(account_id)
              |> Ash.read_one!(actor: actor)

            mutation_backend_pid = backend_pid!()
            send(parent, {:mutating, mutation_backend_pid})

            scope
            |> Ash.Changeset.for_update(:update, %{name: "Changed after validation"})
            |> Ash.Changeset.set_tenant(account_id)
            |> Ash.update!(actor: actor)
          end)
        end)
      end)

    assert_receive {:mutating, mutation_backend_pid}, 5_000
    assert_blocked_by!(mutation_backend_pid, validator_backend_pid)

    send(validator.pid, :release)

    assert :validated = Task.await(validator)
    assert %Scope{name: "Changed after validation"} = Task.await(mutation)
  end

  defp with_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp create_scope! do
    account_key = "projection-lock-#{Ash.UUID.generate()}"

    with_connection(fn ->
      DataLayer.with_account_key(account_key, fn account, actor ->
        scope =
          Scope
          |> Ash.Changeset.for_create(:ensure, %{
            parent_id: nil,
            key: "scope",
            name: "Scope",
            path: "/scope",
            state: "active"
          })
          |> Ash.Changeset.set_tenant(account.id)
          |> Ash.create!(actor: actor)

        {account.id, scope.id}
      end)
    end)
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    pid
  end

  defp assert_blocked_by!(blocked_pid, blocker_pid) do
    with_connection(fn ->
      assert_blocked_by!(blocked_pid, blocker_pid, 100)
    end)
  end

  defp assert_blocked_by!(_blocked_pid, _blocker_pid, 0),
    do: flunk("second projection writer never waited on the scope row lock")

  defp assert_blocked_by!(blocked_pid, blocker_pid, attempts) do
    %{rows: [[blocked?]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT $2 = ANY(pg_blocking_pids($1))",
        [blocked_pid, blocker_pid]
      )

    if blocked? do
      :ok
    else
      Process.sleep(10)
      assert_blocked_by!(blocked_pid, blocker_pid, attempts - 1)
    end
  end
end
