#!/usr/bin/env bash
# Local CI: fmt, clippy, unit tests, release build, e2e, benchmark guard. Same as `cargo xtask ci`.
# Options: --tier 2, --fix, --skip-e2e, --skip-guard (see `cargo xtask`).
set -euo pipefail
cd "$(dirname "$0")/.."
exec cargo xtask ci "$@"
