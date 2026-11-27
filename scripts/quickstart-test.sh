#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# The README's quickstart, run as written, in a clean container, against the clock (PROF-05:
# from nothing to the first recall in 10 minutes or less). Needs Docker.
#
#   scripts/quickstart-test.sh <memhouse-<version>-<linux target>.tar.gz>
#
# The archive is a Linux release archive of this tree (scripts/release/package.sh) for the
# architecture Docker runs. The commands are taken from README.md, between its
# `quickstart:begin` and `quickstart:end` markers: change the README and this test follows.
# One thing is substituted: the release is not downloaded from GitHub but from a web server
# beside the container, on its loopback address, serving that archive with its SHA256SUMS and
# this tree's install.sh (the mirror layout install.sh documents). The model download and the
# package installation are real.
#
# QUICKSTART_IMAGE picks the clean container (default: Debian 13 slim, pinned by digest);
# QUICKSTART_LIMIT the time allowed in seconds (default 600).
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: scripts/quickstart-test.sh <linux release archive>" >&2; exit 2; }
ARCHIVE=$1
IMAGE=${QUICKSTART_IMAGE:-debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0}
SERVER_IMAGE=${QUICKSTART_SERVER_IMAGE:-busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec}
LIMIT=${QUICKSTART_LIMIT:-600}
NAME=memhouse-quickstart-$$
WORK=$(mktemp -d)
cleanup() {
  docker rm -f "$NAME-web" "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() {
  printf 'quickstart-test: FAILED: %s\n' "$*" >&2
  exit 1
}

FILE=$(basename "$ARCHIVE")
VERSION=$(printf '%s' "$FILE" | sed -n -E 's/^memhouse-(.*)-(x86_64|aarch64)-unknown-linux-gnu\.tar\.gz$/\1/p')
[ -n "$VERSION" ] || fail "$FILE is not a Linux release archive (memhouse-<version>-<arch>-unknown-linux-gnu.tar.gz)"

# The release as a mirror serves it.
mkdir -p "$WORK/site/v$VERSION"
cp "$ARCHIVE" "$WORK/site/v$VERSION/$FILE"
cp install.sh "$WORK/site/install.sh"
cp install.sh "$WORK/site/v$VERSION/install.sh"
echo "$VERSION" >"$WORK/site/LATEST"
(cd "$WORK/site/v$VERSION" && for f in "$FILE" install.sh; do
  printf '%s  %s\n' "$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | cut -d' ' -f1; else shasum -a 256 "$f" | cut -d' ' -f1; fi)" "$f"
done >SHA256SUMS)

# The README's commands, as they are.
awk '/quickstart:begin/ { on = 1; next } /quickstart:end/ { on = 0 } on && !/^```/' README.md >"$WORK/readme-commands.sh"
grep -F "install.sh" "$WORK/readme-commands.sh" >/dev/null || fail "README.md has no quickstart between the quickstart:begin and quickstart:end markers"
grep -F "memhouse recall" "$WORK/readme-commands.sh" >/dev/null || fail "the README's quickstart ends before a recall"
MIRROR=http://127.0.0.1:8080
{
  echo "set -eu"
  # What the quickstart assumes of the machine: curl and CA certificates.
  echo "export DEBIAN_FRONTEND=noninteractive"
  echo "apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null"
  echo "export MEMHOUSE_RELEASE_BASE_URL=$MIRROR"
  sed "s|https://github.com/memhousehq/memhouse/releases/latest/download/install.sh|$MIRROR/install.sh|" "$WORK/readme-commands.sh"
} >"$WORK/site/quickstart.sh"
grep -F "$MIRROR/install.sh" "$WORK/site/quickstart.sh" >/dev/null || fail "the README's quickstart does not download install.sh from the latest release"

echo "== the quickstart, from README.md:"
sed 's/^/   /' "$WORK/readme-commands.sh"
echo "== in $IMAGE (limit ${LIMIT} s)"
docker run -d --name "$NAME-web" -v "$WORK/site:/site:ro" "$SERVER_IMAGE" httpd -f -p 127.0.0.1:8080 -h /site >/dev/null
START=$(date +%s)
# The same network namespace as the web server: its loopback address is the mirror's.
docker run -d --name "$NAME" --network "container:$NAME-web" -v "$WORK/site/quickstart.sh:/quickstart.sh:ro" "$IMAGE" sh /quickstart.sh >/dev/null
# The limit holds while the container runs: a download that hangs ends the test at the
# deadline, it does not hold it for ever.
while [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ]; do
  if [ $(($(date +%s) - START)) -gt "$LIMIT" ]; then
    docker logs "$NAME" 2>&1 | tail -40 >&2
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    fail "no first recall within the limit of ${LIMIT} s: the container was stopped"
  fi
  sleep 1
done
SECONDS_TAKEN=$(($(date +%s) - START))
docker logs "$NAME" >"$WORK/out" 2>&1
if [ "$(docker inspect -f '{{.State.ExitCode}}' "$NAME")" != 0 ]; then
  tail -40 "$WORK/out" >&2
  fail "the quickstart did not run to its end"
fi
tail -6 "$WORK/out" | sed 's/^/   /'
# The first recall returns the memory the quickstart stored.
REMEMBERED=$(sed -n 's/^memhouse remember "\([^"]*\)".*/\1/p' "$WORK/readme-commands.sh" | head -1)
[ -n "$REMEMBERED" ] || fail "the README's quickstart has no memhouse remember \"...\" line"
tail -12 "$WORK/out" | grep -F "$REMEMBERED" >/dev/null || fail "the recall did not return what was remembered ('$REMEMBERED')"
[ "$SECONDS_TAKEN" -le "$LIMIT" ] || fail "first recall after ${SECONDS_TAKEN} s: over the limit of ${LIMIT} s"
echo "quickstart-test: passed: first recall ${SECONDS_TAKEN} s after starting from a clean container (limit ${LIMIT} s)"
