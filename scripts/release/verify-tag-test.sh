#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests of scripts/release/verify-tag.sh in a throwaway repository, with signing keys made
# for the run and deleted with it. Needs git 2.34 or newer and ssh-keygen.
#
#   scripts/release/verify-tag-test.sh
#
# Accepted: an annotated tag signed by a listed key, on main, naming the version. Refused: a
# lightweight tag, an unsigned one, one signed by a key that is not listed (also when the
# tagged commit lists it itself), one whose commit is not on main, one that names another
# version, and any tag while the list on main is empty.
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() {
  printf 'verify-tag-test: FAILED: %s\n' "$*" >&2
  exit 1
}

ssh-keygen -q -t ed25519 -N '' -C maintainer -f "$WORK/listed"
ssh-keygen -q -t ed25519 -N '' -C stranger -f "$WORK/other"

REPO=$WORK/repo
mkdir -p "$REPO/scripts/release" "$REPO/.github"
cp "$SRC/verify-tag.sh" "$SRC/lib.sh" "$REPO/scripts/release/"
cd "$REPO"
git init -q -b main
git config user.name tester
git config user.email tester@example.test
git config gpg.format ssh
git config commit.gpgsign false
git config tag.gpgsign false
sign_with() { git config user.signingkey "$WORK/$1.pub"; }
commit() { git add -A && git commit -q -m "$1"; }
main_is_here() { git update-ref refs/remotes/origin/main HEAD; }
check() { scripts/release/verify-tag.sh "$1" >"$WORK/out" 2>&1; }
accepted() { check "$1" || { cat "$WORK/out" >&2; fail "$2: refused"; }; }
refused() { # <tag> <what> <text the refusal must hold>
  if check "$1"; then fail "$2: accepted"; fi
  grep -F -- "$3" "$WORK/out" >/dev/null || { cat "$WORK/out" >&2; fail "$2: refused for another reason"; }
}

printf '[workspace.package]\nversion = "1.2.3"\n\n[workspace.dependencies]\n' >Cargo.toml
printf '# no keys yet\n' >.github/release-signers
commit "version 1.2.3, no signers"
main_is_here
sign_with listed
git tag -s v1.2.3 -m "1.2.3"
refused v1.2.3 "an empty list of signers" "lists no key"

printf 'tester@example.test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/listed.pub")" >.github/release-signers
commit "list the maintainer's key"
main_is_here
git tag -d v1.2.3 >/dev/null
git tag -s v1.2.3 -m "1.2.3"
accepted v1.2.3 "a tag signed by a listed key"

git tag light-v1.2.3
refused light-v1.2.3 "a lightweight tag" "not an annotated tag"
git tag -a v1.2.3-unsigned -m unsigned
refused v1.2.3-unsigned "an unsigned tag" "not signed with an SSH key"
# A signature of another kind is refused before any verifier this machine has is asked.
git tag -a v1.2.3-pgp -m "pgp
-----BEGIN PGP SIGNATURE-----

wsBcBAABCAAQBQJnxxxx
-----END PGP SIGNATURE-----"
refused v1.2.3-pgp "a tag signed with OpenPGP" "not signed with an SSH key"
# An SSH marker in the message does not make an OpenPGP signature an SSH one.
git tag -a v1.2.3-mixed -m "mixed
-----BEGIN SSH SIGNATURE-----
AAAA
-----END SSH SIGNATURE-----
-----BEGIN PGP SIGNATURE-----

wsBcBAABCAAQBQJnxxxx
-----END PGP SIGNATURE-----"
refused v1.2.3-mixed "an OpenPGP signature behind an SSH marker in the message" "not signed with an SSH key"
git tag -s v9.9.9 -m "9.9.9"
refused v9.9.9 "a tag that names another version" "does not name the product version"

sign_with other
git tag -d v1.2.3 >/dev/null
git tag -s v1.2.3 -m "1.2.3"
refused v1.2.3 "a tag signed by an unlisted key" "not signed by a key"

# The stranger adds their own key in the commit they tag: the list is read from main.
git switch -q -c elsewhere
printf 'tester@example.test namespaces="git" %s\n' "$(cut -d' ' -f1,2 "$WORK/other.pub")" >>.github/release-signers
commit "add my own key"
git tag -d v1.2.3 >/dev/null
git tag -s v1.2.3 -m "1.2.3"
refused v1.2.3 "a tag whose commit brings its own signer" "not signed by a key"

# A listed key, but a commit that is not on main.
sign_with listed
git tag -d v1.2.3 >/dev/null
git tag -s v1.2.3 -m "1.2.3"
refused v1.2.3 "a tagged commit that is not on main" "not on origin/main"

echo "verify-tag-test: all checks passed"
