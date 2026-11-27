#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Shared by the release scripts (sourced, not run): the product version without cargo, a
# portable SHA-256, and the commit time archives are stamped with.

# The repository root, from any script under scripts/.
release_root() {
  (cd "$(dirname "$0")" && git rev-parse --show-toplevel 2>/dev/null) || (cd "$(dirname "$0")/../.." && pwd)
}

# `[workspace.package] version` of the root Cargo.toml (what `cargo xtask version` checks
# every other place against).
release_version() {
  sed -n '/^\[workspace\.package\]/,/^\[/s/^version = "\(.*\)"$/\1/p' "$1/Cargo.toml" | head -1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Seconds since the epoch of the commit being released: the timestamp inside archives, so
# that the same commit gives the same bytes.
release_epoch() {
  if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then echo "$SOURCE_DATE_EPOCH"; else git -C "$1" log -1 --format=%ct 2>/dev/null || echo 0; fi
}
