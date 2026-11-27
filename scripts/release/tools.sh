#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Install the tools the release pipeline and the packaging checks use, each at one fixed version,
# each download checked against a SHA-256 recorded here (taken from the project's own release
# on 27 November 2026). The repository allows no third-party setup actions, and a tool that
# signs releases should not be whatever version a package manager has today.
#
#   scripts/release/tools.sh <dir> <tool>...     # tools: helm shellcheck actionlint syft cosign
#
# Installs into <dir> (add it to PATH). A tool already there at the right version is kept.
# To update a tool: change its version and its three checksums together, from the release's
# checksum file, and say so in the pull request.
set -eu

[ $# -ge 2 ] || { echo "usage: scripts/release/tools.sh <dir> <tool>..." >&2; exit 2; }
DIR=$1
shift

HELM_VERSION=4.3.2
SHELLCHECK_VERSION=0.11.0
ACTIONLINT_VERSION=1.7.12
SYFT_VERSION=1.57.2
COSIGN_VERSION=3.1.6

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) PLATFORM=linux-amd64 ;;
  Linux-aarch64 | Linux-arm64) PLATFORM=linux-arm64 ;;
  Darwin-arm64) PLATFORM=darwin-arm64 ;;
  *) echo "tools.sh: no pinned downloads for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

# <tool> <platform> -> "<url> <sha256> <path of the binary inside the archive, or - for a bare binary>"
pin() {
  case "$1-$2" in
    helm-linux-amd64) echo "https://get.helm.sh/helm-v$HELM_VERSION-linux-amd64.tar.gz d1c0278d46beab79582d7e50f5b3dc206944ba8e577cde618513fd07daa53983 linux-amd64/helm" ;;
    helm-linux-arm64) echo "https://get.helm.sh/helm-v$HELM_VERSION-linux-arm64.tar.gz df31cb61680ef728f82c770e5280dd565617bee6b039d37e85c677288be4bbb0 linux-arm64/helm" ;;
    helm-darwin-arm64) echo "https://get.helm.sh/helm-v$HELM_VERSION-darwin-arm64.tar.gz 6f3421de3a8cc2ac578c8cfb33b8edde290dde2871bc1bab12e24f2e5caeaa90 darwin-arm64/helm" ;;
    shellcheck-linux-amd64) echo "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.x86_64.tar.gz b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6 shellcheck-v$SHELLCHECK_VERSION/shellcheck" ;;
    shellcheck-linux-arm64) echo "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.linux.aarch64.tar.gz 68a8133197a50beb8803f8d42f9908d1af1c5540d4bb05fdfca8c1fa47decefc shellcheck-v$SHELLCHECK_VERSION/shellcheck" ;;
    shellcheck-darwin-arm64) echo "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK_VERSION/shellcheck-v$SHELLCHECK_VERSION.darwin.aarch64.tar.gz 339b930feb1ea764467013cc1f72d09cd6b869ebf1013296ba9055ab2ffbd26f shellcheck-v$SHELLCHECK_VERSION/shellcheck" ;;
    actionlint-linux-amd64) echo "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 actionlint" ;;
    actionlint-linux-arm64) echo "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_linux_arm64.tar.gz 325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 actionlint" ;;
    actionlint-darwin-arm64) echo "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_darwin_arm64.tar.gz aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f actionlint" ;;
    syft-linux-amd64) echo "https://github.com/anchore/syft/releases/download/v$SYFT_VERSION/syft_${SYFT_VERSION}_linux_amd64.tar.gz ad92bd3ec1b94a3df01d4d0aec199afa9c42b72e86da436ff5f837914d32706b syft" ;;
    syft-linux-arm64) echo "https://github.com/anchore/syft/releases/download/v$SYFT_VERSION/syft_${SYFT_VERSION}_linux_arm64.tar.gz 8efe605309c98798e1ee0cffdcf8c05ca26819b4cd44c0b03650f1e963e9bdb6 syft" ;;
    syft-darwin-arm64) echo "https://github.com/anchore/syft/releases/download/v$SYFT_VERSION/syft_${SYFT_VERSION}_darwin_arm64.tar.gz 38afbcc03a9d9afac2d7572432fd2c435e051e03930582ea90f4710ffb515224 syft" ;;
    cosign-linux-amd64) echo "https://github.com/sigstore/cosign/releases/download/v$COSIGN_VERSION/cosign-linux-amd64 318a99ade4156a0c4113aa983b46c0a0830fa7896a096c63121ee47b610a94c6 -" ;;
    cosign-linux-arm64) echo "https://github.com/sigstore/cosign/releases/download/v$COSIGN_VERSION/cosign-linux-arm64 bbb2ebc765f483cf9fac42da8763dddc2b55b350ee12ea0c44a520a6d6d52334 -" ;;
    cosign-darwin-arm64) echo "https://github.com/sigstore/cosign/releases/download/v$COSIGN_VERSION/cosign-darwin-arm64 0ce6045c42e9f21427b3a8b70d54b130ca35cdd88a38358cc303fc6fec7366ba -" ;;
    *) return 1 ;;
  esac
}

version_of() {
  case "$1" in
    helm) echo "$HELM_VERSION" ;;
    shellcheck) echo "$SHELLCHECK_VERSION" ;;
    actionlint) echo "$ACTIONLINT_VERSION" ;;
    syft) echo "$SYFT_VERSION" ;;
    cosign) echo "$COSIGN_VERSION" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$DIR"
DIR=$(cd "$DIR" && pwd)
for tool in "$@"; do
  spec=$(pin "$tool" "$PLATFORM") || { echo "tools.sh: unknown tool '$tool'" >&2; exit 2; }
  version=$(version_of "$tool")
  stamp="$DIR/.$tool-$version"
  if [ -x "$DIR/$tool" ] && [ -f "$stamp" ]; then
    continue
  fi
  # shellcheck disable=SC2086  # three fields, split on purpose
  set -- $spec
  url=$1 want=$2 member=$3
  work=$(mktemp -d)
  echo "tools.sh: $tool $version" >&2
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$work/download" "$url"
  have=$(sha256_of "$work/download")
  if [ "$have" != "$want" ]; then
    echo "tools.sh: $url has sha256 $have, expected $want: not installed" >&2
    rm -rf "$work"
    exit 1
  fi
  if [ "$member" = "-" ]; then
    cp "$work/download" "$work/$tool"
  else
    tar -xzf "$work/download" -C "$work" "$member"
    # actionlint and syft unpack to the tool's own name: GNU mv refuses to move a file onto itself.
    if [ "$member" != "$tool" ]; then mv "$work/$member" "$work/$tool"; fi
  fi
  chmod 0755 "$work/$tool"
  rm -f "$DIR"/."$tool"-*
  mv "$work/$tool" "$DIR/$tool"
  : >"$stamp"
  rm -rf "$work"
done
