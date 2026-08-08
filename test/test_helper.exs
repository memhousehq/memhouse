# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

# Suite bootstrap. `mix test` evaluates this script once, before it loads any
# test file, and nothing here runs again per test.
#
# Inputs: the `:test` Mix environment (which also compiles `test/support` into
# the build, so the case templates and the offline model cassette provider are
# available), and the `MemHouse.Repo` configuration for the test database.
# Outputs: a started ExUnit runner and a Repo whose connection pool is in
# manual sandbox mode.
#
# Assumption: a reachable PostgreSQL test database already exists and is
# migrated. Nothing here creates or migrates it.

ExUnit.start()

# Manual mode means no process may run a query until it has explicitly checked
# a connection out of the sandbox pool. The case templates do that checkout in
# their `setup` and hand the connection back afterwards, which rolls the test's
# transaction back so no row survives the test. Leaving the pool in the default
# automatic mode would let the first query in any process silently open its own
# connection and commit real rows, which would leak state between tests and
# make ordering-dependent failures appear at random.
Ecto.Adapters.SQL.Sandbox.mode(MemHouse.Repo, :manual)
