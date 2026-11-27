#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# "A release produces every artefact": the list, and a check of a directory against it.
#
#   scripts/release/complete.sh <dir> [--signed]
#
# Fails, naming each one, when an artefact of the release is missing from <dir> or from its
# SHA256SUMS. With --signed, the Sigstore bundles and the attestation bundles must be there too.
set -eu
# shellcheck source=scripts/release/lib.sh
. "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || { echo "usage: scripts/release/complete.sh <dir> [--signed]" >&2; exit 2; }
DIR=$1
SIGNED=${2:-}
ROOT=$(release_root)
V=$(release_version "$ROOT")
# The version as Python packaging spells it (2.1.0-rc.1 is 2.1.0rc1).
PV=$(printf '%s' "$V" | sed -e 's/-alpha\./a/' -e 's/-beta\./b/' -e 's/-rc\./rc/')
MISSING=0
want() { # <file name> [unlisted]: present, and unless told otherwise, in SHA256SUMS
  if [ ! -f "$DIR/$1" ]; then
    echo "complete.sh: missing $1" >&2
    MISSING=$((MISSING + 1))
  elif [ "${2:-}" != unlisted ] && ! awk -v f="$1" '$2 == f { found = 1 } END { exit !found }' "$DIR/SHA256SUMS"; then
    echo "complete.sh: $1 is not in SHA256SUMS" >&2
    MISSING=$((MISSING + 1))
  fi
}

TARGETS="x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu aarch64-apple-darwin"
want SHA256SUMS unlisted
for t in $TARGETS; do want "memhouse-$V-$t.tar.gz"; done
want install.sh
want memhouse.rb
want RELEASE_NOTES.md
for c in core store-postgres store-sqlite models conformance server bench cli; do want "memhouse-$c-$V.crate"; done
want "memhouse-$PV.tar.gz"
want "memhouse-$PV-py3-none-any.whl"
want "memhouse-sdk-$V.tgz"
want "memhouse-lite-$V.tgz"
want "memhouse-chart-$V.tgz"
want "memhouse-docs-$V.tar.gz"
want "memhouse-$V-source.cdx.json"
want "memhouse-$V-image.cdx.json"
# One wheel of the binding per target; their platform tags are the builder's to choose.
WHEELS=$(find "$DIR" -maxdepth 1 -name "memhouse_lite-$PV-cp39-abi3-*.whl" | wc -l | tr -d ' ')
if [ "$WHEELS" != 3 ]; then
  echo "complete.sh: $WHEELS wheel(s) of memhouse_lite $PV, expected 3 (two Linux, one macOS)" >&2
  MISSING=$((MISSING + 1))
fi
if [ "$SIGNED" = --signed ]; then
  want SHA256SUMS.sigstore.json unlisted
  for t in $TARGETS; do want "memhouse-$V-$t.tar.gz.sigstore.json" unlisted; done
  want "memhouse-$V.provenance.sigstore.json" unlisted
  want "memhouse-$V.sbom.sigstore.json" unlisted
fi
[ "$MISSING" = 0 ] || { echo "complete.sh: $MISSING artefact(s) missing from $DIR" >&2; exit 1; }
echo "complete.sh: every artefact of $V is in $DIR${SIGNED:+, with its signatures}"
