#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# A release starts from a signed tag (RL-02). This checks, for <tag>:
#
#   1. it is an annotated tag signed with an SSH key listed in .github/release-signers, as that
#      file stands on the default branch (not as the tagged commit has it: whoever can push a
#      tag must not be able to bring their own list);
#   2. the commit it names is on the default branch (reviewed, with the required checks);
#   3. it is `v` and the product version of that commit.
#
#   scripts/release/verify-tag.sh <tag> [<default-branch-ref>]     # default origin/main
#
# Needs git 2.34 or newer (SSH signatures) and the repository's full history and tags.
set -eu
# shellcheck source=scripts/release/lib.sh
. "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || { echo "usage: scripts/release/verify-tag.sh <tag> [<default-branch-ref>]" >&2; exit 2; }
TAG=$1
MAIN=${2:-origin/main}
ROOT=$(release_root)
cd "$ROOT"
fail() {
  echo "verify-tag.sh: $*" >&2
  exit 1
}

[ "$(git cat-file -t "refs/tags/$TAG" 2>/dev/null)" = tag ] || fail "$TAG is not an annotated tag (sign one with: git tag -s $TAG -m 'MemHouse ${TAG#v}')"
SIGNERS=$(mktemp)
trap 'rm -f "$SIGNERS"' EXIT
git show "$MAIN:.github/release-signers" >"$SIGNERS" 2>/dev/null || fail "$MAIN has no .github/release-signers"
grep -v '^[[:space:]]*#' "$SIGNERS" | grep -q '[^[:space:]]' || fail ".github/release-signers on $MAIN lists no key: add the maintainers' public signing keys (docs/release.md)"
# Git picks the verifier from the signature itself: a tag signed another way (OpenPGP, X.509)
# would be checked against whatever keys this machine trusts, not against the list.
git cat-file tag "$TAG" | grep -x -e '-----BEGIN SSH SIGNATURE-----' >/dev/null || fail "$TAG is not signed with an SSH key (git config gpg.format ssh; docs/release.md)"
git -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$SIGNERS" verify-tag "$TAG" || fail "$TAG is not signed by a key in .github/release-signers of $MAIN"

COMMIT=$(git rev-parse "refs/tags/$TAG^{commit}")
git merge-base --is-ancestor "$COMMIT" "$MAIN" || fail "$TAG names $COMMIT, which is not on $MAIN"

VERSION=$(git show "$COMMIT:Cargo.toml" | sed -n '/^\[workspace\.package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' | head -1)
[ "$TAG" = "v$VERSION" ] || fail "$TAG does not name the product version of its commit ($VERSION)"
echo "verify-tag.sh: $TAG is signed by a listed key, on $MAIN, and names version $VERSION"
