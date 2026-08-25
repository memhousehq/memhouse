<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# GitHub Actions Workflows

Evaluation, CI, and release readiness makes the repository automation executable
rather than placeholder-only. CI and evaluation use read-only repository
permissions. The GitHub-Release-triggered job receives `contents: write` and
`packages: write` so it can publish the gated outputs. Repository action access
is deliberately narrower than “allow all”:
GitHub-owned actions and `erlef/setup-beam@*` are the only non-local actions
needed. Verify in the live repository settings that Actions access allows only
GitHub-owned actions and `erlef/setup-beam@*`.

## `ci.yml`

Runs on pull requests, `main`, and merge queues:

- `Deterministic gate (external Postgres)` runs Ash snapshot drift, format,
  warnings-as-errors compile, all ExUnit/property tests, Credo, Sobelow, Hex
  retirement audit, the deterministic release-eval matrix, report verification,
  and release readiness.
- `Dialyzer` runs type analysis with cached PLTs.
- `Deterministic gate (packaged pg0)` checksum-builds and boots the packaged pg0
  release, verifies readiness, then runs the complete test suite against that
  pg0 instance.
- `Release and container builds` runs only after all three gates and builds the
  Mix release plus production container.

Every deployment mode uses PostgreSQL with pgvector, PG full-text search, and
Oban; SQLite is unsupported. pg0 and external Postgres vary infrastructure
location, not product behavior.

## `eval.yml`

Runs the versioned `f11-1` release matrix nightly or manually and retains the
report artifact for 30 days. Scheduled runs are deterministic. A manual
maintainer may select live-model mode only when the repository has a protected
`OPENROUTER_API_KEY` and `MEMHOUSE_EVAL_JUDGE_MODEL` variable. The judge model
must differ from `MEMHOUSE_MODEL_ASK`; untrusted pull requests never receive
the credential.

## `release.yml`

Runs when a maintainer publishes a GitHub Release for an existing semantic tag. It repeats
deterministic guardrails, verifies the tag/version/changelog/eval tuple, and
builds the checksum-pinned Linux x86_64/ARM64 and macOS Apple Silicon pg0 plus
pgvectorscale packages. Each package boots from an empty data root and
passes the full suite on its native runner. A final fan-in publishes all three
packages, their SHA-256 files, and eval evidence as durable GitHub Release assets. The Linux
job also pushes the container to this repository's GHCR package with both
`<version>` and `v<version>` tags; a stable release advances `latest`.
Workflow-run copies remain available for 90 days for debugging. GitHub generates
the release notes when the maintainer creates the release; the workflow uploads
only generated artifacts and never edits those notes.

The repository secret `MEMHOUSE_RELEASE_SIGNING_KEY` is the base64-encoded raw
Ed25519 private key matching MemHouse's embedded updater public key. The fan-in
job signs `release-manifest-v1.json`; standalone updaters reject assets unless
that detached signature and the manifest's per-platform SHA-256 both verify.

Configure the CI job names above as required checks only after they have
reported successfully.

## `prepare-release.yml` and `publish-release.yml`

Run **Prepare release PR** manually from `main`, entering a semantic version
without its `v` prefix. It moves the current `Unreleased` changelog content
into a dated release entry, updates the tracked release-version references,
checks the metadata, compiles with warnings as errors, and opens a
release-preparation PR. The job caches the test dependencies and build output by
`mix.lock`. A changed lock file can reuse unchanged dependencies from the most
recent test cache.

A cold build can still report warnings from `toml` 0.7.0, the Rust code in
`ortex` 0.1.10, Oban 2.23.1, and Ash 3.31.3. These are the current upstream
releases. The Oban and Ash upgrades did not remove their unused-clause and
deprecated `igniter/2` warnings. MemHouse accepts these dependency warnings until
an upstream release fixes them. It does not suppress compiler warnings because
suppression could hide a warning in MemHouse code. A cold native dependency
download can also produce an OTP 27 TLS logger formatter error. This is cosmetic,
occurs before compilation, and does not change the release result. A cache hit
avoids these cold-build messages.

Merging that PR invokes **Publish merged release**. It tags the merged version,
publishes the GitHub Release, and dispatches `release.yml` to build and attach
the artifacts. Normal releases use a new version. The optional repair choice
marks the PR as a replacement for an already failed release/tag; only then may
the publishing workflow delete and recreate that version. This design preserves
the required human PR merge gate.

## `docs.yml`

Builds the published user documentation from `docs/` with MkDocs Material and
deploys it to GitHub Pages. It runs on pushes to the default branch that touch
`docs/`, `mkdocs.yml`, or the workflow itself, on pull requests touching the
same paths, and on manual dispatch.

The build job needs no permissions and runs on pull requests too, so an
untrusted branch proves the site still compiles without being able to publish
it. Only the default branch reaches the deploy job, which holds `pages: write`
and `id-token: write` and nothing else.

`mkdocs.yml` sets `strict: true`, so a broken internal link or a page missing
from the navigation fails the build rather than shipping a dead link.

Publishing requires GitHub Pages to be set to "GitHub Actions" as its source.
That is a repository setting and remains a maintainer action; until it is set,
the deploy job fails and the build job still guards the Markdown.
