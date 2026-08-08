# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

# Test-environment configuration, used by `mix test`.
#
# WHEN THIS FILE IS EVALUATED At build time, immediately after `config/config.exs` (which
# imports it at its bottom) and only when MIX_ENV=test. `config/runtime.exs` still runs
# afterwards and has test-specific branches of its own: it reads the database URL from
# MEMHOUSE_TEST_DATABASE_URL rather than DATABASE_URL, and it forces the model credential to
# nil so a developer's live API key in the shell can never make a test suite non-deterministic
# or spend money.

import Config

# Tests must not make release-feed requests just because the application starts.
config :memhouse, :update, enabled: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :memhouse, MemHouse.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "memhouse_test#{System.get_env("MIX_TEST_PARTITION")}",
  # Every test runs inside a transaction that is rolled back afterwards, so no
  # test can leak durable rows into the next one.
  pool: Ecto.Adapters.SQL.Sandbox,
  # Two connections per scheduler, so async tests can actually run in parallel.
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :memhouse, MemHouseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  # Public, committed, test-only value. Never reuse it anywhere else.
  secret_key_base: "+kva5XkTTwZ6ikuEVRv2mqPLh23Lfu3ht8EDoqqwb1tYR2ohmjlXZlwi9eEuHdpi",
  # No listener is started; controller tests drive the endpoint in-process.
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Jobs are inserted but never executed by a running queue. Tests drain the ones
# they care about explicitly, which keeps job execution ordering deterministic
# and stops background work from racing an assertion.
config :memhouse, Oban, testing: :manual

# Tests must remain deterministic even when the developer shell has a live
# model credential. The runtime model config deliberately clears that key.
#
# The inline-question attach deadline is raised from 15 ms to 1000 ms here only
# because a cold sandbox connection, a first-call query plan, and a loaded CI
# machine routinely exceed 15 ms. Production keeps the tight ceiling so a
# pending question can never slow a read.
config :memhouse, :governance, attach_deadline_ms: 1_000

# SQL sandbox owns one shared connection per non-async test. Production keeps
# true Task fan-out; tests execute the same strategy contracts serially so four
# tasks do not contend for the single sandbox connection.
config :memhouse, :retrieval_concurrency, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
