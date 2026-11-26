# SPDX-License-Identifier: Apache-2.0
import os
from types import TracebackType
from typing import Dict, Optional, Tuple, Type, Union

__version__: str

class Lite:
    """One embedded MemHouse Lite deployment.

    ``path`` is the SQLite file to use (created if missing, with the defaults of the Lite
    profile). ``config`` is the path of a ``config.toml`` instead. With neither, the
    installation's own configuration is read (``MEMHOUSE_CONFIG``, or ``config.toml`` under
    ``MEMHOUSE_HOME``). Giving both raises ``ValueError``.
    """

    def __init__(
        self,
        path: Union[str, "os.PathLike[str]", None] = None,
        config: Union[str, "os.PathLike[str]", None] = None,
    ) -> None: ...
    def request(
        self,
        method: str,
        path: str,
        body: Optional[str] = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> Tuple[int, str]:
        """Send one request to the REST API in process; returns ``(status, body)``.

        Without an ``Authorization`` or ``x-api-key`` header, the request is sent with the
        deployment's configured bootstrap key. A header name may appear once: two that differ
        only in letter case raise ``RuntimeError``. The GIL is released while it runs. Raises
        ``RuntimeError`` after ``close()``.
        """
        ...
    def close(self) -> None:
        """Stop the background workers, release the database file and end the native threads.

        Returns when the workers have stopped: each ends after its current job, and one still
        busy after ten seconds is cancelled, its job to be run again the next time the
        deployment is open. Idempotent, also across threads: every call returns when the
        workers have stopped.

        A write whose request was answered just before ``close()`` is finished on a task of
        its own, which ``close()`` does not wait for: if it is still under way when the
        runtime ends, it is cut off there and run again the next time the deployment is open.
        """
        ...
    @property
    def closed(self) -> bool: ...
    def __enter__(self) -> "Lite": ...
    def __exit__(
        self,
        exc_type: Optional[Type[BaseException]] = None,
        exc: Optional[BaseException] = None,
        traceback: Optional[TracebackType] = None,
    ) -> bool: ...
