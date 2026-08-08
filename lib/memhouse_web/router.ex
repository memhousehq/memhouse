# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Router do
  @moduledoc """
  Defines every HTTP route and its authentication boundary.

  Account identity always comes from the verified credential. Machine-facing routes can
  ingest observations and read governed memory but cannot perform curator actions.
  Self-governance requires a password identity; governance additionally requires curator
  or account-admin. Both browser areas share one signed session.
  """

  use MemHouseWeb, :router

  # JSON parsing only; routes remain public unless they also use :authenticated_api.
  pipeline :api do
    plug :accepts, ["json"]
  end

  # Authentication must precede metering because the meter bills the assigned actor.
  pipeline :authenticated_api do
    plug MemHouseWeb.Plugs.RequireIdentity
    plug MemHouseWeb.Plugs.MeterUsage
  end

  # Same-origin CSP allows LiveView sockets and existing inline styles, but no inline scripts.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    # Static LiveView redirects need flash state before the socket connects.
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_root_layout, html: {MemHouseWeb.Layouts, :root}

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; base-uri 'self'; connect-src 'self' ws: wss:; " <>
          "form-action 'self'; frame-ancestors 'none'; object-src 'none'; " <>
          "script-src 'self'; style-src 'self' 'unsafe-inline'"
    }
  end

  # Must follow :authenticated_api, which assigns the actor this plug inspects.
  pipeline :human_governance do
    plug MemHouseWeb.Plugs.RequireHumanIdentity
  end

  scope "/api", MemHouseWeb do
    pipe_through :api

    # Public probes must remain content-safe. "f5-1" is the extraction contract identity.
    get "/health", MemoryController, :health
    get "/ready", MemoryController, :ready

    # Credential failures share one opaque 401 to prevent account enumeration.
    post "/auth/password", AuthController, :password

    scope "/v1" do
      pipe_through :authenticated_api

      # This surface accepts raw observations; only the pipeline writes knowledge.
      post "/ingest", MemoryController, :ingest
      get "/ingest/:message_id", MemoryController, :ingest_status
      post "/ask", MemoryController, :ask
      post "/search", MemoryController, :search
      post "/context", MemoryController, :context
      post "/readiness", MemoryController, :readiness
      get "/knowledge", MemoryController, :knowledge
      get "/operations/costs", MemoryController, :costs
      post "/operations/reconcile", MemoryController, :reconcile
    end
  end

  # All password-authenticated roles share this console session.
  scope "/", MemHouseWeb do
    pipe_through :browser

    get "/", SessionController, :home

    get "/sign-in", SessionController, :new
    post "/sign-in", SessionController, :create
    delete "/sign-out", SessionController, :delete

    # Re-authenticate every mount and reconnect; individual pages narrow role access.
    live_session :console,
      on_mount: [{MemHouseWeb.ConsoleAuth, :default}] do
      live "/console", ConsoleLive.Dashboard, :index
      live "/console/knowledge", ConsoleLive.Knowledge, :index
      live "/console/knowledge/:id", ConsoleLive.KnowledgeDetail, :show
      live "/console/scopes", ConsoleLive.Scopes, :index
      live "/console/graph", ConsoleLive.Graph, :index
      live "/console/sources", ConsoleLive.Sources, :index
      live "/console/skills", ConsoleLive.Skills, :index
      live "/console/tools", ConsoleLive.Tools, :index
      live "/console/me", ConsoleLive.Me, :index
      live "/console/operations", ConsoleLive.Operations, :index
    end
  end

  scope "/governance", MemHouseWeb do
    pipe_through :browser

    # Only curator and account-admin password identities may establish this session.
    get "/sign-in", GovernanceSessionController, :new
    post "/sign-in", GovernanceSessionController, :create
    delete "/sign-out", GovernanceSessionController, :delete

    # Re-verify identity and role on every mount and reconnect.
    live_session :governance,
      on_mount: [{MemHouseWeb.GovernanceAuth, :default}] do
      live "/", GovernanceLive.Index, :index
    end
  end

  # Pipeline order is load-bearing: JSON, authentication, then the human-only check.
  scope "/api/v1", MemHouseWeb do
    pipe_through [:api, :authenticated_api, :human_governance]

    get "/self/knowledge", SelfGovernanceController, :index
    post "/self/knowledge/:id/contest", SelfGovernanceController, :contest
    post "/self/knowledge/:id/redact", SelfGovernanceController, :redact
    post "/self/erasure", SelfGovernanceController, :erase
  end

  # MCP derives Account access from the same bearer identity as the JSON API.
  scope "/mcp" do
    pipe_through [:api, :authenticated_api]

    # Complete machine allowlist: never add curator or promotion actions here.
    # "2025-03-26" is the advertised MCP protocol revision.
    forward "/", AshAi.Mcp.Router,
      tools: [
        :ingest,
        :get_context,
        :search,
        :ask,
        :query_knowledge,
        :check_readiness,
        :resolve_validation,
        :set_ask_preference
      ],
      protocol_version_statement: "2025-03-26",
      otp_app: :memhouse
  end
end
