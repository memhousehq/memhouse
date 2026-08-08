# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Update.Checker do
  @moduledoc """
  Periodically refreshes update availability without delaying application boot.

  It only checks and records status. Replacing a running release would break request handling, so
  automatic activation is performed by the stable launcher before the server starts.
  """

  use GenServer

  @doc "Starts the non-blocking update checker."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :check)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    _ = MemHouse.Update.check()
    hours = Application.get_env(:memhouse, :update, []) |> Keyword.get(:interval_hours, 24)
    Process.send_after(self(), :check, hours * 60 * 60 * 1_000)
    {:noreply, state}
  end
end
