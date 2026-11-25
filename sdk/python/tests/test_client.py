# SPDX-License-Identifier: Apache-2.0
"""The client offline: how requests are built and how answers and errors are read."""

import socket
import sys
import threading
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from fakes import RecordingTransport

from memhouse import API_VERSION, HttpTransport, MemHouse, MemHouseError
from memhouse._generated import GeneratedClient

FAKE_KEY = "mh_test_0000"  # secret-scan: allow (fake fixture)


def client(*answers, **options):
    transport = RecordingTransport(*answers)
    return MemHouse("http://memhouse.test", FAKE_KEY, transport=transport, **options), transport


def test_a_post_sends_the_body_as_json_with_the_key_as_a_bearer_credential():
    mh, sent = client({"id": "1", "status": "candidate", "deduplicated": False})
    result = mh.remember({"subject": "customer:acme", "content": "Acme renews in March"}, idempotency_key="k-1")
    assert result["status"] == "candidate"
    (request,) = sent.requests
    assert (request["method"], request["path"]) == ("POST", "/v1/remember")
    assert request["body"] == {"subject": "customer:acme", "content": "Acme renews in March"}
    assert request["headers"]["authorization"] == f"Bearer {FAKE_KEY}"
    assert request["headers"]["content-type"] == "application/json"
    assert request["headers"]["idempotency-key"] == "k-1"
    assert "x-memhouse-user" not in request["headers"]


def test_path_parameters_are_encoded_and_unset_query_parameters_left_out():
    mh, sent = client({"items": []}, {"deleted": 1})
    mh.list_memories("customer:acme/eu", include_inactive=True, limit=5)
    mh.revoke_grant("a b")
    assert sent.calls == [("GET", "/v1/subjects/customer%3Aacme%2Feu/memories?include_inactive=true&limit=5"), ("DELETE", "/v1/grants/a%20b")]
    assert sent.requests[0]["body"] is None and "content-type" not in sent.requests[0]["headers"]


def test_the_client_user_is_sent_unless_the_call_names_another():
    mh, sent = client({}, {}, user="user:ana", actor="support-bot")
    mh.whoami()
    mh.whoami(user="user:ben")
    assert [r["headers"]["x-memhouse-user"] for r in sent.requests] == ["user:ana", "user:ben"]
    assert sent.requests[0]["headers"]["x-memhouse-actor"] == "support-bot"


def test_a_text_answer_is_returned_as_text():
    mh, sent = client("memhouse_up 1\n")
    assert mh.metrics() == "memhouse_up 1\n"
    assert sent.requests[0]["headers"]["accept"] == "text/plain"


def test_an_error_answer_raises_with_the_code_the_message_and_the_status():
    mh, _ = client((409, {"error": "request key 'k' was already used for a different request", "code": "conflict"}))
    with pytest.raises(MemHouseError) as raised:
        mh.remember({"content": "x"})
    e = raised.value
    assert (e.status, e.code) == (409, "conflict") and "already used" in e.error
    assert FAKE_KEY not in str(e)


def test_an_error_without_a_json_body_gets_the_code_of_its_status():
    mh, _ = client((503, "upstream is down"), (418, ""))
    with pytest.raises(MemHouseError) as raised:
        mh.stats()
    assert (raised.value.status, raised.value.code, raised.value.error) == (503, "unavailable", "upstream is down")
    with pytest.raises(MemHouseError) as raised:
        mh.stats()
    assert (raised.value.status, raised.value.code) == (418, "unknown")


def test_a_key_repeated_by_an_error_answer_is_not_in_the_error():
    # A proxy that echoes the request's headers in its error page, as text or as JSON.
    mh, _ = client((502, f"bad gateway; request was: Authorization: Bearer {FAKE_KEY}"), (401, {"error": f"the key {FAKE_KEY} is not known", "code": f"unauthorized:{FAKE_KEY}"}), (500, "x" * 495 + FAKE_KEY))
    for status in (502, 401, 500):
        with pytest.raises(MemHouseError) as raised:
            mh.stats()
        e = raised.value
        assert e.status == status and FAKE_KEY not in f"{e} {e.error} {e.code}" and FAKE_KEY[:8] not in e.error
    assert "[redacted]" in e.error or status == 500


def test_url_and_key_come_from_the_environment_and_the_key_is_not_shown(monkeypatch):
    monkeypatch.setenv("MEMHOUSE_URL", "http://127.0.0.1:1")
    monkeypatch.setenv("MEMHOUSE_API_KEY", FAKE_KEY)
    mh = MemHouse()
    assert mh.base_url == "http://127.0.0.1:1"
    assert FAKE_KEY not in repr(mh) and FAKE_KEY not in str(vars(mh.transport))
    # Nothing listens there: no answer is an error of its own, without the key in it.
    with pytest.raises(MemHouseError) as raised:
        mh.health()
    assert (raised.value.status, raised.value.code) == (0, "transport")
    assert FAKE_KEY not in str(raised.value)


def test_only_http_urls_are_accepted():
    with pytest.raises(ValueError):
        HttpTransport("file:///etc/passwd")
    with pytest.raises(ValueError):
        HttpTransport("http://")


def test_a_url_that_would_change_the_request_target_is_refused():
    # Appending `/health` to these would put the path into the query or the fragment.
    for url in ("https://memhouse.test/gateway?region=west", "https://memhouse.test/gateway#api", "https://memhouse.test?"):
        with pytest.raises(ValueError, match="query string or a fragment"):
            HttpTransport(url)
    # A path prefix is kept in front of every operation's path.
    assert HttpTransport("https://memhouse.test/gateway/").base_url == "https://memhouse.test/gateway"
    assert HttpTransport("http://127.0.0.1:7077").base_url == "http://127.0.0.1:7077"


def test_credentials_in_the_url_are_refused_and_not_repeated():
    for url in ("https://ada:" + FAKE_KEY + "@memhouse.test", "ftp://ada:" + FAKE_KEY + "@memhouse.test", "https://ada:" + FAKE_KEY + "@memhouse.test:port"):
        with pytest.raises(ValueError) as raised:
            MemHouse(url)
        assert FAKE_KEY not in str(raised.value) and "ada" not in str(raised.value)


def test_a_path_parameter_cannot_name_another_route():
    mh, sent = client({"items": []})
    # `/v1/subjects/../memories` is `/v1/memories` to a URL parser, encoded or not.
    for subject in ("..", ".", ""):
        with pytest.raises(ValueError, match="path parameter"):
            mh.list_memories(subject)
    with pytest.raises(ValueError, match="path parameter"):
        mh.get_memory("")
    assert sent.calls == []
    # Dots inside a longer value, and an encoded slash, are one segment as before.
    mh.list_memories("../x")
    assert sent.calls == [("GET", "/v1/subjects/..%2Fx/memories")]


class _Server:
    """A local HTTP server that answers every request with `answer(handler)` and records them."""

    def __init__(self, answer):
        seen = self.seen = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802 (the name http.server calls)
                seen.append((self.path, self.headers.get("Authorization")))
                answer(self)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def _answer(status, body=b"", **headers):
    def answer(handler):
        handler.send_response(status)
        for name, value in headers.items():
            handler.send_header(name, value)
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)

    return answer


def test_the_key_is_not_sent_to_another_origin_by_a_redirect():
    health = b'{"status": "ok", "version": "x", "api_version": "y"}'
    other = _Server(_answer(200, health))
    moved = _Server(_answer(302, Location=f"{other.url}/health"))
    within = _Server(lambda handler: _answer(200, health)(handler) if handler.path == "/v2/health" else _answer(307, Location="/v2/health")(handler))
    try:
        with pytest.raises(MemHouseError) as raised:
            MemHouse(moved.url, FAKE_KEY).health()
        e = raised.value
        assert e.status == 302 and "was not followed" in e.error and other.url in e.error
        assert FAKE_KEY not in str(e)
        # The other origin was never called, with the key or without it.
        assert other.seen == [] and moved.seen == [("/health", f"Bearer {FAKE_KEY}")]
        # Within the origin the request follows, credential included.
        assert MemHouse(within.url, FAKE_KEY).health()["status"] == "ok"
        assert within.seen == [("/health", f"Bearer {FAKE_KEY}"), ("/v2/health", f"Bearer {FAKE_KEY}")]
    finally:
        for server in (other, moved, within):
            server.close()


def test_a_failure_while_reading_an_error_body_is_a_transport_error(monkeypatch):
    class Stalled:
        def read(self, *args):
            raise socket.timeout("timed out")

        def close(self):
            pass

    def unavailable(self, request, timeout=None):
        raise urllib.error.HTTPError(request.full_url, 503, "Service Unavailable", {}, Stalled())

    monkeypatch.setattr("urllib.request.OpenerDirector.open", unavailable)
    with pytest.raises(MemHouseError) as raised:
        MemHouse("http://memhouse.test", FAKE_KEY).health()
    assert (raised.value.status, raised.value.code) == (0, "transport") and "timed out" in raised.value.error
    assert FAKE_KEY not in str(raised.value)


def test_embedded_says_what_to_install_when_the_binding_is_missing(monkeypatch):
    monkeypatch.setitem(sys.modules, "memhouse_lite", None)  # makes the import fail
    with pytest.raises(ImportError, match="memhouse-lite"):
        MemHouse.embedded()


def test_embedded_uses_the_binding_as_the_transport_and_closes_it(monkeypatch):
    class Lite:
        def __init__(self, path=None, config=None):
            self.opened, self.closed, self.seen = (path, config), False, []

        def request(self, method, path, body, headers):
            self.seen.append((method, path, headers.get("authorization")))
            return 200, '{"status": "ok", "version": "x", "api_version": "y"}'

        def close(self):
            self.closed = True

    module = type(sys)("memhouse_lite")
    module.Lite = Lite
    monkeypatch.setitem(sys.modules, "memhouse_lite", module)
    monkeypatch.setenv("MEMHOUSE_API_KEY", FAKE_KEY)
    with MemHouse.embedded("/tmp/x.db") as mh:
        assert mh.health()["status"] == "ok"
        lite = mh.transport
    # In process there is no key to send, whatever the environment holds.
    assert lite.opened == ("/tmp/x.db", None) and lite.seen == [("GET", "/health", None)] and lite.closed


def test_every_operation_of_the_specification_is_a_method():
    methods = [name for name in vars(GeneratedClient) if not name.startswith("_")]
    assert {"remember", "recall", "revise", "forget", "ingest", "get_memory", "list_memories", "review", "whoami"} <= set(methods)
    assert all(callable(getattr(MemHouse, name)) for name in methods)
    assert API_VERSION.count(".") == 2
