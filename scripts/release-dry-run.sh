#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# A release dry run on this machine (roadmap G21): every artefact the release workflow makes
# that this machine can make, with the same scripts and the same pinned tools, into dist/.
# Nothing is published, pushed, tagged or signed.
#
#   scripts/release-dry-run.sh [--linux-binary <path>] [--skip <part>]...
#
# Parts, in order (skip any with --skip): binary crates python-sdk python-binding
# typescript-sdk node-binding chart site image sbom.
#   --linux-binary <path>   a `memhouse` built for Linux on Docker's architecture (for example
#                           `docker build --target binary --output type=local,dest=out .`): it
#                           is packed as that target's archive and, unless `image` is skipped,
#                           put into a container image for that one architecture
#
# What differs from the workflow (.github/workflows/release.yml), which is the release:
# - one platform: the host's archive, wheel and addon (the workflow builds three);
# - no signatures and no provenance: both come from the workflow's OIDC identity, which does
#   not exist here (scripts/release/sign.sh refuses to run outside a workflow);
# - the Homebrew formula is written only when all three archives are present.
# Needs: cargo, uv, pnpm, node, and for `image` Docker. helm and syft are downloaded at their
# pinned versions into dist/.tools (scripts/release/tools.sh). Heavy: it compiles the workspace
# several times (the release binary, `cargo package`'s verification build, the two bindings).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/release/lib.sh
. scripts/release/lib.sh

LINUX_BINARY=
SKIP=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --linux-binary) LINUX_BINARY=$2; shift 2 ;;
    --skip) SKIP="$SKIP$2 "; shift 2 ;;
    *) echo "usage: scripts/release-dry-run.sh [--linux-binary <path>] [--skip <part>]..." >&2; exit 2 ;;
  esac
done
runs() { case "$SKIP" in *" $1 "*) return 1 ;; *) return 0 ;; esac; }
step() { printf '\n== %s\n' "$*"; }

ROOT=$PWD
VERSION=$(release_version "$ROOT")
DIST=$ROOT/dist
MATURIN_VERSION=1.16.0
rm -rf "$DIST/release"
mkdir -p "$DIST/release" "$DIST/.tools"
OUT=$DIST/release
export PATH="$DIST/.tools:$PATH"

step "version $VERSION in every place"
cargo xtask version

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) HOST_TARGET=x86_64-unknown-linux-gnu ;;
  Linux-aarch64) HOST_TARGET=aarch64-unknown-linux-gnu ;;
  Darwin-arm64) HOST_TARGET=aarch64-apple-darwin ;;
  *) echo "release-dry-run: no release target for this machine" >&2; exit 1 ;;
esac
case "$(docker version --format '{{.Server.Arch}}' 2>/dev/null || true)" in
  amd64 | x86_64) DOCKER_ARCH=amd64 LINUX_TARGET=x86_64-unknown-linux-gnu ;;
  arm64 | aarch64) DOCKER_ARCH=arm64 LINUX_TARGET=aarch64-unknown-linux-gnu ;;
  *) DOCKER_ARCH='' LINUX_TARGET='' ;;
esac

if runs binary; then
  step "binary archive ($HOST_TARGET)"
  cargo build --release --locked -p memhouse-cli
  scripts/release/package.sh target/release/memhouse "$HOST_TARGET" "$OUT"
  if [ -n "$LINUX_BINARY" ]; then
    [ -n "$LINUX_TARGET" ] || { echo "release-dry-run: --linux-binary needs Docker to say which architecture it is for" >&2; exit 1; }
    scripts/release/package.sh "$LINUX_BINARY" "$LINUX_TARGET" "$OUT"
  fi
  cp install.sh "$OUT/install.sh"
fi

if runs crates; then
  # Packs the eight crates and builds each from its packed form, later ones against the
  # earlier ones' packages: what `cargo publish --workspace` would upload, in its order.
  step "crates (cargo package, verified)"
  cargo package --workspace --exclude xtask --exclude memhouse-lite-python --exclude memhouse-lite-node --locked --allow-dirty
  cp target/package/memhouse-*-"$VERSION".crate "$OUT/"
fi

if runs python-sdk; then
  step "Python SDK (sdist and wheel)"
  uv build --out-dir "$OUT" sdk/python
fi

if runs python-binding; then
  step "Python binding (abi3 wheel, $HOST_TARGET)"
  (cd bindings/python && uvx --from "maturin==$MATURIN_VERSION" maturin build --profile bindings --locked --out "$OUT")
fi

if runs typescript-sdk; then
  step "TypeScript SDK (npm pack)"
  (cd sdk/typescript && pnpm install --frozen-lockfile && pnpm build && npm pack --pack-destination "$OUT")
fi

if runs node-binding; then
  step "Node.js binding (addon for $HOST_TARGET, npm pack)"
  (cd bindings/node && pnpm install --frozen-lockfile && pnpm build && npm pack --pack-destination "$OUT")
fi

if runs chart; then
  step "Helm chart"
  scripts/release/tools.sh "$DIST/.tools" helm
  scripts/helm-check.sh
  helm package deploy/helm/memhouse --destination "$OUT"
  mv "$OUT/memhouse-$VERSION.tgz" "$OUT/memhouse-chart-$VERSION.tgz"
fi

if runs site; then
  step "documentation site"
  cargo xtask site --out "$DIST/site" --ref "v$VERSION"
  tar -czf "$OUT/memhouse-docs-$VERSION.tar.gz" -C "$DIST" site
fi

IMAGE_TAR=
if runs image && [ -n "$LINUX_BINARY" ]; then
  step "container image (linux/$DOCKER_ARCH, from the packed binary)"
  mkdir -p "dist/linux-$DOCKER_ARCH"
  cp "$LINUX_BINARY" "dist/linux-$DOCKER_ARCH/memhouse"
  IMAGE_TAR="$OUT/memhouse-$VERSION-image.oci.tar"
  docker buildx build --platform "linux/$DOCKER_ARCH" --build-arg BINARY_STAGE=prebuilt \
    --build-arg VERSION="$VERSION" --build-arg REVISION="$(git rev-parse HEAD)" \
    --build-arg CREATED="$(date -u -r "$(release_epoch "$ROOT")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(release_epoch "$ROOT")" +%Y-%m-%dT%H:%M:%SZ)" \
    --output "type=oci,dest=$IMAGE_TAR" .
fi

if runs sbom; then
  step "SBOM (CycloneDX JSON, syft)"
  scripts/release/tools.sh "$DIST/.tools" syft
  scripts/release/sbom.sh source "$OUT"
  if [ -n "$IMAGE_TAR" ]; then scripts/release/sbom.sh image "$IMAGE_TAR" "$OUT"; fi
fi

step "checksums"
scripts/release/checksums.sh "$OUT"
(cd "$OUT" && if command -v sha256sum >/dev/null 2>&1; then sha256sum -c --quiet SHA256SUMS; else shasum -a 256 -c SHA256SUMS >/dev/null; fi)
if scripts/release/homebrew.sh "$OUT" "$DIST/memhouse.rb" 2>/dev/null; then
  mv "$DIST/memhouse.rb" "$OUT/memhouse.rb" && scripts/release/checksums.sh "$OUT" >/dev/null
else
  echo "Homebrew formula: not written (it needs the archives of all three targets; this run has $(find "$OUT" -name 'memhouse-*-*-*.tar.gz' | wc -l | tr -d ' '))"
fi

step "artefacts in dist/release"
(cd "$OUT" && for f in *; do printf '  %10s  %s\n' "$(wc -c <"$f" | tr -d ' ')" "$f"; done)
echo
echo "release-dry-run: $(wc -l <"$OUT/SHA256SUMS" | tr -d ' ') artefacts with checksums; not signed, not published (see the header of this script)"
