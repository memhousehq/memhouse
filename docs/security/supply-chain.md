<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Supply chain: how a release is made, and how to verify one

What stands between this repository and the file you run, and the commands that check each
step. For the release procedure itself see [release.md](../release.md); for credentials,
[secrets.md](secrets.md).

> **Status (27 November 2026).** The pipeline described here is in the repository and its
> parts are tested locally. It has not yet run on GitHub, and no release has been published:
> the verification commands below are written from the tools' documentation and are exercised
> by the workflow itself (it verifies its own signatures before anything is published), not
> yet against a published release.

## Contents

- [What protects a release](#what-protects-a-release)
- [Verify a download](#verify-a-download)
- [The container image](#the-container-image)
- [The Helm chart](#the-helm-chart)
- [Packages from registries](#packages-from-registries)
- [The software bill of materials](#the-software-bill-of-materials)
- [Dependencies and build inputs](#dependencies-and-build-inputs)
- [Limits](#limits)
- [Tool versions](#tool-versions)

## What protects a release

| Step | Control |
|---|---|
| Source | `main` is protected: pull requests, required checks, signed-off commits; the secret scanner runs on every commit and in CI |
| Start of a release | a tag `v<version>`, signed with an SSH key listed in [`.github/release-signers`](../../.github/release-signers) as that file stands on `main`; the tagged commit must be on `main` and its version must be the tag's. The workflow's first job checks all three (`scripts/release/verify-tag.sh`) and nothing else runs if it fails |
| Build | GitHub-hosted runners, from the tagged commit, with `--locked` dependency versions; only GitHub's own actions and two reviewed ones, all pinned to commit SHAs; every other tool is downloaded at a fixed version and checked against a recorded SHA-256 (`scripts/release/tools.sh`) |
| Vulnerabilities and licences | `cargo deny check` on every pull request and again at the start of every release: a known vulnerability or a licence outside the allow-list stops it |
| Integrity | `SHA256SUMS` lists every artefact of the release |
| Authenticity | `SHA256SUMS` and each binary archive are signed keylessly with Sigstore: the signature is bound to the identity of the release workflow at that tag, recorded in a public transparency log. No signing key exists to be stolen |
| Provenance | a SLSA build provenance attestation covers every artefact in `SHA256SUMS`: which repository, workflow, commit and runner produced it |
| Contents | a CycloneDX SBOM of the source's locked dependencies, attested for the binary archives; a second SBOM of the container image |
| Publishing | no stored registry token: crates.io, PyPI and npm accept the workflow's OIDC identity (trusted publishing); the container registry and the GitHub release take the workflow's own short-lived token. Every publishing job waits for a reviewer in the `release` environment |

## Verify a download

Replace `2.0.0` and the target with yours. All files are assets of the GitHub release.

**1. Checksum** — the file is the one the release lists.

```bash
curl -fsSLO https://github.com/memhousehq/memhouse/releases/download/v2.0.0/SHA256SUMS
curl -fsSLO https://github.com/memhousehq/memhouse/releases/download/v2.0.0/memhouse-2.0.0-x86_64-unknown-linux-gnu.tar.gz
grep -F '  memhouse-2.0.0-x86_64-unknown-linux-gnu.tar.gz' SHA256SUMS | sha256sum -c -     # macOS: … | shasum -a 256 -c -
```

The `grep` picks the archive's own line, so the check fails when the list has no entry for it
(`--ignore-missing` would pass without checking anything). It must print the file name and `OK`.

**2. Signature** — the list was made by this repository's release workflow, for this tag.
Needs [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3 (the bundle
is in the format cosign 3 writes by default).

```bash
curl -fsSLO https://github.com/memhousehq/memhouse/releases/download/v2.0.0/SHA256SUMS.sigstore.json
cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "https://github.com/memhousehq/memhouse/.github/workflows/release.yml@refs/tags/v2.0.0" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

Each binary archive has its own bundle too (`<archive>.sigstore.json`), verified the same way.
[`install.sh`](../install.md#install-script) does steps 1 and 2 for you; step 2 only when
cosign is installed, or always with `--require-signature`.

**3. Provenance** — the file was built by that workflow, from that commit, on a GitHub-hosted
runner. Needs the [GitHub CLI](https://cli.github.com/).

```bash
gh attestation verify memhouse-2.0.0-x86_64-unknown-linux-gnu.tar.gz \
  --repo memhousehq/memhouse \
  --signer-workflow memhousehq/memhouse/.github/workflows/release.yml \
  --source-ref refs/tags/v2.0.0 --deny-self-hosted-runners
```

It works for any file in `SHA256SUMS` (wheels, npm packages, crates, the chart, the install
script). The attestation is also a release asset, `memhouse-2.0.0.provenance.sigstore.json`,
for checking without the GitHub API: add `--bundle memhouse-2.0.0.provenance.sigstore.json`.

## The container image

The image is signed by digest and carries its provenance in the registry. Resolve the tag to a
digest once, verify the digest, and deploy the digest.

```bash
cosign verify ghcr.io/memhousehq/memhouse:2.0.0 \
  --certificate-identity "https://github.com/memhousehq/memhouse/.github/workflows/release.yml@refs/tags/v2.0.0" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
# cosign prints the digest it verified ("docker-manifest-digest": "sha256:…"): every later
# step names the image by that digest, not by the tag, which could have moved in between.
DIGEST=sha256:…
gh attestation verify "oci://ghcr.io/memhousehq/memhouse@$DIGEST" --repo memhousehq/memhouse \
  --signer-workflow memhousehq/memhouse/.github/workflows/release.yml --source-ref refs/tags/v2.0.0
```

Deploy that digest: as `image.digest` in the [Helm chart](../install.md#kubernetes-helm), or as
`ghcr.io/memhousehq/memhouse@sha256:…`. The release pipeline never moves a version tag to
another digest; a digest cannot move at all.

## The Helm chart

The chart is pushed to the registry as an OCI artefact and signed by digest; the same file is
in `SHA256SUMS` as `memhouse-chart-<version>.tgz`.

```bash
cosign verify ghcr.io/memhousehq/charts/memhouse:2.0.0 \
  --certificate-identity "https://github.com/memhousehq/memhouse/.github/workflows/release.yml@refs/tags/v2.0.0" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

## Packages from registries

| Registry | Packages | What you can check |
|---|---|---|
| crates.io | `memhouse-core`, `-store-postgres`, `-store-sqlite`, `-models`, `-conformance`, `-server`, `-bench`, `-cli` | published by the release workflow through trusted publishing. The registry does not carry signatures; the `.crate` files the pipeline packed are in `SHA256SUMS` and covered by the provenance attestation |
| PyPI | `memhouse`, `memhouse-lite` | published through trusted publishing; the same files are in `SHA256SUMS` and covered by the provenance attestation (`gh attestation verify <file> …`). PyPI's own attestations (PEP 740) are not uploaded yet |
| npm | `@memhouse/sdk`, `@memhouse/lite` | published through trusted publishing, for which the registry records provenance: `npm audit signatures` in a project that depends on them; the tarballs are in `SHA256SUMS` |
| Homebrew | `memhousehq/tap/memhouse` | the formula names the release archives by SHA-256, taken from the signed `SHA256SUMS` |

## The software bill of materials

Two CycloneDX JSON documents are assets of every release:

| File | Describes | Made from |
|---|---|---|
| `memhouse-<version>-source.cdx.json` | every dependency a release artefact can contain, at its locked version: the Rust crates, and the SDKs' Python and npm dependencies | the lock files of the tagged commit (`Cargo.lock`, `uv.lock`, `pnpm-lock.yaml`), with [syft](https://github.com/anchore/syft) |
| `memhouse-<version>-image.cdx.json` | the container image: the packages of its base layers, and its files. The crates inside the binary are in the source SBOM, not here | the image archive that is pushed |

The source SBOM is attested for the binary archives:

```bash
gh attestation verify memhouse-2.0.0-x86_64-unknown-linux-gnu.tar.gz --repo memhousehq/memhouse \
  --predicate-type https://cyclonedx.org/bom
```

Feed either file to a scanner of your choice (for example `grype sbom:memhouse-2.0.0-source.cdx.json`).

## Dependencies and build inputs

- **Rust crates**: only from crates.io, permissive licences only, no known vulnerabilities
  ([`deny.toml`](../../deny.toml), with each exception and its reason); versions locked in
  `Cargo.lock` and built with `--locked`. Dependabot proposes updates weekly.
- **ONNX Runtime**: downloaded by the `ort-sys` build script at a fixed version and checked
  against its checksum; linked into the binary.
- **Model files**: not part of any artefact. Fetched at first use, at a revision and with
  SHA-256 checksums pinned in the binary, and checked again when loaded
  ([model files](../lite.md#model-files)).
- **Container base images**: pinned by digest in the [`Dockerfile`](../../Dockerfile).
- **GitHub Actions**: pinned to commit SHAs; the repository allows only GitHub's own actions,
  `dtolnay/rust-toolchain` and `taiki-e/install-action`.
- **Release tools** (cosign, syft, helm, shellcheck, actionlint): fixed versions with recorded
  SHA-256 checksums in `scripts/release/tools.sh`. uv, pnpm and maturin are installed at fixed
  versions from PyPI and npm.
- **TLS trust**: the binary uses the operating system's certificate store, never a bundled list.

## Limits

- The source SBOM is a superset of what one binary links: it lists every locked dependency of
  the workspace, including build and test dependencies. It errs on the side of reporting.
- Builds are not claimed to be bit-for-bit reproducible. Archives are packed
  deterministically (fixed order, owner and times), but the compiler's output is not verified
  to be identical across machines.
- The macOS binary is not signed with an Apple Developer ID or notarised.
- Release archives hold `LICENSE` and `NOTICE`; the licence texts of the linked third-party
  crates are not bundled yet (the SBOM names each one's licence).
- Sigstore's public transparency log records the signing identity (the workflow and tag) for
  every signature, including those of dry runs.

## Tool versions

Looked up on 27 November 2026; each is pinned where the table says.

| Tool | Version | Pinned in |
|---|---|---|
| cosign (Sigstore) | 3.1.6 | `scripts/release/tools.sh` |
| syft | 1.57.2 (CycloneDX JSON) | `scripts/release/tools.sh` |
| helm | 4.3.2 | `scripts/release/tools.sh` |
| shellcheck, actionlint | 0.11.0, 1.7.12 | `scripts/release/tools.sh` |
| `actions/attest` | v4.2.2 | `.github/workflows/release.yml` |
| uv, pnpm, maturin | 0.13.8, 12.18.0, 1.16.0 | `.github/workflows/release.yml` |
| npm for trusted publishing | 11.5.1 or newer, on Node 22.14 or newer (the workflow uses Node 24) | `.github/workflows/release.yml` |
