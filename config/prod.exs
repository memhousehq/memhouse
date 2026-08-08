# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

# Production build-time configuration.
#
# WHEN THIS FILE IS EVALUATED While the release is being built, immediately after
# `config/config.exs` (which imports it at its bottom) and only when MIX_ENV=prod. It is *not*
# re-read when the release starts, so nothing here can vary per deployment. Everything an
# operator must be able to change — host, port, secrets, database location, model roles,
# telemetry — lives in `config/runtime.exs`, which is evaluated on every boot of the built
# release.
#
# Only settings that genuinely cannot be deferred to boot belong in this file.

import Config

# Force using SSL in production. This also sets the "strict-security-transport" header, known
# as HSTS. If you have a health check endpoint, you may want to exclude it below. Note
# `:force_ssl` is required to be set at compile-time.
#
# `rewrite_on: [:x_forwarded_proto]` makes the check trust the proxy's protocol header, which
# is correct only behind a terminating proxy that sets it. The loopback hosts are excluded so
# a local container or an on-host probe can reach the app over plain HTTP without being
# redirected to a scheme it cannot use.
config :memhouse, MemHouseWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Production logs are structured JSON emitted by a formatter that applies the
# reviewed metadata allowlist. That allowlist is what keeps raw messages,
# prompts, answers, restricted knowledge, and credentials out of log output;
# swapping this formatter for a plain one removes that protection.
config :logger, :default_handler, formatter: {MemHouse.Observability.JSONFormatter, %{}}

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
