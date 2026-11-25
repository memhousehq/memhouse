# SPDX-License-Identifier: Apache-2.0
"""Fixtures: a throwaway Lite deployment whose embedding model is a local stand-in.

The stand-in is an OpenAI-compatible ``/embeddings`` endpoint served by this process (hashed
bag of words), so the tests download no model and call nothing outside the machine.
"""

import hashlib
import json
import math
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

DIM = 64
KEY = "mh_python_binding_test_key"  # secret-scan: allow (fake fixture)


def embed(text: str) -> list:
    vector = [0.0] * DIM
    for word in "".join(c.lower() if c.isalnum() else " " for c in text).split():
        if len(word) > 2:
            vector[int(hashlib.sha256(word.encode()).hexdigest()[:8], 16) % DIM] += 1.0
    norm = math.sqrt(sum(x * x for x in vector)) or 1.0
    return [x / norm for x in vector]


class Embeddings(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (the name http.server calls)
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        texts = request["input"] if isinstance(request["input"], list) else [request["input"]]
        body = json.dumps({"data": [{"index": i, "embedding": embed(t)} for i, t in enumerate(texts)]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


@pytest.fixture(scope="session")
def embeddings_url():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Embeddings)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


@pytest.fixture(autouse=True)
def clean_environment(monkeypatch):
    """The configuration under test is the file's: no override from the developer's shell."""
    import os

    for name in list(os.environ):
        if name.startswith("MEMHOUSE_") and name != "MEMHOUSE_LITE_TEST_LOCAL_MODEL" or name == "DATABASE_URL":
            monkeypatch.delenv(name)


@pytest.fixture
def config(tmp_path, embeddings_url):
    """A ``config.toml`` for a Lite deployment in ``tmp_path`` (a directory only we can use)."""
    tmp_path.chmod(0o700)
    path = tmp_path / "config.toml"
    path.write_text(
        f"""
[database]
url = "sqlite:{tmp_path / 'memhouse.db'}"

[embedding]
provider = "openai"
model = "stand-in"
dim = {DIM}
base_url = "{embeddings_url}"
sessions = 1
max_retries = 0

[server]
api_keys = ["{KEY}"]
"""
    )
    return str(path)
