# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Database.RoleGuard do
  @moduledoc """
  Refuses startup unless the application connection is restricted by row-level security.

  It runs after Repo starts and treats owner, superuser, BYPASSRLS, or misconfigured roles as
  fatal rather than serving with weakened Account isolation.
  """

  use GenServer

  alias MemHouse.Database.AppRole

  @doc """
  Starts the guard under the supervision tree.

  Registered under the module name. Options are accepted and ignored. Raises
  from `init/1` — and so fails the boot — when the node's connections can bypass
  row-level security and the deployment has not explicitly opted out.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    AppRole.assert_enforced!()
    {:ok, %{}}
  end
end
