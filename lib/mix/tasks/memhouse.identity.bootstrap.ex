# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Identity.Bootstrap do
  use Mix.Task

  @shortdoc "Bootstraps the free Account and its first human administrator"

  @moduledoc """
  Creates the single community Account and its first human administrator.

    This is the one-time step that turns a migrated but empty database into a usable
    installation. It provisions the community Account if it does not exist, registers a
    human peer with a password identity, grants that peer the administrator role on the
    root scope with downward propagation, and prints a short-lived bearer token so the
    operator can make an authenticated call immediately.
  """

  @doc """
  Parses the switches described in the module documentation, performs the bootstrap, and
  prints the Account key, administrator peer id, and bearer token.

  Raises on missing or invalid arguments and on a conflicting existing identity, which
  surfaces as a non-zero exit status.
  """
  @impl true
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _args, invalid} =
      OptionParser.parse(argv,
        strict: [email: :string, name: :string, password: :string],
        aliases: [e: :email, n: :name]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    email = Keyword.get(opts, :email) || Mix.raise("--email is required")
    name = Keyword.get(opts, :name, email)

    # There is no fallback password by design. An installation that silently came up with a
    # known credential would be reachable by anyone who read this file.
    password =
      Keyword.get(opts, :password) ||
        System.get_env("MEMHOUSE_BOOTSTRAP_PASSWORD") ||
        Mix.raise("set MEMHOUSE_BOOTSTRAP_PASSWORD or pass --password")

    result =
      MemHouse.Identity.bootstrap_human(%{
        email: email,
        name: name,
        password: password
      })

    Mix.shell().info("Bootstrapped community Account #{result.account.key}.")
    Mix.shell().info("Administrator peer: #{result.peer.id}")
    # The token is issued once and never stored in retrievable form; the operator must copy
    # it now. It is a credential, so it must not be echoed into logs or telemetry.
    Mix.shell().info("Bearer token (12h): #{result.token}")
  end
end
