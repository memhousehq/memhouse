#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The Python SDK as a way into a deployment, for the profile conformance suite.

Reads one JSON object per line on standard input, `{"op": "remember", "body": {...}}` (the
operation is `remember`, `recall`, `revise`, `forget` or `ingest`), carries it out with the
SDK's client and writes one line: `{"ok": true, "result": {...}}` or `{"ok": false, "error":
"..."}`. The deployment is the one at MEMHOUSE_URL with MEMHOUSE_API_KEY, or with
MEMHOUSE_EMBEDDED=<database file> the embedded Lite engine. See docs/conformance.md.
"""

import json
import os
import sys

from memhouse import MemHouse

OPERATIONS = ("remember", "recall", "revise", "forget", "ingest")


def main() -> int:
    embedded = os.environ.get("MEMHOUSE_EMBEDDED")
    client = MemHouse.embedded(embedded) if embedded else MemHouse()
    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                request = json.loads(line)
                op = request.get("op")
                if op not in OPERATIONS:
                    raise ValueError(f"the driver has no operation {op!r}")
                answer = {"ok": True, "result": getattr(client, op)(request.get("body") or {})}
            except Exception as e:  # one failed call is one failed step, not the end of the run
                answer = {"ok": False, "error": f"{type(e).__name__}: {e}"}
            sys.stdout.write(json.dumps(answer) + "\n")
            sys.stdout.flush()
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
