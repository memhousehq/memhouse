# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule Mix.Tasks.Memhouse.Eval.Verify do
  @moduledoc """
  Checks that a stored evaluation report carries enough provenance to be quotable.

    Exactly one positional argument: the path to a JSON evaluation report or suite.
    There are no switches, no defaults, and nothing is written — the task only reads and
    reports.
  """

  use Mix.Task

  alias MemHouse.Eval.Report

  @shortdoc "Validates evaluation report provenance"

  @doc """
  Validates the report at the single positional path.

  Raises when the path is unreadable, the JSON is malformed, the provenance contract is not
  satisfied, or the argument list is not exactly one path; each surfaces as a non-zero exit
  status.
  """
  @impl true
  def run([path]) do
    # Deliberately no app.start: validation is pure JSON inspection, so this stays usable
    # on a machine with no database, which is how CI checks an uploaded artifact.
    report = path |> File.read!() |> Jason.decode!()

    case report do
      %{"report_schema" => "f11-suite-1"} -> Report.validate_suite!(report)
      _report -> Report.validate!(report)
    end

    Mix.shell().info("valid evaluation evidence: #{path}")
  end

  # Any argument list other than a single path is a caller mistake, not a default-path
  # invitation: silently verifying some assumed file would let CI "pass" on stale evidence.
  def run(_args), do: Mix.raise("usage: mix memhouse.eval.verify PATH")
end
