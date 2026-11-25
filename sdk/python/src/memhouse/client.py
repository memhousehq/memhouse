# SPDX-License-Identifier: Apache-2.0
"""The MemHouse client: the generated operations over a pluggable transport.

A transport carries one request and returns the status and the body's text. The default one is
HTTP through the standard library; `MemHouse.embedded()` uses the embedded Lite binding instead,
with the same operations and the same engine behind them.
"""

from __future__ import annotations

import http.client
import json
import os
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Protocol, Tuple
from urllib.parse import urlencode, urljoin, urlsplit

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


_URL_FORM = "the MemHouse URL must be http(s)://host[:port], with an optional path prefix"


def _origin(url: str) -> Tuple[str, str, Optional[int]]:
    parts = urlsplit(url)
    scheme = parts.scheme.lower()
    return scheme, (parts.hostname or "").lower(), parts.port or {"http": 80, "https": 443}.get(scheme)


class _SameOriginRedirects(urllib.request.HTTPRedirectHandler):
    """Follows a redirect within the origin it was sent to, and no other.

    urllib repeats the request's headers, the `Authorization` one too, at wherever a redirect
    points. One that leaves the origin is not followed, so the API key reaches no other host:
    urllib then reports the redirect itself, as an error status.
    """

    def redirect_request(self, req: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> Optional[urllib.request.Request]:
        if _origin(urljoin(req.full_url, newurl)) != _origin(req.full_url):
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class HttpTransport:
    """HTTP through `urllib`: no dependency outside the standard library.

    `base_url` is `http(s)://host[:port]`, with a path prefix when the API is served under one.
    A URL with credentials, a query string or a fragment is refused (the message does not
    repeat the URL). A redirect is followed within the same origin only.
    """

    def __init__(self, base_url: str, timeout: float = 30.0) -> None:
        # The URL is not quoted in these messages: it may hold credentials.
        try:
            parts = urlsplit(base_url)
            parts.port  # raises for a port that is not a number
        except ValueError:
            raise ValueError(f"{_URL_FORM}; this one cannot be read as a URL") from None
        # urllib would also open file: and ftp: URLs.
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ValueError(f"{_URL_FORM}; this one is not an http(s) URL with a host")
        if "@" in parts.netloc:
            raise ValueError(f"{_URL_FORM}; this one has credentials in it: give the key as `api_key` or in MEMHOUSE_API_KEY")
        if "?" in base_url or "#" in base_url:
            raise ValueError(f"{_URL_FORM}; this one has a query string or a fragment, which would swallow the path of every request")
        self.base_url = f"{parts.scheme}://{parts.netloc}{parts.path.rstrip('/')}"
        self.timeout = timeout
        # The default opener (proxies from the environment and so on) but for its redirects.
        self._opener = urllib.request.build_opener(_SameOriginRedirects())

    def request(self, method: str, path: str, body: Optional[str], headers: Dict[str, str]) -> Tuple[int, str]:
        data = body.encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        # One handler for the whole exchange: reading the body of an error answer can fail
        # like any other read (a stalled or cut connection), and is no answer either.
        try:
            try:
                with self._opener.open(req, timeout=self.timeout) as response:
                    return response.status, response.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as e:
                # An error status is an answer: the client maps its body to MemHouseError.
                try:
                    answer = e.code, e.read().decode("utf-8", "replace")
                finally:
                    e.close()
                target = _origin(urljoin(req.full_url, e.headers.get("Location") or "")) if 300 <= e.code < 400 else None
                if target is not None and target != _origin(req.full_url):
                    scheme, host, port = target
                    raise MemHouseError(
                        e.code,
                        _STATUS_CODES.get(e.code, "unknown"),
                        f"{self.base_url} redirects to {scheme}://{host}:{port}, which was not followed: the API key is sent only to the URL's own origin. Give the URL the API is served at",
                    ) from None
                return answer
        except (urllib.error.URLError, http.client.HTTPException, OSError) as e:
            reason = getattr(e, "reason", None) or e
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
        # A path parameter that is empty or a dot segment would name another route: `..` is
        # resolved away by URL parsers and proxies even when percent-encoded.
        if any(segment in ("", ".", "..") for segment in path.split("/")[1:]):
            raise ValueError(f"{method} {path}: a path parameter cannot be empty, `.` or `..`: the request would go to another route")
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
        raise _error(status, answer, self._api_key)


def _query_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def _error(status: int, answer: str, key: Optional[str] = None) -> MemHouseError:
    """The error of an answer. `key` is taken out of it, should whatever answered have repeated it."""

    def clean(text: str) -> str:
        return text.replace(key, "[redacted]") if key else text

    code = _STATUS_CODES.get(status, "unknown")
    # Cut after the key is out: a cut through the key would leave a part of it.
    message = clean(answer).strip()[:500] or f"HTTP {status}"
    try:
        parsed = json.loads(answer)
        if isinstance(parsed, dict):
            code = str(parsed.get("code") or code)
            message = str(parsed.get("error") or message)
    except ValueError:
        pass
    return MemHouseError(status, clean(code), clean(message))
