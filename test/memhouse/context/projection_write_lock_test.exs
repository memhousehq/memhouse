# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Context.ProjectionWriteLockTest do
  @moduledoc """
  Proves that current projection writers serialize the final transaction per Account and scope.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MemHouse.Context.{ProjectionInputs, ProjectionLock}
  alias MemHouse.DataLayer
  alias MemHouse.Governance.{Erasure, ErasureRequest}
  alias MemHouse.Knowledge.Projection
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

  test "a projection commit and real scope mutation keep Account then scope lock order" do
    {account_id, scope_id} = create_scope!()
    parent = self()

    projection_writer =
      Task.async(fn ->
        with_connection(fn ->
          DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account,
                                                                                     actor ->
            writer_backend_pid = backend_pid!()
            ProjectionLock.acquire!(account_id, scope_id)
            send(parent, {:scope_locked, writer_backend_pid})

            receive do
              :write_projection ->
                Projection
                |> Ash.Changeset.new()
                |> Ash.Changeset.set_tenant(account_id)
                |> Ash.Changeset.for_create(:upsert_from_pipeline, %{
                  cache_key: "scope:#{scope_id}:lock-order",
                  scope_id: scope_id,
                  kind: "scope_card",
                  version: 1,
                  validity_version: 1,
                  content: %{"name" => "Current projection"},
                  source_ids: [],
                  dirty: false
                })
                |> Ash.create!(actor: actor, authorize?: false)
            end
          end)
        end)
      end)

    assert_receive {:scope_locked, writer_backend_pid}, 5_000

    mutation =
      Task.async(fn ->
        with_connection(fn ->
          DataLayer.with_account_id(account_id, fn _account, actor ->
            ProjectionInputs.serialize_account!(account_id)
            mutation_backend_pid = backend_pid!()
            send(parent, {:account_locked, mutation_backend_pid})

            scope =
              Scope
              |> Ash.Query.filter(id == ^scope_id)
              |> Ash.Query.set_tenant(account_id)
              |> Ash.read_one!(actor: actor)

            scope
            |> Ash.Changeset.for_update(:update, %{name: "Mutation after projection commit"})
            |> Ash.Changeset.set_tenant(account_id)
            |> Ash.update!(actor: actor)
          end)
        end)
      end)

    assert_receive {:account_locked, mutation_backend_pid}, 5_000
    assert_blocked_by!(mutation_backend_pid, writer_backend_pid)

    send(projection_writer.pid, :write_projection)

    assert %Projection{} = Task.await(projection_writer, 5_000)
    assert %Scope{name: "Mutation after projection commit"} = Task.await(mutation, 5_000)
  end

  test "erasure acquires the Account projection-input lock before reading rows" do
    {account_id, _scope_id} = create_scope!()
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    blocker =
      Task.async(fn ->
        with_connection(fn ->
          DataLayer.with_account_id(account_id, fn _account, _actor ->
            blocker_backend_pid = backend_pid!()
            ProjectionInputs.serialize_account!(account_id)
            send(parent, {:erasure_lock_held, blocker_backend_pid})

            receive do
              :release -> :released
            end
          end)
        end)
      end)

    assert_receive {:erasure_lock_held, blocker_backend_pid}, 5_000

    erasure =
      Task.Supervisor.async_nolink(supervisor, fn ->
        with_connection(fn ->
          DataLayer.with_account_id(account_id, [role: :system, pipeline?: true], fn _account,
                                                                                     actor ->
            erasure_backend_pid = backend_pid!()
            send(parent, {:erasure_started, erasure_backend_pid})

            Erasure.execute!(
              %ErasureRequest{account_id: account_id, peer_id: Ash.UUID.generate()},
              actor
            )
          end)
        end)
      end)

    assert_receive {:erasure_started, erasure_backend_pid}, 5_000
    assert_blocked_by!(erasure_backend_pid, blocker_backend_pid)

    send(blocker.pid, :release)
    assert :released = Task.await(blocker, 5_000)

    assert {:exit, {%Ash.Error.Query.NotFound{resource: MemHouse.Accounts.Peer}, _stacktrace}} =
             Task.yield(erasure, 5_000)
  end

  test "capturing an absent scope raises the Ash domain error" do
    {account_id, _scope_id} = create_scope!()

    with_connection(fn ->
      assert_raise Ash.Error.Query.NotFound, fn ->
        ProjectionLock.capture!(account_id, Ash.UUID.generate())
      end
    end)
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
