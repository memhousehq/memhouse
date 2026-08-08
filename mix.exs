# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.MixProject do
  @moduledoc """
  Build definition for MemHouse: one OTP application, one Mix release, two deployment modes.

  MemHouse ships as a single `memhouse` release that runs either against an operator-run
  PostgreSQL or against a private PostgreSQL the release starts for itself. Which one is in
  use is decided by runtime environment variables, never by the build — there is no second
  project file, no alternate dependency set, and no build-time flag that forks behaviour.
  Anything added here therefore applies to both deployments at once.

  ## What must stay in step with this file

  The `version` below is read as data by the release-readiness check. It must parse as
  Semantic Versioning, `CHANGELOG.md` must carry a dated entry for exactly that string, and
  the git tag must be exactly `v` followed by it. Bumping one of the three without the
  others fails the release gate rather than shipping a mislabelled build.

  ## What belongs elsewhere

  Runtime configuration (database mode, secrets, model roles, blob storage) lives in the
  config files and is resolved when the release boots, not here. The unpacked release's
  extra launchers and the embedded-PostgreSQL staging are produced by the packaging script
  and the release overlays, not by this file.
  """
  use Mix.Project

  @doc """
  Top-level project definition consumed by Mix.

  Returns the keyword list that names the application, its version, and the build settings
  shared by every environment.
  """
  def project do
    [
      app: :memhouse,
      # Read as data by the release-readiness check, which requires a matching dated
      # CHANGELOG entry and a `v`-prefixed git tag before a release may proceed.
      version: "0.4.0",
      elixir: "~> 1.17",
      # Registers the LiveView compiler, which extracts the hooks, JS, and CSS colocated
      # inside HEEx templates. It schedules its own pass to run after the Elixir compiler
      # has finished; this list position is the arrangement LiveView documents.
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      elixirc_paths: elixirc_paths(Mix.env()),
      # In production a crashed application takes the VM down, so a supervisor of last
      # resort (systemd, Docker, the platform) can restart from a known-clean state
      # instead of leaving a half-started node serving traffic.
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: dialyzer(),
      deps: deps(),
      package: package(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  @doc """
  OTP application definition.

  Names the root supervisor module and the extra OTP applications that must be started
  alongside it. `runtime_tools` is kept in the release so an operator can attach to a
  running node and observe it without redeploying a differently built artifact.
  """
  def application do
    [
      mod: {MemHouse.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  @doc """
  Default Mix environments for project-specific tasks.

  The `precommit` alias runs the test suite, so it is forced into the test environment.
  Without this a developer invoking it from a plain shell would compile the application in
  the development environment and then try to run tests against it.
  """
  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Test runs additionally compile `test/support`, which holds shared case templates and
  # fixture helpers. Those must never reach a production build, so they are added only for
  # the test environment rather than being moved under `lib`.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Runtime and tooling dependencies.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
      # The PostgreSQL driver. Left unconstrained on purpose: the Ash/Ecto packages above
      # already pin a compatible range, and duplicating it here only creates conflicts
      # when they move.
      {:postgrex, ">= 0.0.0"},
      {:ash, "~> 3.30"},
      {:ash_authentication, "~> 4.14"},
      {:ash_ai, "~> 0.7.3"},
      {:ash_postgres, "~> 2.11"},
      {:ash_oban, "~> 0.8.10"},
      # Code-generation engine behind the migration and resource-snapshot tasks. It is a
      # build-time tool only, so it is kept out of the started application; the override
      # keeps the several Ash packages that depend on it on one version.
      {:igniter, "~> 0.6.16", override: true, runtime: false},
      # Boolean satisfiability solver used by Ash to evaluate authorization policies.
      # Removing it does not simplify anything: policy checks stop working.
      {:simple_sat, "~> 0.1.4"},
      {:oban, "~> 2.19"},
      # Numerical tensors, needed by the local embedding stack. Overridden because the
      # ONNX runtime and the retrieval-augmentation library each pin their own range and
      # the local embedder must not end up running against two different tensor versions.
      {:nx, "~> 0.10", override: true},
      # ONNX Runtime bindings. This is the default, fully local embedding path: no network
      # call, no API key, and therefore usable in an air-gapped install.
      {:ortex, "~> 0.1.10"},
      # Native document text extraction for the many binary formats (PDF, office files,
      # and similar) that arrive through document ingest.
      {:extractous_ex, "~> 0.2.1"},
      # Markdown parsing, used in preference to the generic extractor when the source is
      # already Markdown, so structure survives instead of being flattened to plain text.
      {:mdex, "~> 0.13.4"},
      # Retrieval-augmentation helpers. Only its batch embedding stage is used, to attach
      # vectors to already-built chunks; chunk storage and retrieval stay in this codebase
      # so tenancy and lifecycle filtering cannot be bypassed by a library default.
      {:rag, "~> 0.2.3"},
      # Splits extracted text into chunks on semantic boundaries and reports byte offsets,
      # so a retrieved chunk can be pointed back at its exact location in the original.
      {:text_chunker, "~> 0.6.1"},
      # S3-compatible object storage for document blobs. This is one of two interchangeable
      # blob adapters chosen at runtime; the other writes to a local directory, so object
      # storage is never a requirement.
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      # Required by the S3 client to read the XML that the S3 API returns. Nothing in this
      # application parses XML directly, so this looks unused and is not.
      {:sweet_xml, "~> 0.7"},
      # HTTP client. Several packages pull it in on their own version ranges — the model
      # client, the S3 client, and the authentication strategies among them — so it is
      # overridden to keep them all on one version.
      {:req, "~> 0.6.3", override: true},
      # Tokenizer for the local embedding model: it turns text into the exact token ids
      # that model expects, and supplies the token counts recorded for usage accounting.
      {:tokenizers, "~> 0.5"},
      # Loads `.env`-style files during runtime configuration so a self-hosted operator can
      # keep settings in a file instead of exporting variables by hand.
      {:dotenvy, "~> 1.1"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry_bandit, "~> 0.3.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_exporter, "~> 1.10"},
      {:opentelemetry_logger_metadata, "~> 0.2.0"},
      {:opentelemetry_oban, "~> 1.2"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Static analysis and security linting. All three gate CI and none of them is part of
      # the running system, so they are excluded from production builds entirely.
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false},
      # Generators for the property-based tests that cover invariants a fixed example set
      # cannot reach: cross-Account isolation, and downward role inheritance where any
      # applicable deny wins.
      {:stream_data, "~> 1.2"},
      # HTML parser Phoenix.LiveViewTest requires to drive a socket-level test (live/2,
      # render_click/2) rather than a plain HTTP response assertion.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  # Static type analysis settings.
  #
  # The custom mix tasks and the test support modules are analysed too, so the persistent
  # lookup table has to know about `mix` and `ex_unit`. The table is written to `priv/plts/`
  # instead of Dialyxir's default location under `_build`, so the CI cache can name it as its
  # own path: building it from scratch takes minutes, checking against it takes seconds.
  # `:no_warn` silences Dialyxir's deprecation notice for setting `:plt_file` at all.
  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  # Source-package metadata.
  #
  # The licence identifier here is the community/core licence and is not an OSI-approved
  # one; the full terms live in the licence files listed below, which is why both the
  # community and the enterprise licence text are shipped inside the package. Tests are
  # included on purpose: they are the executable statement of the behaviour contract, so a
  # recipient can re-verify the package instead of trusting it.
  defp package do
    [
      licenses: ["MemHouse-Sustainable-Use-1.0"],
      files: [
        "config",
        "lib",
        "priv",
        "test",
        "LICENSE.md",
        "LICENSE_EE.md",
        "CHANGELOG.md",
        "mix.exs",
        "README.md"
      ]
    ]
  end

  # The single deployable artifact.
  #
  # Launchers are generated for both Unix and Windows because the no-container release is
  # meant to be unpacked and run by an individual on their own machine, not only deployed to a
  # Linux server. `runtime_tools` is given the `:permanent` start type, so the tooling an
  # operator attaches to a live node with is always started with it.
  #
  # The overlay directory is copied verbatim into the built release. It carries the extra
  # entry points the generated launcher does not provide — a server starter that creates a
  # private data root and signing secret on first run, and a standalone migration command — so
  # a fresh install needs no manual setup step before it can serve.
  defp releases do
    [
      memhouse: [
        include_executables_for: [:unix, :windows],
        applications: [runtime_tools: :permanent],
        overlays: ["rel/overlays"]
      ]
    ]
  end

  # Command shortcuts. Each entry is a chain: the listed tasks run in order and the chain
  # stops at the first failure.
  defp aliases do
    [
      # One command for a new checkout.
      setup: ["deps.get", "ecto.setup"],
      # Order matters: the database must exist before migrations, and the seeds run last
      # because they insert through the migrated schema.
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      # Destructive. Drops the database and rebuilds it from migrations and seeds.
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # Overrides `mix test` so the suite can never run against a missing or out-of-date
      # schema. This matters because the schema carries hand-written extension, index, and
      # row-level-security statements: a stale database would silently weaken the very
      # isolation the tests are asserting. `--quiet` keeps the normal case free of noise.
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # Lint and security scan. `--strict` promotes advisory findings to failures, and the
      # security scanner reads its own configuration file for the reviewed exceptions.
      static: ["credo --strict", "sobelow --config"],
      # Local approximation of the continuous-integration gate. It stops at the first
      # failure and the suite runs last, so a compile error or a lint finding surfaces
      # before the slowest step. `deps.unlock --unused` fails when the lock file has
      # drifted from the dependency list above. Unlike the gate, this chain rewrites
      # formatting instead of only checking it, so run it before committing rather than
      # after.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "static",
        "test"
      ]
    ]
  end
end
