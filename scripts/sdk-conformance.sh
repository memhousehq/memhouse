#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# The SDKs against a live deployment (roadmap G18):
#   1. the profile scenario through REST, the Python SDK, the TypeScript SDK and the two framework
#      adapters (OpenAI Agents SDK, LangGraph): every way meets the scenario's expectations and
#      all give the same outcome at every step;
#   2. each SDK's own tests, including the live one that shows governance is the same with the
#      lifecycle hooks and without them; the Python ones once more with the framework extras,
#      which adds the adapters' tests and runs their examples with a stand-in model.
# Starts a throwaway Lite deployment (one SQLite file in a temporary MEMHOUSE_HOME) unless
# MEMHOUSE_URL and MEMHOUSE_API_KEY name one to use. Needs python3 (3.9+), uv, node (20+) and
# pnpm. The adapters run on the Python that MEMHOUSE_SDK_ADAPTER_PYTHON names (default 3.12, which
# uv fetches when it is missing), in an environment of their own (target/sdk-adapters-venv) that
# uv builds from sdk/python/uv.lock: the first run downloads the two frameworks.
# Exits non-zero on any unmet expectation, difference between ways, or failed test.
#
#   scripts/sdk-conformance.sh              # over HTTP
#   scripts/sdk-conformance.sh --embedded   # also the profile scenario over the embedded
#                                           # bindings, which must be built (docs/sdk.md)
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-./target/release/memhouse}
PORT=${PORT:-7098}
EMBEDDED=0
for arg in "$@"; do
  case "$arg" in
    --embedded) EMBEDDED=1 ;;
    *) echo "usage: scripts/sdk-conformance.sh [--embedded]" >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$*"; }

SERVER=
SCRATCH=
cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
}
trap cleanup EXIT

step "build the TypeScript SDK"
(cd sdk/typescript && pnpm install --frozen-lockfile && pnpm build)

SCRATCH=$(mktemp -d)
chmod 700 "$SCRATCH"
# The embedding models already downloaded, if any, instead of fetching them again. A cache that
# is named (MEMHOUSE_MODEL_CACHE, as in scripts/e2e.sh) is created when it is not there yet, so
# what this run downloads stays in it: hosted CI keeps that directory between runs.
if [ -n "${MEMHOUSE_MODEL_CACHE:-}" ]; then mkdir -p "$MEMHOUSE_MODEL_CACHE"; fi
MODELS=${MEMHOUSE_MODEL_CACHE:-${MEMHOUSE_HOME:-$HOME/.memhouse}/models}

if [ -z "${MEMHOUSE_URL:-}" ]; then
  step "a throwaway Lite deployment on 127.0.0.1:$PORT"
  [ -x "$BIN" ] || { echo "$BIN is missing: cargo build --release -p memhouse-cli (or set BIN)" >&2; exit 1; }
  LITE_HOME="$SCRATCH/home"
  mkdir -p "$LITE_HOME" && chmod 700 "$LITE_HOME"
  # As an absolute path: a relative one (MEMHOUSE_MODEL_CACHE=target/model-cache) would be read
  # from the link's own directory, and name nothing there.
  if [ -d "$MODELS" ]; then ln -s "$(cd "$MODELS" && pwd)" "$LITE_HOME/models"; fi
  # The developer's own deployment is not touched: everything below reads this home only.
  unset MEMHOUSE_CONFIG MEMHOUSE_DATABASE_URL DATABASE_URL MEMHOUSE_API_KEY
  export MEMHOUSE_HOME="$LITE_HOME"
  # As in the governance suite's profile check: no enrichment, no reranker.
  export MEMHOUSE_ENRICH=0 MEMHOUSE_RERANK=0
  "$BIN" up --lite >/dev/null
  MEMHOUSE_BIND=127.0.0.1:$PORT "$BIN" serve >"$SCRATCH/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 200); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break
    kill -0 "$SERVER" 2>/dev/null || { echo "the server stopped:" >&2; tail -20 "$SCRATCH/server.log" >&2; exit 1; }
    sleep 0.3
  done
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null || { echo "the server did not come up:" >&2; tail -20 "$SCRATCH/server.log" >&2; exit 1; }
  export MEMHOUSE_URL="http://127.0.0.1:$PORT"
  # The key goes from the deployment to the environment of the tests, never to the output.
  MEMHOUSE_API_KEY=$("$BIN" key)
  export MEMHOUSE_API_KEY
else
  : "${MEMHOUSE_API_KEY:?MEMHOUSE_API_KEY: a key of the deployment at MEMHOUSE_URL}"
  step "the deployment at $MEMHOUSE_URL"
fi

step "profile scenario: REST, Python SDK, TypeScript SDK, OpenAI Agents SDK adapter, LangGraph adapter"
cargo test -p memhouse-conformance --test sdk_profile -- --ignored --nocapture

step "Python SDK tests (offline and live)"
(cd sdk/python && uv run pytest -q)

step "Python SDK tests with the framework adapters (offline and live)"
(cd sdk/python && UV_PROJECT_ENVIRONMENT="$PWD/../../target/sdk-adapters-venv" \
  uv run --python "${MEMHOUSE_SDK_ADAPTER_PYTHON:-3.12}" --extra openai-agents --extra langgraph --locked pytest -q)

step "TypeScript SDK tests (offline and live)"
(cd sdk/typescript && pnpm test)

if [ "$EMBEDDED" = 1 ]; then
  step "profile scenario: Python SDK and TypeScript SDK over the embedded bindings"
  mkdir -p "$SCRATCH/embedded"
  # The bindings as built in this checkout (bindings/python: `maturin develop`; bindings/node:
  # `pnpm build`), unless the interpreters already have them installed.
  # (`.so` on Linux and macOS, `.pyd` on Windows; the `.pyi` beside them is always there.)
  for built in bindings/python/python/memhouse_lite/_lite.*.so bindings/python/python/memhouse_lite/_lite.*.pyd; do
    if [ -e "$built" ]; then
      export PYTHONPATH="$PWD/bindings/python/python${PYTHONPATH:+:$PYTHONPATH}"
      break
    fi
  done
  if [ -f bindings/node/index.js ] && [ ! -e sdk/typescript/node_modules/@memhouse/lite ]; then
    mkdir -p sdk/typescript/node_modules/@memhouse
    ln -s "$PWD/bindings/node" sdk/typescript/node_modules/@memhouse/lite
  fi
  # Each SDK opens a database file of its own; no server and no key are involved.
  (unset MEMHOUSE_URL MEMHOUSE_API_KEY
   MEMHOUSE_SDK_EMBEDDED="$SCRATCH/embedded" cargo test -p memhouse-conformance --test sdk_profile -- --ignored --nocapture)
fi

echo
echo "SDK conformance: all passed"
