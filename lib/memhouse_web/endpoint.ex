# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Endpoint do
  @moduledoc """
  The HTTP entry point: the ordered plug pipeline every request passes through before
    the router sees it, plus the LiveView socket and the static-file serving rules.

    1. Static assets are answered first, so file serving never pays for parsing or
    sessions.
  """

  use Phoenix.Endpoint, otp_app: :memhouse

  # Session cookie settings, shared by the HTTP session and the LiveView socket so a browser
  # that signed in over HTTP is recognised when its socket connects.
  #
  # The cookie is signed but not encrypted: the browser owner can read its contents and
  # cannot forge them. That is acceptable only because the session holds nothing the client
  # does not already possess — its own sign-in token. Never put another peer's data,
  # knowledge text, or a server secret in the session without adding :encryption_salt first.
  #
  # `signing_salt` is a fixed, non-secret salt; the actual signing strength comes from the
  # endpoint's `secret_key_base`, which is supplied per deployment at runtime. Changing this
  # salt invalidates every live session, which is a blunt way to force sign-outs.
  #
  # SameSite=Lax means the cookie is not sent on cross-site POSTs, which is a second line of
  # defence behind the router's CSRF token check.
  @session_options [
    store: :cookie,
    key: "_memhouse_key",
    signing_salt: "nMCY+C/7",
    same_site: "Lax"
  ]

  # The curator LiveView socket. `connect_info: [session: ...]` is what lets the mount hook
  # read the sign-in token out of the cookie session and re-verify it on every connect;
  # without it the socket would have no identity at all. Longpoll is kept as the fallback
  # transport for environments where WebSockets are blocked.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # The two browser JS dependencies are served straight out of the installed Elixir packages
  # instead of being bundled. That keeps the repository free of a Node build step, and it
  # keeps every script same-origin so the strict script-src 'self' policy on the browser
  # pipeline holds without a CDN exception. `only:` limits each mount to the one file the
  # page imports.
  plug Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.mjs)

  plug Plug.Static,
    at: "/vendor/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js)

  # Application assets from priv/static, restricted to the allowlist so an unrelated file
  # dropped into that directory is not exposed over HTTP.
  #
  # `gzip` is on only outside code reloading, because pre-compressed files exist only after a
  # release build runs the digest step. `raise_on_missing_only` is a development aid: a
  # request for a file that exists in priv/static but is not in the allowlist raises instead
  # of being quietly refused, so a forgotten allowlist entry is caught by the developer.
  plug Plug.Static,
    at: "/",
    from: :memhouse,
    gzip: not code_reloading?,
    only: MemHouseWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  # Development-only stages. The repo check refuses requests when migrations are pending, so
  # a developer gets an explicit error page instead of confusing query failures deep in the
  # request. Neither is compiled into a release build.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :memhouse
  end

  # Correlation, before anything that can reject a request.
  #
  # Plug.RequestId puts a per-request id into logger metadata. TraceContext then resolves the
  # trace id — reusing the caller's W3C `traceparent` when one is supplied, otherwise minting
  # a fresh one — and registers the callback that returns it as the `x-trace-id` response
  # header. Because it is installed here, the header is present on 401s, 404s, and crashes
  # too, which is exactly when someone needs it. Move it below the router and error
  # responses stop being traceable.
  plug Plug.RequestId
  plug MemHouseWeb.Plugs.TraceContext
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Body parsing. `pass: ["*/*"]` lets unmatched content types reach the router with an
  # unparsed body rather than failing here, so the route decides what it accepts. Parsed
  # parameters are logged only after the configured sensitive-parameter filter has scrubbed
  # them; request content itself must never reach logs or traces.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  # MethodOverride and Head must follow the parsers (the override is read from the parsed
  # body) and precede the router, which matches on the resulting method. Head turns a HEAD
  # into a GET whose response body is discarded.
  plug Plug.MethodOverride
  plug Plug.Head

  # Installs the session configuration the browser pipeline's `fetch_session` and the CSRF
  # check then use, so it has to precede the router. JSON API routes never touch it.
  plug Plug.Session, @session_options
  plug MemHouseWeb.Router
end
