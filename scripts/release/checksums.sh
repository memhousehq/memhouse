#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Write <dir>/SHA256SUMS over every artefact in <dir> (not over itself, nor over signatures,
# which are made of it), in the format `sha256sum -c` and `shasum -a 256 -c` read.
#
#   scripts/release/checksums.sh <dir>
set -eu
# shellcheck source=scripts/release/lib.sh
. "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || { echo "usage: scripts/release/checksums.sh <dir>" >&2; exit 2; }
cd "$1"
: >SHA256SUMS.tmp
for f in $(find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' ! -name '*.sigstore.json' ! -name '.*' | sed 's|^\./||' | LC_ALL=C sort); do
  printf '%s  %s\n' "$(sha256_of "$f")" "$f" >>SHA256SUMS.tmp
done
[ -s SHA256SUMS.tmp ] || { echo "checksums.sh: no artefacts in $1" >&2; rm -f SHA256SUMS.tmp; exit 1; }
mv SHA256SUMS.tmp SHA256SUMS
echo "$(wc -l <SHA256SUMS | tr -d ' ') artefacts in $1/SHA256SUMS"
