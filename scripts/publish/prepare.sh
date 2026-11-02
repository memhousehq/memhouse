#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Build the publishable repositories from this private one (roadmap G09), without touching it:
#
#   1. a fresh clone, then git filter-repo: every path in private-paths.txt and republish-paths.txt
#      removed from every commit, every author and committer mapped to the public identity, the
#      private addresses and the private terms (PRIVATE_TERMS) replaced in file contents and
#      commit messages; then one last commit adds the paths in republish-paths.txt back as they
#      are at HEAD (their earlier versions held private planning material).
#      With HISTORY=fresh, one commit holding the current tree instead;
#   2. checks on the result: no private path, address or term anywhere in the history, the
#      full-history secret scan clean;
#   3. the memory-format repository split out of it, with its own history.
#
# Needs git-filter-repo (pip install git-filter-repo). Pushes nothing: forge-setup.sh does that.
#   scripts/publish/prepare.sh [publish.env]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1090
source "${1:-$here/publish.env}"
: "${PUBLIC_NAME:?}" "${PUBLIC_EMAIL:?}" "${HISTORY:?}" "${WORKDIR:?}" "${ORG:?}" "${REPO:?}" "${PRIVATE_TERMS:?}"
command -v git-filter-repo >/dev/null || { echo "git-filter-repo is not installed (pip install git-filter-repo)"; exit 1; }
case "$WORKDIR" in /*) work="$WORKDIR" ;; *) work="$src/$WORKDIR" ;; esac
case "$PRIVATE_TERMS" in /*) terms="$PRIVATE_TERMS" ;; *) terms="$src/$PRIVATE_TERMS" ;; esac
[ -f "$terms" ] || { echo "PRIVATE_TERMS file not found: $terms"; exit 1; }
paths() { grep -v -e '^#' -e '^$' "$here/$1" || true; }
for p in $(paths republish-paths.txt); do
  git -C "$src" diff --quiet HEAD -- "$p" || { echo "$p has uncommitted changes; commit them first"; exit 1; }
done

mono="$work/$REPO"
fmt="$work/memory-format"
rm -rf "$mono" "$fmt"
mkdir -p "$work"
as_public() { GIT_AUTHOR_NAME="$PUBLIC_NAME" GIT_AUTHOR_EMAIL="$PUBLIC_EMAIL" GIT_COMMITTER_NAME="$PUBLIC_NAME" GIT_COMMITTER_EMAIL="$PUBLIC_EMAIL" "$@"; }

# Every identity that ever committed here, and every private address we know of.
private_addresses=$(git -C "$src" log --all --format='%ae%n%ce' | sort -u)
private_addresses="$private_addresses"$'\n'"$(git -C "$src" log --all --format='%B' | sed -n 's/^Signed-off-by: .*<\(.*\)>$/\1/p' | sort -u)"
private_addresses=$(printf '%s\n' "$private_addresses" | grep -v -x -F "$PUBLIC_EMAIL" | grep -v 'noreply@anthropic.com' | sort -u | grep . || true)

echo "== 1. building the public history ($HISTORY)"
if [ "$HISTORY" = "fresh" ]; then
  mkdir -p "$mono"
  git -C "$src" archive --format=tar HEAD | tar -x -C "$mono"
  for p in $(paths private-paths.txt); do rm -rf "${mono:?}/$p"; done
  git -C "$mono" init -q -b main
  git -C "$mono" add -A
  as_public git -C "$mono" commit -q -m "MemHouse 2.0.0: first public commit" -m "Signed-off-by: $PUBLIC_NAME <$PUBLIC_EMAIL>"
else
  git clone -q --no-local "$src" "$mono"
  git -C "$mono" remote remove origin
  mailmap="$work/mailmap"
  replacements="$work/replacements"
  removed="$work/removed-paths"
  : > "$mailmap"
  : > "$replacements"
  while read -r a; do
    [ -n "$a" ] || continue
    printf '%s <%s> <%s>\n' "$PUBLIC_NAME" "$PUBLIC_EMAIL" "$a" >> "$mailmap"
    printf '%s==>%s\n' "$a" "$PUBLIC_EMAIL" >> "$replacements"
  done <<< "$private_addresses"
  # The local host name in old addresses, wherever it is quoted on its own.
  printf 'regex:@[A-Za-z0-9-]+\\.home\\b==>@localhost\n' >> "$replacements"
  grep -e '==>' "$terms" | grep -v '^#' >> "$replacements" || true
  { paths private-paths.txt; paths republish-paths.txt; } > "$removed"
  (cd "$mono" && git filter-repo --force --quiet \
    --invert-paths --paths-from-file "$removed" \
    --mailmap "$mailmap" \
    --replace-text "$replacements" \
    --replace-message "$replacements")
  republish=$(paths republish-paths.txt)
  if [ -n "$republish" ]; then
    for p in $republish; do
      mkdir -p "$mono/$(dirname "$p")"
      git -C "$src" show "HEAD:$p" > "$mono/$p"
      git -C "$mono" add "$p"
    done
    as_public git -C "$mono" commit -q -m "Publish the roadmap" \
      -m "Earlier versions of these files were working drafts with private planning material; they are published from this commit on: $(echo $republish)." \
      -m "Signed-off-by: $PUBLIC_NAME <$PUBLIC_EMAIL>"
  fi
fi

echo "== 2. checks"
fail=0
for p in $(paths private-paths.txt); do
  if [ -n "$(git -C "$mono" log --all --format=%h -- "$p" | head -1)" ]; then echo "  FAIL: $p is still in the history"; fail=1; fi
done
for p in $(paths republish-paths.txt); do
  n=$(git -C "$mono" log --all --format=%h -- "$p" | wc -l | tr -d ' ')
  [ "$n" -le 1 ] || { echo "  FAIL: $p has $n versions in the history (only the published one may remain)"; fail=1; }
done
everything=$(git -C "$mono" log --all -p --format='%an <%ae> %cn <%ce>%n%B')
while read -r a; do
  [ -n "$a" ] || continue
  if grep -q -F "$a" <<< "$everything"; then echo "  FAIL: $a is still in the history"; fail=1; fi
done <<< "$private_addresses"
while IFS= read -r line; do
  case "$line" in
    '#'*|'') continue ;;
    check:*) re="${line#check:}" ;;
    regex:*) continue ;;
    *==\>*) old="${line%%==>*}"; if grep -q -F "$old" <<< "$everything"; then echo "  FAIL: a private term is still in the history (line: ${old:0:3}...)"; fail=1; fi; continue ;;
    *) continue ;;
  esac
  if grep -q -i -E "$re" <<< "$everything"; then echo "  FAIL: a private term is still in the history (check: ${re:0:3}...)"; fail=1; fi
done < "$terms"
# Built from pieces, so this script doesn't match itself.
local_names="@[A-Za-z0-9-]+\\.ho""me\\b|/Us""ers/"
if grep -q -E "$local_names" <<< "$everything"; then echo "  FAIL: a local host name or home path is in the history"; fail=1; fi
authors=$(git -C "$mono" log --all --format='%an <%ae>%n%cn <%ce>' | sort -u)
echo "  identities in the public history:"; sed 's/^/    /' <<< "$authors"
(cd "$src" && cargo xtask secrets --repo "$mono" --history) || fail=1
[ "$fail" = 0 ] || { echo "checks failed; nothing is ready to publish"; exit 1; }
echo "  ok: no private path, address or term; secret scan clean ($(git -C "$mono" rev-list --count HEAD) commits)"

echo "== 3. splitting memory-format"
git clone -q --no-local "$mono" "$fmt"
git -C "$fmt" remote remove origin
(cd "$fmt" && git filter-repo --force --quiet \
  --path memory-format/ --path docs/memory-format.md \
  --path-rename memory-format/: --path-rename docs/memory-format.md:SPEC.md)
cp "$src/LICENSE" "$fmt/LICENSE"
cp "$src/docs/LICENSE" "$fmt/LICENSE-SPEC"
cp "$here/memory-format-README.md.tmpl" "$fmt/README.md"
sed -i.bak -e 's#(\.\./memory-format/vectors/#(vectors/#g' -e 's#(\.\./memory-format/vectors/manifest.json)#(vectors/manifest.json)#g' -e 's#(schema.md#(https://github.com/'"$ORG/$REPO"'/blob/main/docs/schema.md#g' "$fmt/SPEC.md"
rm -f "$fmt/SPEC.md.bak"
git -C "$fmt" add -A
as_public git -C "$fmt" commit -q -m "Stand-alone repository: licences, README, links" -m "Signed-off-by: $PUBLIC_NAME <$PUBLIC_EMAIL>"
echo "  $(git -C "$fmt" rev-list --count HEAD) commits; files: $(git -C "$fmt" ls-files | wc -l | tr -d ' ')"

echo
echo "Ready, not pushed:"
echo "  $mono"
echo "  $fmt"
echo "Next: run 'cargo xtask ci' in a fresh clone of $mono, then scripts/publish/forge-setup.sh."
