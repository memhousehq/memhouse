#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Install the MemHouse binary from a release.
#
#   sh install.sh                       # the latest release, into ~/.local/bin
#   sh install.sh --version 2.0.0       # that release
#   sh install.sh --dir /usr/local/bin  # another directory (must be writable: no sudo is run)
#   sh install.sh --dry-run             # say what would be downloaded and installed, change nothing
#   sh install.sh --require-signature   # refuse to install unless cosign verified the release
#
# What it does, in order: picks the archive for this machine, downloads the release's
# SHA256SUMS and the archive into a temporary directory, verifies the Sigstore signature of
# SHA256SUMS when `cosign` is installed (docs/security/supply-chain.md), verifies the archive's
# SHA-256 against SHA256SUMS, and only then unpacks it and copies the one binary into place.
# Nothing that was downloaded is executed, and nothing is installed unless its checksum matched.
#
# Environment: MEMHOUSE_VERSION, MEMHOUSE_INSTALL_DIR (as the options above), and
# MEMHOUSE_RELEASE_BASE_URL for a mirror that serves <base>/v<version>/<file> and <base>/LATEST.
set -eu

REPO="memhousehq/memhouse"
GITHUB="https://github.com/$REPO"
BASE_URL=${MEMHOUSE_RELEASE_BASE_URL:-}
VERSION=${MEMHOUSE_VERSION:-}
DIR=${MEMHOUSE_INSTALL_DIR:-}
DRY_RUN=0
REQUIRE_SIGNATURE=0

say() { printf '%s\n' "$*"; }
fail() {
  printf 'install.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || fail "--version needs a value"
      VERSION=$2
      shift 2
      ;;
    --dir)
      [ $# -ge 2 ] || fail "--dir needs a value"
      DIR=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --require-signature)
      REQUIRE_SIGNATURE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "unknown option '$1' (see --help)" ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is needed and was not found"; }
need uname
need tar
need mktemp

if command -v curl >/dev/null 2>&1; then
  # A plain-http base is accepted only for a loopback mirror (the script's own test).
  fetch() { curl --proto '=https,http' -fsSL --retry 3 -o "$2" "$1"; }
  effective_url() { curl --proto '=https' -fsSLI -o /dev/null -w '%{url_effective}' "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
  effective_url() { wget -q -S --spider "$1" 2>&1 | sed -n 's/^ *Location: *//p' | tail -1 | tr -d '\r'; }
else
  fail "curl or wget is needed and neither was found"
fi

if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  fail "sha256sum or shasum is needed and neither was found"
fi

# The archive for this machine. Release archives exist for the three targets below; anywhere
# else, build from source (docs/install.md).
OS=$(uname -s)
ARCH=$(uname -m)
case "$OS" in
  Linux)
    if (ldd --version 2>&1 || true) | grep -qi musl; then
      fail "this system uses musl libc; the release binaries need glibc 2.39 or newer. Use the container image, or build from source (docs/install.md)"
    fi
    # The binaries link the C++ runtime of GCC 13 and glibc 2.39 (Ubuntu 24.04, Debian 13).
    GLIBC=$(getconf GNU_LIBC_VERSION 2>/dev/null | cut -d' ' -f2 || true)
    case "$GLIBC" in
      [0-9]*.[0-9]*)
        GLIBC_MINOR=${GLIBC#*.}
        if [ "${GLIBC%%.*}" -lt 2 ] || { [ "${GLIBC%%.*}" -eq 2 ] && [ "${GLIBC_MINOR%%.*}" -lt 39 ]; }; then
          fail "this system has glibc $GLIBC; the release binaries need 2.39 or newer (Ubuntu 24.04, Debian 13). Use the container image, or build from source (docs/install.md)"
        fi
        ;;
    esac
    case "$ARCH" in
      x86_64 | amd64) TARGET=x86_64-unknown-linux-gnu ;;
      aarch64 | arm64) TARGET=aarch64-unknown-linux-gnu ;;
      *) fail "no release binary for Linux on $ARCH; build from source (docs/install.md)" ;;
    esac
    ;;
  Darwin)
    case "$ARCH" in
      arm64) TARGET=aarch64-apple-darwin ;;
      *) fail "no release binary for macOS on $ARCH (the bundled ONNX Runtime has no build for it); build from source (docs/install.md)" ;;
    esac
    ;;
  *) fail "no release binary for $OS; build from source, or use the container image (docs/install.md)" ;;
esac

case "$BASE_URL" in
  "") BASE_URL="$GITHUB/releases/download" MIRROR=0 ;;
  https://* | http://127.0.0.1[:/]* | http://localhost[:/]* | http://\[::1\][:/]*) MIRROR=1 ;;
  *) fail "MEMHOUSE_RELEASE_BASE_URL must be an https URL (plain http only for a loopback address)" ;;
esac
BASE_URL=${BASE_URL%/}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

if [ -z "$VERSION" ]; then
  if [ "$MIRROR" = 1 ]; then
    fetch "$BASE_URL/LATEST" "$WORK/LATEST" || fail "cannot read $BASE_URL/LATEST; name a release with --version"
    VERSION=$(tr -d ' \r\n' <"$WORK/LATEST")
  else
    # GitHub redirects /releases/latest to /releases/tag/v<version>.
    LATEST=$(effective_url "$GITHUB/releases/latest") || fail "cannot find the latest release at $GITHUB/releases/latest; name one with --version"
    VERSION=${LATEST##*/tag/}
  fi
fi
VERSION=${VERSION#v}
# A version is digits, dots and a pre-release suffix: it goes into URLs and file names.
case "$VERSION" in
  "" | *[!0-9A-Za-z.-]* | [!0-9]*) fail "'$VERSION' is not a release version (expected something like 2.0.0)" ;;
esac

if [ -z "$DIR" ]; then
  [ -n "${HOME:-}" ] || fail "HOME is not set; name the directory with --dir"
  DIR="$HOME/.local/bin"
fi

ARCHIVE="memhouse-$VERSION-$TARGET.tar.gz"
RELEASE_URL="$BASE_URL/v$VERSION"

if [ "$DRY_RUN" = 1 ]; then
  say "Would install MemHouse $VERSION ($TARGET):"
  say "  download  $RELEASE_URL/SHA256SUMS"
  say "  download  $RELEASE_URL/SHA256SUMS.sigstore.json  (verified when cosign is installed)"
  say "  download  $RELEASE_URL/$ARCHIVE"
  say "  install   $DIR/memhouse"
  say "Nothing was downloaded or changed."
  exit 0
fi

say "MemHouse $VERSION for $TARGET"
fetch "$RELEASE_URL/SHA256SUMS" "$WORK/SHA256SUMS" || fail "cannot download $RELEASE_URL/SHA256SUMS (is $VERSION a release?)"

# The signature says the checksum file was made by the project's release workflow for this tag.
IDENTITY="$GITHUB/.github/workflows/release.yml@refs/tags/v$VERSION"
if command -v cosign >/dev/null 2>&1; then
  fetch "$RELEASE_URL/SHA256SUMS.sigstore.json" "$WORK/SHA256SUMS.sigstore.json" || fail "cannot download the signature $RELEASE_URL/SHA256SUMS.sigstore.json"
  cosign verify-blob "$WORK/SHA256SUMS" --bundle "$WORK/SHA256SUMS.sigstore.json" \
    --certificate-identity "$IDENTITY" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" >/dev/null 2>"$WORK/cosign.log" ||
    {
      cat "$WORK/cosign.log" >&2
      fail "the signature of SHA256SUMS did not verify: nothing was installed"
    }
  say "  signature: SHA256SUMS was signed by the release workflow at v$VERSION (cosign)"
elif [ "$REQUIRE_SIGNATURE" = 1 ]; then
  fail "--require-signature: cosign is not installed (https://docs.sigstore.dev/cosign/system_config/installation/); nothing was installed"
else
  say "  signature: not checked (cosign is not installed); the checksum below shows the download is intact, not who made it"
fi

fetch "$RELEASE_URL/$ARCHIVE" "$WORK/$ARCHIVE" || fail "cannot download $RELEASE_URL/$ARCHIVE"
# The line of SHA256SUMS for this archive: "<sha256>  <file>".
WANT=$(awk -v f="$ARCHIVE" '$2 == f || $2 == "*" f { print $1 }' "$WORK/SHA256SUMS")
[ -n "$WANT" ] || fail "SHA256SUMS has no entry for $ARCHIVE: nothing was installed"
HAVE=$(sha256_of "$WORK/$ARCHIVE")
[ "$HAVE" = "$WANT" ] || fail "checksum mismatch for $ARCHIVE (have $HAVE, SHA256SUMS says $WANT): nothing was installed"
say "  checksum:  $ARCHIVE matches SHA256SUMS"

# Unpack in the temporary directory, after a look at the names: nothing absolute, nothing
# that climbs out.
if tar -tzf "$WORK/$ARCHIVE" | grep -E '^/|(^|/)\.\.(/|$)' >/dev/null; then
  fail "$ARCHIVE holds a path outside its own directory: nothing was installed"
fi
mkdir "$WORK/unpacked"
tar -xzf "$WORK/$ARCHIVE" -C "$WORK/unpacked"
BIN="$WORK/unpacked/memhouse-$VERSION-$TARGET/memhouse"
[ -f "$BIN" ] || fail "$ARCHIVE does not hold memhouse-$VERSION-$TARGET/memhouse: nothing was installed"

mkdir -p "$DIR" 2>/dev/null || fail "cannot create $DIR; choose a directory you can write to with --dir"
[ -w "$DIR" ] || fail "$DIR is not writable; choose another with --dir (this script does not use sudo)"
# Copy beside the destination, then rename: a running memhouse keeps its old file.
cp "$BIN" "$DIR/.memhouse.new.$$"
chmod 0755 "$DIR/.memhouse.new.$$"
mv -f "$DIR/.memhouse.new.$$" "$DIR/memhouse"
say "  installed: $DIR/memhouse"

case ":$PATH:" in
  *":$DIR:"*) ;;
  *)
    say ""
    say "$DIR is not on your PATH. Add it for this shell with:"
    say "  export PATH=\"$DIR:\$PATH\""
    ;;
esac
say ""
say "Next: memhouse up --lite    (or: memhouse up, with Docker, for Postgres)"
