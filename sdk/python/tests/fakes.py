# SPDX-License-Identifier: Apache-2.0
"""A transport that records every request and answers from a list."""

import json
from typing import Any, Dict, List, Optional, Tuple


class RecordingTransport:
    def __init__(self, *answers: Any) -> None:
        # Each answer is a body (answered with 200) or a (status, body) pair.
        self.answers: List[Any] = list(answers)
        self.requests: List[Dict[str, Any]] = []

    def request(self, method: str, path: str, body: Optional[str], headers: Dict[str, str]) -> Tuple[int, str]:
        self.requests.append({"method": method, "path": path, "body": json.loads(body) if body is not None else None, "headers": headers})
        answer = self.answers.pop(0) if self.answers else {}
        status, payload = answer if isinstance(answer, tuple) else (200, answer)
        return status, payload if isinstance(payload, str) else json.dumps(payload)

    @property
    def calls(self) -> List[Tuple[str, str]]:
        return [(r["method"], r["path"]) for r in self.requests]
