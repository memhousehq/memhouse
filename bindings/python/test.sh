#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build the extension into a local virtual environment and run its tests.
# Needs a Rust toolchain and uv (https://docs.astral.sh/uv/). Arguments go to pytest.
set -eu
cd "$(dirname "$0")"
uv venv --allow-existing .venv
VIRTUAL_ENV="$PWD/.venv" uvx maturin develop --uv --extras test
exec .venv/bin/python -m pytest "$@"
