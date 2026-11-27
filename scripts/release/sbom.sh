#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Software bills of materials (SC-01, TR-OPS-03), CycloneDX JSON, made with syft
# (scripts/release/tools.sh installs the pinned version):
#
#   scripts/release/sbom.sh source <out-dir>               # memhouse-<version>-source.cdx.json
#   scripts/release/sbom.sh image <oci-archive> <out-dir>  # memhouse-<version>-image.cdx.json
#
# `source` reads the lock files of the tree being released (Cargo.lock, the SDKs' uv.lock and
# pnpm-lock.yaml): every dependency a release artefact can contain, at its locked version. It
# is a superset of what one binary links (it includes build and test dependencies), which is
# the safe direction for a vulnerability scan. `image` reads the image itself: the packages of
# its base layers and the binary.
set -eu
# shellcheck source=scripts/release/lib.sh
. "$(dirname "$0")/lib.sh"

ROOT=$(release_root)
VERSION=$(release_version "$ROOT")
command -v syft >/dev/null 2>&1 || { echo "sbom.sh: syft is not on PATH (scripts/release/tools.sh <dir> syft)" >&2; exit 1; }
export SYFT_CHECK_FOR_APP_UPDATE=false

case "${1:-}" in
  source)
    [ $# -eq 2 ] || { echo "usage: scripts/release/sbom.sh source <out-dir>" >&2; exit 2; }
    mkdir -p "$2"
    OUT="$(cd "$2" && pwd)/memhouse-$VERSION-source.cdx.json"
    # Lock files only: build outputs and installed dependency trees are not what is released.
    (cd "$ROOT" && syft scan dir:. --source-name memhouse --source-version "$VERSION" \
      --exclude './target' --exclude './dist' --exclude './.dev-home' --exclude './bench-results' --exclude './bench-data' \
      --exclude '**/node_modules' --exclude '**/.venv' --exclude './.git' --exclude './.claude' \
      -q -o "cyclonedx-json=$OUT")
    ;;
  image)
    [ $# -eq 3 ] || { echo "usage: scripts/release/sbom.sh image <oci-archive> <out-dir>" >&2; exit 2; }
    mkdir -p "$3"
    OUT="$(cd "$3" && pwd)/memhouse-$VERSION-image.cdx.json"
    syft scan "oci-archive:$2" --source-name memhouse-image --source-version "$VERSION" -q -o "cyclonedx-json=$OUT"
    ;;
  *)
    echo "usage: scripts/release/sbom.sh source <out-dir> | image <oci-archive> <out-dir>" >&2
    exit 2
    ;;
esac
# An SBOM without components would pass every later step and say nothing. The `components`
# array is counted, not every `bom-ref`: the document's own metadata has one too.
COMPONENTS=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1])).get("components") or []))' "$OUT")
[ "$COMPONENTS" -gt 0 ] || { echo "sbom.sh: $OUT lists no components" >&2; exit 1; }
echo "$OUT ($COMPONENTS components)"
