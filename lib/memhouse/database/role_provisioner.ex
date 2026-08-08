# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Database.RoleProvisioner do
  @moduledoc """
  Creates the restricted application role before normal Repo startup.

  The step uses operator credentials only for idempotent role provisioning, then discards them.
  Normal application queries use the restricted role.
  """

  use GenServer

  alias MemHouse.Database.AppRole

  @doc """
  Starts the provisioning step under the supervision tree.

  Registered under the module name. Options are accepted and ignored: the role
  name comes from the node's configuration.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    AppRole.with_privileged_repo(&AppRole.provision!/1)
    {:ok, %{}}
  end
end
