# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.ReleaseReadiness do
  @moduledoc """
  Validates whether a revision can be released.

  It checks semantic version, tag and changelog alignment, clean provenance, required evaluation
  identity and deterministic floors, and expected surface evidence. Missing or malformed evidence
  fails closed; frontier metrics remain informational unless deliberately promoted to gates.
  """

  alias MemHouse.Eval.Report

  # Semantic Versioning core with an optional pre-release suffix, deliberately
  # without build metadata: a release tag must be unambiguous, and two versions
  # differing only in build metadata compare as equal.
  @semver ~r/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/

  @doc """
  Runs every release check and returns `%{version:, status: :ready}`, or raises.

  Options:

    * `:root` — repository root to read from. Defaults to the current working
      directory; tests and tooling pass an explicit path.
    * `:eval_report` — path to the evaluation suite document to verify. Required
      unless the caller explicitly opts out.
    * `:allow_missing_eval` — when true, skip the evaluation checks entirely.
      Defaults to false. This exists for metadata-only lanes such as an early
      pull-request check; a real release must supply the report, because
      without it nothing verifies the quality floors.
    * `:tag` — the tag about to be pushed. When absent, the tag check is
      skipped; when present it must match the declared version exactly.

  Raises `ArgumentError` with the specific reason on any failed check, and
  whatever `File.read!/1` raises when a required file is missing.
  """
  def check!(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    version = mix_version!(root)
    assert_semver!(version)
    assert_changelog!(root, version)
    assert_release_docs!(root)
    assert_tag!(version, Keyword.get(opts, :tag))

    case Keyword.get(opts, :eval_report) do
      nil ->
        unless Keyword.get(opts, :allow_missing_eval, false) do
          raise ArgumentError,
                "release evaluation evidence is required; pass --eval-report or --allow-missing-eval for metadata-only checks"
        end

      path ->
        assert_eval!(root, path, version)
    end

    %{version: version, status: :ready}
  end

  @doc """
  Reads the application version declared in the project file under `root`.

  Deliberately a text match rather than loading the project: the check must
  work on a tree it is not itself compiled from, and must see the literal a
  human would read.

  Returns the first `version: "..."` literal in the file. A project that
  computes its version instead of declaring one raises `ArgumentError`, because
  there would be nothing for a human or a tag to be checked against.
  """
  def mix_version!(root) do
    mix = read_local!(Path.join(root, "mix.exs"))

    case Regex.run(~r/version:\s*"([^"]+)"/, mix, capture: :all_but_first) do
      [version] -> version
      _match -> raise ArgumentError, "mix.exs must declare one literal version"
    end
  end

  defp assert_semver!(version) do
    unless Regex.match?(@semver, version) do
      raise ArgumentError, "mix.exs version #{inspect(version)} is not Semantic Versioning syntax"
    end
  end

  # Two requirements, both on the changelog:
  #
  #   * an Unreleased section, so the next change has somewhere to go and the
  #     file has not been closed off at this release; and
  #   * a heading for exactly this version with an ISO date, anchored to line
  #     start and end so a mention inside prose cannot satisfy it.
  #
  # The version is escaped before interpolation because it comes from file text
  # and its dots would otherwise match any character.
  defp assert_changelog!(root, version) do
    changelog = read_local!(Path.join(root, "CHANGELOG.md"))

    unless String.contains?(changelog, "## [Unreleased]") and
             Regex.match?(~r/^## \[#{Regex.escape(version)}\] - \d{4}-\d{2}-\d{2}$/m, changelog) do
      raise ArgumentError, "CHANGELOG.md must contain Unreleased and a dated #{version} entry"
    end
  end

  # The documents a releaser actually reads before tagging. Each must still
  # describe the release gate under a recognisable name, so that renaming or
  # deleting the gate cannot leave the shipped documentation quietly describing
  # a process that no longer exists. This is a documentation-coherence check,
  # not a content review: it only asserts the phrase is still there.
  @release_docs [
    "README.md",
    "AGENTS.md",
    ".github/workflows/README.md",
    "docs/operations/upgrades.md",
    "docs/reference/mix-tasks.md"
  ]

  # Case-folded, and both the spaced and hyphenated spellings are accepted, so
  # the check survives ordinary prose and heading style without needing every
  # document to phrase it identically.
  defp assert_release_docs!(root) do
    for file <- @release_docs do
      body = root |> Path.join(file) |> read_local!() |> String.downcase()

      unless String.contains?(body, "release readiness") or
               String.contains?(body, "release-readiness") do
        raise ArgumentError, "#{file} must document evaluation, CI, and release readiness"
      end
    end
  end

  # No tag supplied means the caller is checking a working tree rather than a
  # tag about to be pushed, so there is nothing to compare.
  defp assert_tag!(_version, nil), do: :ok

  # Exact string equality, not a version parse: the tag that gets pushed is a
  # literal, and a mistyped one must fail here rather than ship under a name
  # that does not match the declared version.
  defp assert_tag!(version, tag) do
    unless tag == "v#{version}" do
      raise ArgumentError, "release tag #{inspect(tag)} must equal v#{version}"
    end
  end

  # Order matters. Provenance is validated first, so an unusable report is
  # rejected before its numbers are trusted; then version equality, so evidence
  # measured against different code cannot be recycled; only then thresholds.
  defp assert_eval!(root, path, version) do
    suite = path |> read_local!() |> Jason.decode!() |> Report.validate_suite!()

    Enum.each(suite["reports"], fn report ->
      unless report["memhouse_version"] == version do
        raise ArgumentError,
              "eval report version #{report["memhouse_version"]} does not match #{version}"
      end
    end)

    manifest =
      root
      |> Path.join("test/fixtures/eval/release-suite.json")
      |> read_local!()
      |> Jason.decode!()

    thresholds =
      root
      |> Path.join("test/fixtures/eval/deterministic-thresholds.json")
      |> read_local!()
      |> Jason.decode!()

    # A run gates the release only when the matrix explicitly opts it in. The
    # default is false, so a newly added run is an ablation until someone
    # decides it should be able to block a release.
    guarded_ids =
      manifest["runs"]
      |> Enum.filter(&Map.get(&1, "release_guardrail", false))
      |> MapSet.new(& &1["id"])

    # Non-guardrail reports are skipped entirely. A guardrail run whose floor is
    # missing is not skipped — asserting thresholds raises for an unknown
    # benchmark and profile combination, so nobody can dodge a floor by
    # forgetting to commit one.
    suite["reports"]
    |> Enum.filter(&MapSet.member?(guarded_ids, &1["matrix_id"]))
    |> Enum.each(&Report.assert_thresholds!(&1, thresholds))
  end

  # Every path read here is either a fixed repository file or a report path the
  # operator passed on the command line; none is derived from network or
  # request input, which is why the traversal warning is suppressed.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_local!(path), do: File.read!(path)
end
