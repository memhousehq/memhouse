<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Release guide

For maintainers: how MemHouse is versioned, what a release publishes, how to cut one, and what
has to be set up once before the first. Users who want to check a release:
[supply chain](security/supply-chain.md).

> **Status (27 November 2026).** The pipeline is in the repository and each part that can run
> on a developer's machine has been run there (`scripts/release-dry-run.sh`). The workflow
> itself has not run on GitHub yet, and nothing has been published: the
> [one-time setup](#one-time-setup) comes first, then a [dry run](#dry-run).

## Contents

- [Versioning](#versioning)
- [What a release publishes](#what-a-release-publishes)
- [Cut a release](#cut-a-release)
- [Dry run](#dry-run)
- [When a release fails part-way](#when-a-release-fails-part-way)
- [One-time setup](#one-time-setup)
- [The pipeline, job by job](#the-pipeline-job-by-job)
- [Keeping the pipeline current](#keeping-the-pipeline-current)

## Versioning

- **One product version**, [Semantic Versioning](https://semver.org/), carried in lockstep by
  everything a release publishes: the eight crates, the Python and TypeScript SDKs, the
  embedded bindings, the container image and the Helm chart (its `version` and `appVersion`).
  The source of truth is `[workspace.package] version` in the root `Cargo.toml`.
- **`cargo xtask version`** checks every place that states it (the workspace's internal
  dependency versions, `Cargo.lock`, the SDK manifests and lock file, `__version__`, the chart)
  and that `CHANGELOG.md` has a section for it; `cargo xtask ci` and hosted CI run it, so a
  drift fails a pull request. `cargo xtask version --set 2.1.0` writes all of them.
- **Pre-releases** are `-alpha.N`, `-beta.N` and `-rc.N` (`2.1.0-rc.1`). Python packaging
  spells them its own way (`2.1.0rc1`), which the command handles. A pre-release is published
  as one: npm tag `next`, a GitHub pre-release, no `latest` image tag, no documentation site.
- **The API has its own version** (`info.version` of `api/openapi.json`, `/health`'s
  `api_version`) and its own policy ([api-stability.md](api-stability.md)). A release does not
  move it; a change to the API does.
- **What a major, minor or patch means:** a patch fixes; a minor adds, and may add API minors,
  schema versions (additive: old and new binaries share a database) and configuration keys with
  defaults; a major may remove what a deprecation has announced for at least the period the
  stability policy gives.
- **The changelog** ([CHANGELOG.md](../CHANGELOG.md)) has one section per version, written as
  the work lands. Its section for the version becomes the release notes
  (`cargo xtask version --notes`).

## What a release publishes

| Artefact | Where | How it gets there |
|---|---|---|
| `memhouse-<v>-<target>.tar.gz` for `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`, `aarch64-apple-darwin` | GitHub release | workflow token |
| `install.sh`, `memhouse.rb` (Homebrew formula), `RELEASE_NOTES.md`, the documentation site as `memhouse-docs-<v>.tar.gz` | GitHub release | workflow token |
| `SHA256SUMS`, Sigstore bundles, the provenance and SBOM attestations, two CycloneDX SBOMs | GitHub release (attestations also in the repository's attestation store) | keyless signing with the workflow's OIDC identity |
| Container image, `linux/amd64` and `linux/arm64` | `ghcr.io/memhousehq/memhouse` | workflow token; signed and attested by digest |
| Helm chart | `oci://ghcr.io/memhousehq/charts/memhouse` | workflow token; signed by digest |
| Eight crates | crates.io | trusted publishing (OIDC) |
| `memhouse` (sdist, wheel), `memhouse-lite` (three wheels) | PyPI | trusted publishing (OIDC) |
| `@memhouse/sdk`, `@memhouse/lite` | npm | trusted publishing (OIDC) |
| Documentation site | GitHub Pages, when turned on | Pages deployment (OIDC) |

Not released: binaries for Intel Macs, Windows and musl ([platforms](install.md#platforms));
an sdist of `memhouse-lite` (it builds only inside this workspace).

## Cut a release

1. **Prepare, in a pull request.** `cargo xtask version --set <version>`; give the changelog's
   section its final heading (`## 2.1.0`, without "unreleased") and read it as release notes;
   run `cargo xtask ci`. Merge.
2. **Run the paid guard tiers** the roadmap asks for at a release, on your machine: T3, and T4
   with the approval it needs ([benchmarks.md](benchmarks.md#where-benchmarks-run)). Record the
   outcome with the goal or in the changelog.
3. **Tag the merged commit, signed**, and push the tag:

   ```bash
   git switch main && git pull --ff-only
   cargo xtask version                       # the tree states one version
   git tag -s v2.1.0 -m "MemHouse 2.1.0"
   scripts/release/verify-tag.sh v2.1.0      # what the workflow's first job will check
   git push origin v2.1.0
   ```

4. **Watch the workflow** (`release`, in the Actions tab). It verifies the tag, builds every
   artefact on its own platform, tests the image, assembles, makes the SBOMs and
   `SHA256SUMS`, signs and attests, verifies its own signatures, and then **stops**: each
   publishing job waits for a reviewer of the `release` environment.
5. **Review before approving.** Download the `release` artefact of the run. Check the list in
   the run's summary, try a binary, read `RELEASE_NOTES.md`. Up to here nothing is public
   except the tag and the signatures' transparency-log entries.
6. **Approve.** The image and chart, crates.io, PyPI and npm publish side by side; the GitHub
   release is created last, when all of them have succeeded, so `releases/latest` (which
   `install.sh` and the Homebrew tap follow) never points at a release that is half out.
7. **After.** Verify one download as a user would
   ([supply chain](security/supply-chain.md#verify-a-download)); update the Homebrew tap
   ([packaging/homebrew](../packaging/homebrew/README.md)); set the next version on `main` when
   work on it starts.

Rejecting the approval instead of giving it leaves a complete, signed, unpublished set of
artefacts: every release is a dry run until it is approved.

## Dry run

Three ways, from least to most complete:

- **On your machine:** `scripts/release-dry-run.sh` builds what this machine can (the host's
  binary archive, the crates, the SDK packages, the host's wheel and addon, the chart, the
  site, the SBOM, `SHA256SUMS`) into `dist/release`, with the pipeline's own scripts and pinned
  tools. No signatures: they need the workflow's identity. With `--linux-binary` it also packs
  a Linux binary and builds the image from it.
- **On GitHub, by hand:** in the Actions tab choose the `release` workflow, "Run workflow",
  pick an existing signed tag as the ref and leave "Dry run" ticked. Every job up to and
  including `sign and attest` runs; no publishing job is even offered for approval. The
  artefacts are the run's `release` artefact (kept 30 days).
- **A pushed tag, not approved:** as in [Cut a release](#cut-a-release), stopping at step 5.

A dry run on GitHub signs for real: Sigstore's public log and the repository's attestation
list keep entries for the dry run's files. That is what makes it a rehearsal of the signing
step; use a pre-release version (`2.1.0-rc.1`) if you would rather not have them under the
final version.

## When a release fails part-way

Publishing to a registry cannot be undone, so the publishing jobs are written to be run again:
each leaves what is already published as it is (a crate version that exists is skipped, PyPI
files that exist are skipped, an npm version that exists is skipped, the image and chart are
pushed to the same digest, an existing GitHub release gets its missing files). Fix the cause,
then re-run the failed jobs of the same run, or start the workflow by hand on the tag with
"Dry run" unticked.

Never move a release tag. If the tagged commit itself is wrong and nothing was published,
delete the tag and tag the fixed commit with the same version; if anything was published, the
fix is the next patch version (and `cargo yank`, `npm deprecate` or a PyPI yank for the bad one).

## One-time setup

Everything here is the maintainer's to do, outside the repository; the pipeline stores no
credential, so none of it involves giving it one. Do it in this order.

- [ ] **Tag signing key.** Make an SSH signing key (a hardware-backed one if you can), tell git
      to sign with it (`git config gpg.format ssh`, `git config user.signingkey <path to the
      public key>`), add the **public** key to [`.github/release-signers`](../.github/release-signers)
      in a pull request (`<your e-mail> namespaces="git" ssh-ed25519 AAAA…`), and add it to
      your GitHub account as a signing key so the tag shows as verified. The workflow refuses
      every tag until the file on `main` lists a key.
- [ ] **The `release` environment** (repository settings, Environments): required reviewers
      (at least one; someone other than the person who pushed the tag, when there is a second
      maintainer), deployment limited to tags matching `v*`, and **no secrets**.
- [ ] **A tag ruleset** for `v*`: only maintainers may create such tags, nobody may move or
      delete them once a release exists.
- [ ] **Actions settings.** Nothing to add: the workflow uses only GitHub's own actions and the
      two already allowed. Keep the default workflow token read-only; the jobs ask for what
      they need.
- [ ] **Container registry.** The first release creates the packages
      `ghcr.io/memhousehq/memhouse` and `ghcr.io/memhousehq/charts/memhouse`. Afterwards set
      each to public and connect it to this repository (organisation settings, Packages), and
      check that the organisation lets this repository's workflows create packages.
- [ ] **crates.io.** Trusted publishing cannot make a crate's first release, so the eight
      names (`memhouse-core`, `memhouse-store-postgres`, `memhouse-store-sqlite`,
      `memhouse-models`, `memhouse-conformance`, `memhouse-server`, `memhouse-bench`,
      `memhouse-cli`) must first exist: check that they are free, publish each once by hand
      with a short-lived token from your account (the first version, or a placeholder), then
      on each crate's Settings page add a Trusted Publisher: owner `memhousehq`, repository
      `memhouse`, workflow `release.yml`, environment `release`. Revoke the token. Consider
      reserving `memhouse` itself.
- [ ] **PyPI.** For `memhouse` and `memhouse-lite`: check that the names are free, then add a
      *pending* trusted publisher for each from your account's Publishing page (owner, repository,
      workflow `release.yml`, environment `release`). The first release creates the projects. A
      pending publisher does not reserve the name: do this shortly before the first release.
- [ ] **npm.** Create the `@memhouse` scope (an organisation). A trusted publisher can only be
      set on a package that exists, so publish `@memhouse/sdk` and `@memhouse/lite` once by
      hand (a placeholder version, with two-factor authentication), then on each package's
      settings add a trusted publisher for GitHub Actions (organisation `memhousehq`,
      repository `memhouse`, workflow `release.yml`, environment `release`) **with direct
      `npm publish` allowed**: configurations made since September 2026 allow only staged
      publishing unless that is ticked. A new configuration expires if it is not used within
      two days, so set it right before the first release. Afterwards set each package to
      "require two-factor authentication and disallow tokens".
- [ ] **Homebrew tap.** Create the public repository `memhousehq/homebrew-tap` (Apache-2.0)
      with `Formula/memhouse.rb` taken from the first release, and decide how it follows later
      releases: by hand, or a scheduled workflow in the tap
      ([packaging/homebrew](../packaging/homebrew/README.md)). Run `brew audit --strict` and
      `brew test` on the first formula.
- [ ] **Documentation site.** Either turn on GitHub Pages for this repository (Source: GitHub
      Actions) and set the repository variable `DOCS_PAGES` to `true`, after which each
      release deploys the site; or publish `memhouse-docs-<v>.tar.gz` from the release
      wherever the website lives. The website's own repository is outside this one.
- [ ] **Required checks.** Add `packaging checks` to the checks `main` requires, next to
      `checks` and `end-to-end and governance suite`.
- [ ] **The trademark question**, before the announcement: whether the name is registered or
      to be registered, and what the README and the site may say about it (moved here from
      the publication goal).
- [ ] **First dry run**, then the first release, as above.

## The pipeline, job by job

[`.github/workflows/release.yml`](../.github/workflows/release.yml). A job has only the
permissions listed; the workflow's default is none.

| Job | Runs on | Does | Permissions |
|---|---|---|---|
| `verify` | Linux | the tag is annotated, signed by a listed key, on `main`, and names the version; one version in every place; `cargo deny check` | contents: read |
| `binaries` (three) | each target | `cargo build --release --locked`, the glibc floor on Linux, `scripts/release/package.sh` | contents: read |
| `bindings` (three) | each target | the abi3 wheel (maturin) and the Node.js addon; each is loaded once | contents: read |
| `packages` | Linux | `cargo package` of the eight crates (each built from its packed form), the SDK packages, the chart (`scripts/helm-check.sh`), the site, `install.sh` and its tests, the release notes | contents: read |
| `image` | Linux | the two-architecture image from the archives' binaries (no compilation, no emulation), as an OCI archive; `scripts/container-test.sh` on it | contents: read |
| `assemble` | Linux | the npm package of the binding with its three addons, both SBOMs, the Homebrew formula, `SHA256SUMS`, and `scripts/release/complete.sh`: nothing is missing | contents: read |
| `sign` | Linux | Sigstore signatures (`scripts/release/sign.sh`), provenance and SBOM attestations (`actions/attest`), then verifies its own signatures | id-token: write, attestations: write, contents: read |
| `publish-oci` | Linux, environment `release` | pushes the image archive and the chart, signs both by digest, attests the image | packages: write, id-token: write, attestations: write, contents: read |
| `publish-crates` | Linux, environment `release` | exchanges the OIDC token at crates.io for a token of this job, publishes in dependency order, revokes it | id-token: write, contents: read |
| `publish-pypi` | Linux, environment `release` | `uv publish --trusted-publishing always` | id-token: write, contents: read |
| `publish-npm` | Linux, environment `release` | `npm publish` of the two tarballs | id-token: write, contents: read |
| `publish-github` | Linux, environment `release` | the GitHub release with every file, after the four above | contents: write |
| `publish-site` | Linux, environment `github-pages` | deploys the site, when `DOCS_PAGES` is `true` and the version is not a pre-release | pages: write, id-token: write |

Hosted CI ([`ci.yml`](../.github/workflows/ci.yml)) keeps the pieces working between
releases: `packaging checks` lints the scripts and workflows, checks the chart, tests
`install.sh` and builds the site; the end-to-end job runs the
[README's quickstart in a clean container](../README.md#quickstart), with its ten-minute limit.

## Keeping the pipeline current

- **Actions** are updated by Dependabot, as in CI.
- **Release tools** (`scripts/release/tools.sh`) are pinned by version and SHA-256 and are not
  seen by Dependabot: review them each quarter and when one publishes a security fix. Change a
  version and its three checksums together, from the release's own checksum file.
- **uv, pnpm and maturin** versions are in the `env` of `release.yml`; `ci.yml` installs uv and
  pnpm in its SDK job. Keep the two files on the same versions.
- **Base images** in the `Dockerfile` are pinned by digest: update the Rust image and the
  distroless image together and run `scripts/container-test.sh`.
- **Signers.** Remove a key from `.github/release-signers` when its holder leaves or the key is
  lost; tags it signed stay verifiable through the releases' own signatures.
