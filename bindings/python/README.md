<!-- SPDX-License-Identifier: Apache-2.0 -->
# memhouse-lite (Python)

MemHouse Lite inside a Python process: no server, no socket, one SQLite file.

The module does not wrap the engine method by method. It embeds the HTTP router that
`memhouse serve` runs and sends each request to it in process, so you get the REST API exactly
as it is documented, and every control on the way is the server's own: authentication, the
access check, the write gate with its injection screen, redaction, the audit trail. The Python
SDK uses this module as a transport in place of HTTP.

```python
import json
from memhouse_lite import Lite

with Lite("/home/ada/.memhouse/memhouse.db") as lite:
    lite.request("POST", "/v1/remember", json.dumps({"subject": "user:ada", "content": "Ada prefers tea", "wait": True}))
    status, body = lite.request("POST", "/v1/recall", json.dumps({"subject": "user:ada", "query": "what does Ada drink?"}))
```

## Interface

```python
class Lite:
    def __init__(self, path=None, config=None): ...
    def request(self, method, path, body=None, headers=None) -> tuple[int, str]: ...
    def close(self) -> None: ...
    closed: bool
    # and the context-manager methods
```

- `Lite(path)` opens (or creates) that SQLite file with the defaults of the Lite profile. Its
  directory must be yours alone (`chmod 700`), as for every Lite database. The first use
  downloads the pinned local embedding model.
- `Lite(config=...)` reads a `config.toml` instead, as `memhouse serve` would, environment
  overrides included. With neither argument, the installation's own configuration is read.
- `request` returns the status and the response body as text (JSON for the API's routes, the
  Prometheus text format for `GET /metrics`). It releases the GIL while it runs, so it can be
  called from several threads. A header name may appear once in `headers`: two that differ
  only in letter case (`Authorization` and `authorization`) raise `RuntimeError`, and nothing
  is sent.
- `close()` stops the background workers, releases the file and ends the native threads the
  deployment ran on (after the last request still running on another thread has returned), so
  a closed `Lite` you still hold costs nothing. It may be called more than once, also from
  several threads at once: each call returns when the workers have stopped.

One process opens a Lite file for writing at a time: do not open the same file from two
processes that both write.

## Authentication

There is no open mode. The middleware verifies a credential on every request, as on the server.
The process that embeds MemHouse holds the configuration, and so the bootstrap key in it: a
request without an `Authorization` or `x-api-key` header is sent with that key and runs as
`admin:bootstrap`. With `Lite(path)` there is no configuration file, so a random key is made for
the process and kept in memory only. A request that names a credential is verified as it stands
(a wrong one gets 401 and an `auth.failed` audit event), so code acting for an agent or a user
passes that principal's key or token in `headers` and is held to its permissions.

## Build from source

There are no published wheels yet: building them for the platform matrix is part of the release
work. From a checkout, with a Rust toolchain and [uv](https://docs.astral.sh/uv/):

```bash
cd bindings/python
./test.sh                                   # build into .venv and run the tests
uvx maturin build                           # a wheel under target/wheels/, to `pip install`
```

Both build with the workspace's `bindings` profile (set in `pyproject.toml`): optimised, and
without LTO. A build with LTO (the `release` profile) produces on macOS a module that cannot be
loaded, so do not pass `--release`.

The wheel uses Python's stable ABI (`abi3`): one build serves CPython 3.9 and later on its
platform. It has been built and tested on macOS (Apple silicon).

The tests use a stand-in embedding endpoint served by the test process, so they download
nothing. `MEMHOUSE_LITE_TEST_LOCAL_MODEL=1 ./test.sh` also runs the test that opens a bare file
path with the real local model.
