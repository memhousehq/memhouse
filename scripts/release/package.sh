#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Pack one built binary into its release archive:
#
#   scripts/release/package.sh <binary> <target> <out-dir>
#
# writes <out-dir>/memhouse-<version>-<target>.tar.gz holding
# memhouse-<version>-<target>/{memhouse,LICENSE,NOTICE,README.md,CHANGELOG.md}.
# File times are the commit's and the owner is root, so the archive depends only on its
# contents. When the binary runs on this machine, its `--version` must be the product version.
set -eu
# shellcheck source=scripts/release/lib.sh
. "$(dirname "$0")/lib.sh"

[ $# -eq 3 ] || { echo "usage: scripts/release/package.sh <binary> <target> <out-dir>" >&2; exit 2; }
BINARY=$1 TARGET=$2 OUT=$3
ROOT=$(release_root)
VERSION=$(release_version "$ROOT")
[ -f "$BINARY" ] || { echo "package.sh: $BINARY: no such file" >&2; exit 1; }

# A binary of another platform cannot be asked; one of this platform must agree.
if REPORTED=$("$BINARY" --version 2>/dev/null); then
  [ "$REPORTED" = "memhouse $VERSION" ] || { echo "package.sh: $BINARY reports '$REPORTED', the product version is $VERSION" >&2; exit 1; }
fi

NAME="memhouse-$VERSION-$TARGET"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$NAME" "$OUT"
cp "$BINARY" "$WORK/$NAME/memhouse"
chmod 0755 "$WORK/$NAME/memhouse"
for f in LICENSE NOTICE README.md CHANGELOG.md; do
  cp "$ROOT/$f" "$WORK/$NAME/$f"
  chmod 0644 "$WORK/$NAME/$f"
done
EPOCH=$(release_epoch "$ROOT")
# touch -d @N is GNU, -r needs a file: set the time through a reference file made by either.
STAMP=$(date -u -r "$EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$EPOCH" +%Y%m%d%H%M.%S)
find "$WORK/$NAME" -exec env TZ=UTC touch -t "$STAMP" {} +
OUT=$(cd "$OUT" && pwd)
if tar --version 2>/dev/null | grep -q GNU; then
  (cd "$WORK" && tar --sort=name --owner=0 --group=0 --numeric-owner -cf - "$NAME") | gzip -n -9 >"$OUT/$NAME.tar.gz"
else
  (cd "$WORK" && find "$NAME" -print | LC_ALL=C sort | tar --uid 0 --gid 0 --uname root --gname root -n -cf - -T -) | gzip -n -9 >"$OUT/$NAME.tar.gz"
fi
echo "$OUT/$NAME.tar.gz"
