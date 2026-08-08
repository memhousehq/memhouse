# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Release.Check do
  @moduledoc """
  Fails unless the working tree satisfies release-readiness checks.

  The task validates the Mix version, tag and changelog alignment, repository state, and
  evaluation evidence. It reads files only and does not start the application.
  """

  use Mix.Task

  alias MemHouse.ReleaseReadiness

  @shortdoc "Fails unless the release satisfies release readiness"

  @doc """
  Parses the switches described in the module documentation and runs every release check.

  Raises on an unknown switch, on missing evaluation evidence without an explicit opt-out,
  and on any failed check, which surfaces as a non-zero exit status.
  """
  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          tag: :string,
          eval_report: :string,
          allow_missing_eval: :boolean
        ]
      )

    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    # Deliberately no app.start: every check reads repository files, so this gate stays
    # runnable in a lane that has no database and no configured model provider.
    result =
      ReleaseReadiness.check!(
        tag: Keyword.get(opts, :tag),
        eval_report: Keyword.get(opts, :eval_report),
        allow_missing_eval: Keyword.get(opts, :allow_missing_eval, false)
      )

    Mix.shell().info("release #{result.version} satisfies release readiness")
  end
end
