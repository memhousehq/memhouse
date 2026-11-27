#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Write the Homebrew formula of a release from its checksums:
#
#   scripts/release/homebrew.sh <dir-with-SHA256SUMS> <out-file>
#
# Fills packaging/homebrew/memhouse.rb.in with the product version and the SHA-256 of the three
# binary archives, read from SHA256SUMS (the file the release signs). Fails if an archive is
# missing from it, so a formula never names a download it has no checksum for.
set -eu
# shellcheck source=scripts/release/lib.sh
. "$(dirname "$0")/lib.sh"

[ $# -eq 2 ] || { echo "usage: scripts/release/homebrew.sh <dir-with-SHA256SUMS> <out-file>" >&2; exit 2; }
SUMS="$1/SHA256SUMS"
OUT=$2
ROOT=$(release_root)
VERSION=$(release_version "$ROOT")
[ -f "$SUMS" ] || { echo "homebrew.sh: $SUMS is missing" >&2; exit 1; }

sum_of() {
  awk -v f="memhouse-$VERSION-$1.tar.gz" '$2 == f { print $1 }' "$SUMS"
}
MAC_ARM=$(sum_of aarch64-apple-darwin)
LINUX_ARM=$(sum_of aarch64-unknown-linux-gnu)
LINUX_X86=$(sum_of x86_64-unknown-linux-gnu)
for pair in "aarch64-apple-darwin:$MAC_ARM" "aarch64-unknown-linux-gnu:$LINUX_ARM" "x86_64-unknown-linux-gnu:$LINUX_X86"; do
  [ -n "${pair#*:}" ] || { echo "homebrew.sh: $SUMS has no memhouse-$VERSION-${pair%%:*}.tar.gz" >&2; exit 1; }
done
sed -e "s/@VERSION@/$VERSION/g" \
  -e "s/@SHA256_AARCH64_APPLE_DARWIN@/$MAC_ARM/" \
  -e "s/@SHA256_AARCH64_UNKNOWN_LINUX_GNU@/$LINUX_ARM/" \
  -e "s/@SHA256_X86_64_UNKNOWN_LINUX_GNU@/$LINUX_X86/" \
  "$ROOT/packaging/homebrew/memhouse.rb.in" >"$OUT"
if grep -q '@[A-Z0-9_]*@' "$OUT"; then
  echo "homebrew.sh: $OUT still holds a placeholder" >&2
  exit 1
fi
echo "$OUT"
