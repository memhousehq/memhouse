# SPDX-License-Identifier: Apache-2.0
"""The client offline: how requests are built and how answers and errors are read."""

import sys

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
