# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConnCase do
  @moduledoc """
  ExUnit case template for tests that drive the HTTP surface.

  `Phoenix.ConnTest` builds in-memory connections; no web server listens during tests.
  The template checks out the SQL sandbox and supplies verified routes.
  """

  use ExUnit.CaseTemplate

  # Injected into every module that does `use MemHouseWeb.ConnCase`.
  using do
    quote do
      # Phoenix.ConnTest request macros such as get/post/delete read @endpoint
      # from the calling module, so this attribute is what makes request calls
      # resolve at all. Removing it breaks every request helper in the module.
      @endpoint MemHouseWeb.Endpoint

      use MemHouseWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import MemHouseWeb.ConnCase
    end
  end

  setup tags do
    # Delegates to the data case template rather than duplicating the checkout,
    # so endpoint tests and data tests get identical sandbox and rollback rules.
    MemHouse.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
