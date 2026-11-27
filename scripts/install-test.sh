#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Tests of install.sh against a made-up release served on a loopback address (roadmap G21).
# Needs python3 (the web server and the archive builder), curl and tar. Nothing outside a
# temporary directory is written, and no real release is contacted.
#
#   scripts/install-test.sh [shell]        # the shell install.sh runs under (default sh)
#
# What it shows: the latest and a named release install and run; --dry-run changes nothing;
# a changed archive, an archive missing from SHA256SUMS, an archive with a path that climbs
# out, a failed signature check and --require-signature without cosign each install nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

SH=${1:-sh}
WORK=$(mktemp -d)
SERVER=
cleanup() {
  if [ -n "$SERVER" ]; then
    kill "$SERVER" 2>/dev/null || true
    wait "$SERVER" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() {
  printf 'install-test: FAILED: %s\n' "$*" >&2
  exit 1
}
step() { printf '== %s\n' "$*"; }

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) TARGET=x86_64-unknown-linux-gnu ;;
  Linux-aarch64 | Linux-arm64) TARGET=aarch64-unknown-linux-gnu ;;
  Darwin-arm64) TARGET=aarch64-apple-darwin ;;
  *) echo "install-test: no release target for this machine; nothing to test" >&2; exit 0 ;;
esac
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# A release: <root>/v<version>/{memhouse-<version>-<target>.tar.gz, SHA256SUMS}. The "binary"
# is a script that answers --version.
release() { # <version>
  local v=$1 name="memhouse-$1-$TARGET" dir="$WORK/site/v$1"
  mkdir -p "$dir" "$WORK/stage/$name"
  printf '#!/bin/sh\necho "memhouse %s"\n' "$v" >"$WORK/stage/$name/memhouse"
  chmod 0755 "$WORK/stage/$name/memhouse"
  tar -czf "$dir/$name.tar.gz" -C "$WORK/stage" "$name"
  (cd "$dir" && printf '%s  %s\n' "$(sha "$name.tar.gz")" "$name.tar.gz" >SHA256SUMS)
}
release 9.9.8
release 9.9.9
echo 9.9.9 >"$WORK/site/LATEST"

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/LATEST" >/dev/null 2>&1 && break; sleep 0.1; done
export MEMHOUSE_RELEASE_BASE_URL="http://127.0.0.1:$PORT"
# No cosign unless a case puts one on the PATH.
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
install() { PATH="${EXTRA_PATH:+$EXTRA_PATH:}$BASE_PATH" HOME="$WORK/home" "$SH" ./install.sh "$@"; }
refused() { # <what> <dir that must stay empty> <args...>
  local what=$1 dir=$2
  shift 2
  if install --dir "$dir" "$@" >"$WORK/out" 2>&1; then
    cat "$WORK/out" >&2
    fail "$what: install.sh succeeded"
  fi
  [ ! -e "$dir/memhouse" ] || fail "$what: a binary was installed all the same"
  grep -F "nothing was installed" "$WORK/out" >/dev/null || fail "$what: the refusal does not say that nothing was installed: $(cat "$WORK/out")"
}

step "dry run changes nothing"
install --dry-run --dir "$WORK/dry" | grep -F "v9.9.9/memhouse-9.9.9-$TARGET.tar.gz" >/dev/null || fail "the dry run does not name the archive"
[ ! -e "$WORK/dry" ] || fail "the dry run created the directory"

step "latest release, default directory"
install >"$WORK/out" 2>&1 || { cat "$WORK/out" >&2; fail "installing the latest release"; }
[ "$("$WORK/home/.local/bin/memhouse" --version)" = "memhouse 9.9.9" ] || fail "the installed binary is not 9.9.9"
grep -F "signature: not checked" "$WORK/out" >/dev/null || fail "an unchecked signature is not reported"
grep -F "is not on your PATH" "$WORK/out" >/dev/null || fail "no hint that the directory is off the PATH"

step "a named release, another directory, over an existing binary"
install --version 9.9.8 --dir "$WORK/bin" >/dev/null 2>&1 || fail "installing 9.9.8"
[ "$("$WORK/bin/memhouse" --version)" = "memhouse 9.9.8" ] || fail "the installed binary is not 9.9.8"
MEMHOUSE_VERSION=v9.9.9 install --dir "$WORK/bin" >/dev/null 2>&1 || fail "upgrading to 9.9.9 through MEMHOUSE_VERSION"
[ "$("$WORK/bin/memhouse" --version)" = "memhouse 9.9.9" ] || fail "the upgrade did not replace the binary"

step "a changed archive is refused"
cp -R "$WORK/site/v9.9.9" "$WORK/site/v9.9.7"
(cd "$WORK/site/v9.9.7" && mv "memhouse-9.9.9-$TARGET.tar.gz" "memhouse-9.9.7-$TARGET.tar.gz" && sed -i.bak 's/9\.9\.9/9.9.7/' SHA256SUMS && printf 'x' >>"memhouse-9.9.7-$TARGET.tar.gz")
refused "changed archive" "$WORK/tampered" --version 9.9.7
grep -F "checksum mismatch" "$WORK/out" >/dev/null || fail "the changed archive was refused for another reason"

step "an archive SHA256SUMS does not list is refused"
mkdir "$WORK/site/v9.9.6" && cp "$WORK/site/v9.9.9/memhouse-9.9.9-$TARGET.tar.gz" "$WORK/site/v9.9.6/memhouse-9.9.6-$TARGET.tar.gz"
echo "0000000000000000000000000000000000000000000000000000000000000000  another-file.tar.gz" >"$WORK/site/v9.9.6/SHA256SUMS"
refused "unlisted archive" "$WORK/unlisted" --version 9.9.6

step "an archive with a path that climbs out is refused"
mkdir "$WORK/site/v9.9.5"
python3 - "$WORK/site/v9.9.5/memhouse-9.9.5-$TARGET.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as tar:
    data = b"#!/bin/sh\necho escaped\n"
    info = tarfile.TarInfo("../memhouse-escaped")
    info.size, info.mode = len(data), 0o755
    tar.addfile(info, io.BytesIO(data))
PY
(cd "$WORK/site/v9.9.5" && printf '%s  %s\n' "$(sha "memhouse-9.9.5-$TARGET.tar.gz")" "memhouse-9.9.5-$TARGET.tar.gz" >SHA256SUMS)
refused "climbing path" "$WORK/climb" --version 9.9.5

step "--require-signature without cosign installs nothing"
refused "no cosign" "$WORK/nosig" --version 9.9.9 --require-signature

step "with cosign: a failed verification installs nothing, a passed one is reported"
mkdir -p "$WORK/cosign-no" "$WORK/cosign-yes"
printf '#!/bin/sh\necho "error: no matching signatures" >&2\nexit 1\n' >"$WORK/cosign-no/cosign"
# The stand-in passes only for the identity the release workflow signs with.
cat >"$WORK/cosign-yes/cosign" <<'STUB'
#!/bin/sh
case "$*" in
  *"--certificate-identity https://github.com/memhousehq/memhouse/.github/workflows/release.yml@refs/tags/v9.9.9"*"--certificate-oidc-issuer https://token.actions.githubusercontent.com"*) exit 0 ;;
  *) echo "unexpected arguments: $*" >&2; exit 1 ;;
esac
STUB
chmod 0755 "$WORK/cosign-no/cosign" "$WORK/cosign-yes/cosign"
echo '{}' >"$WORK/site/v9.9.9/SHA256SUMS.sigstore.json"
EXTRA_PATH="$WORK/cosign-no" refused "failed signature" "$WORK/badsig" --version 9.9.9
EXTRA_PATH="$WORK/cosign-yes" install --version 9.9.9 --dir "$WORK/goodsig" >"$WORK/out" 2>&1 || { cat "$WORK/out" >&2; fail "installing with a passing signature check"; }
grep -F "signed by the release workflow at v9.9.9" "$WORK/out" >/dev/null || fail "a verified signature is not reported"

step "bad input is refused before any download"
if MEMHOUSE_RELEASE_BASE_URL="http://example.invalid/releases" install --version 9.9.9 --dir "$WORK/http" >/dev/null 2>&1; then fail "a plain-http mirror that is not loopback was accepted"; fi
if install --version '9.9.9/../../x' --dir "$WORK/ver" >/dev/null 2>&1; then fail "a version with a path in it was accepted"; fi
if install --frobnicate >/dev/null 2>&1; then fail "an unknown option was accepted"; fi
[ ! -e "$WORK/http" ] && [ ! -e "$WORK/ver" ] || fail "a refused run left a directory"

printf 'install-test: all checks passed (%s, %s)\n' "$SH" "$TARGET"
