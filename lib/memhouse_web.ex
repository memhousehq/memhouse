# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb do
  @moduledoc """
  Shared setup for every Phoenix module in MemHouse's web layer.

  `use MemHouseWeb, profile` injects one shared helper set. Identity, Account, and authorization
  remain in plugs and LiveView hooks; never derive Account from request data. Quoted blocks contain
  setup only, not copied business functions.
  """

  @doc """
  Directories and files under `priv/static` that the endpoint is allowed to serve.

  Unlisted `priv/static` files remain unavailable over HTTP.
  """
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @doc """
  Setup for the router module: the Phoenix router plus the imports its pipelines need.

  Route helper generation is off; routes are written with the compile-time verified `~p`
  sigil instead, so a typo in a path fails the build rather than 404ing at runtime.
  """
  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Router pipelines need these function plugs and `live_session`.
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @doc """
  Setup for Phoenix channel modules. No channel module exists in this project today.
  """
  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  @doc """
  Setup for controller modules serving HTML and JSON.

  Authenticated controllers use `conn.assigns.current_actor`; they never reconstruct Account from
  request data.
  """
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @doc """
  Setup for LiveView modules.

  Uses only the root layout. Authentication hooks must reverify every mount and reconnect.
  """
  def live_view do
    quote do
      use Phoenix.LiveView, layout: false

      unquote(html_helpers())
    end
  end

  @doc """
  Setup for stateless function-component modules, including the layouts.
  """
  def html do
    quote do
      use Phoenix.Component

      unquote(html_helpers())
    end
  end

  @doc """
  Rendering helpers shared by LiveViews and function components.

  Shared by static components and LiveViews for identical template behavior.
  """
  def html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.Component

      unquote(verified_routes())
    end
  end

  @doc """
  Enables the `~p` sigil, which checks every path against the router at compile time.

  `statics:` identifies served assets for compile-time verification.
  """
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: MemHouseWeb.Endpoint,
        router: MemHouseWeb.Router,
        statics: MemHouseWeb.static_paths()
    end
  end

  @doc """
  Expands `use MemHouseWeb, :which` into the quoted block returned by the function named
  `which` in this module.

  Unknown profiles raise `UndefinedFunctionError` at compile time.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
