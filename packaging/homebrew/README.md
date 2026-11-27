<!-- SPDX-License-Identifier: Apache-2.0 -->
# Homebrew formula

`memhouse.rb.in` is the template of the formula `memhousehq/tap/memhouse`. The release pipeline
fills it with the version and the SHA-256 of the three binary archives, read from the release's
`SHA256SUMS`, and attaches the result to the GitHub release as `memhouse.rb`:

```bash
scripts/release/homebrew.sh <directory with SHA256SUMS> memhouse.rb
```

The script fails if an archive is missing from `SHA256SUMS`, so a formula never names a
download it has no checksum for.

## The tap

The tap is its own repository, `memhousehq/homebrew-tap`, holding `Formula/memhouse.rb`. The
release workflow of this repository does not push to it: that would need a stored token for
another repository, and the pipeline holds none. Instead the tap takes the formula from the
release, either by hand:

```bash
curl -fsSL -o Formula/memhouse.rb https://github.com/memhousehq/memhouse/releases/latest/download/memhouse.rb
git commit -s -am "memhouse <version>" && git push
```

or with a scheduled workflow in the tap that does the same with the tap's own token
([release.md](../../docs/release.md#one-time-setup) lists it among the maintainer's steps).
Before committing, check the formula against the signed checksums
([supply chain](../../docs/security/supply-chain.md#verify-a-download)).

## What the formula does

It installs the prebuilt `memhouse` binary for macOS on Apple silicon and for Linux on x86_64
and arm64, with the README, the changelog and the notice. A formula rather than a cask: a
formula's download is not quarantined by macOS, and the binary is not notarised. There is no
release binary for Intel Macs ([platforms](../../docs/install.md#platforms)).

The template has not been installed through Homebrew yet: the tap does not exist, and no
release has been published. `ruby -c` accepts the generated file; `brew audit --strict` and
`brew test` on the first real formula are part of the first release.
