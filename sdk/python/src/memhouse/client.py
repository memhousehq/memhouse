# SPDX-License-Identifier: Apache-2.0
"""The MemHouse client: the generated operations over a pluggable transport.

A transport carries one request and returns the status and the body's text. The default one is
HTTP through the standard library; `MemHouse.embedded()` uses the embedded Lite binding instead,
with the same operations and the same engine behind them.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Protocol, Tuple
from urllib.parse import urlencode, urlsplit

from ._generated import GeneratedClient

DEFAULT_URL = "http://127.0.0.1:7077"
_SDK_VERSION = "2.0.0"

# What a status means when the body carries no `code` (docs/api.md, Errors).
_STATUS_CODES = {400: "invalid_request", 401: "unauthorized", 403: "forbidden", 404: "not_found", 409: "conflict", 500: "internal", 503: "unavailable"}


class MemHouseError(Exception):
    """An error answer from the API, or a request that never got one.

    `code` is the API's stable error code (`invalid_request`, `unauthorized`, `forbidden`,
    `not_found`, `conflict`, `internal`, `unavailable`): branch on it, never on the message.
    `status` is the HTTP status, 0 when no answer arrived (`code` is then `transport`).
    """

    def __init__(self, status: int, code: str, error: str) -> None:
        super().__init__(f"{status} {code}: {error}" if status else f"{code}: {error}")
        self.status = status
        self.code = code
        self.error = error


class Transport(Protocol):
    """Carries one request. `path` starts with `/` and includes the query string."""

    def request(self, method: str, path: str, body: Optional[str], headers: Dict[str, str]) -> Tuple[int, str]: ...


class HttpTransport:
    """HTTP through `urllib`: no dependency outside the standard library."""

    def __init__(self, base_url: str, timeout: float = 30.0) -> None:
        parts = urlsplit(base_url)
        # urllib would also open file: and ftp: URLs.
        if parts.scheme not in ("http", "https") or not parts.netloc:
            raise ValueError(f"the MemHouse URL must be http(s)://host[:port], not {base_url!r}")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def request(self, method: str, path: str, body: Optional[str], headers: Dict[str, str]) -> Tuple[int, str]:
        data = body.encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as response:  # noqa: S310 (scheme checked above)
                return response.status, response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            # An error status is an answer: the client maps its body to MemHouseError.
            return e.code, e.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise MemHouseError(0, "transport", f"no answer from {self.base_url}: {reason}") from None


class MemHouse(GeneratedClient):
    """A MemHouse deployment. Every operation of the API is a method (see `GeneratedClient`).

    `base_url` and `api_key` default to the environment variables `MEMHOUSE_URL` and
    `MEMHOUSE_API_KEY`. `user` is the user every call acts for (`x-memhouse-user`), unless a
    call names another. The key is never logged, printed or put in an error message.
    """

    def __init__(
        self,
        base_url: Optional[str] = None,
        api_key: Optional[str] = None,
        *,
        user: Optional[str] = None,
        actor: Optional[str] = None,
        timeout: float = 30.0,
        transport: Optional[Transport] = None,
    ) -> None:
        self.base_url = base_url or os.environ.get("MEMHOUSE_URL") or DEFAULT_URL
        self._api_key = api_key if api_key is not None else os.environ.get("MEMHOUSE_API_KEY")
        self.user = user
        self.actor = actor
        self.transport: Transport = transport if transport is not None else HttpTransport(self.base_url, timeout)

    @classmethod
    def embedded(cls, path: Optional[str] = None, config: Optional[str] = None, *, user: Optional[str] = None, actor: Optional[str] = None) -> "MemHouse":
        """A client over the embedded Lite engine, in this process: no server, one SQLite file.

        `path` is the database file and `config` a configuration file (both optional). Needs the
        package `memhouse-lite`.
        """
        try:
            import memhouse_lite  # type: ignore[import-not-found]
        except ImportError as e:
            raise ImportError("MemHouse.embedded() needs the embedded Lite binding: install the package `memhouse-lite` (built from bindings/python of the MemHouse repository)") from e
        # The embedded engine has no listener and so no key to check: none is sent, whatever
        # the environment holds.
        return cls("embedded:", "", user=user, actor=actor, transport=memhouse_lite.Lite(path, config))

    def close(self) -> None:
        """Release the transport (the embedded engine's file; nothing for HTTP)."""
        close = getattr(self.transport, "close", None)
        if callable(close):
            close()

    def __enter__(self) -> "MemHouse":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def __repr__(self) -> str:
        return f"MemHouse(base_url={self.base_url!r})"

    def _call(
        self,
        method: str,
        path: str,
        query: Optional[Dict[str, Any]] = None,
        body: Any = None,
        headers: Optional[Dict[str, Optional[str]]] = None,
        text: bool = False,
    ) -> Any:
        sent: Dict[str, str] = {"accept": "text/plain" if text else "application/json", "user-agent": f"memhouse-python/{_SDK_VERSION}"}
        if self._api_key:
            sent["authorization"] = f"Bearer {self._api_key}"
        if self.user:
            sent["x-memhouse-user"] = self.user
        if self.actor:
            sent["x-memhouse-actor"] = self.actor
        for name, value in (headers or {}).items():
            if value is not None:
                sent[name.lower()] = str(value)
        pairs = [(k, _query_value(v)) for k, v in (query or {}).items() if v is not None]
        if pairs:
            path = f"{path}?{urlencode(pairs)}"
        payload: Optional[str] = None
        if body is not None:
            payload = json.dumps(body)
            sent["content-type"] = "application/json"
        status, answer = self.transport.request(method, path, payload, sent)
        if 200 <= status < 300:
            if text:
                return answer
            return json.loads(answer) if answer.strip() else None
        raise _error(status, answer)


def _query_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def _error(status: int, answer: str) -> MemHouseError:
    code = _STATUS_CODES.get(status, "unknown")
    message = answer.strip()[:500] or f"HTTP {status}"
    try:
        parsed = json.loads(answer)
        if isinstance(parsed, dict):
            code = str(parsed.get("code") or code)
            message = str(parsed.get("error") or message)
    except ValueError:
        pass
    return MemHouseError(status, code, message)
