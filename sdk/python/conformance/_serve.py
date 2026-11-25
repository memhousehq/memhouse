# SPDX-License-Identifier: Apache-2.0
"""What the adapter drivers share: the JSON-lines protocol of the profile suite's `Process` way
(docs/conformance.md), and reading a scenario request into what an adapter is given.

A driver passes `serve` one function that carries out an operation through its adapter. A field
of a request that the adapter has no place for is an error, never dropped silently.
"""

import json
import sys
from typing import Any, Callable, Dict, List, Tuple

OPERATIONS = ("remember", "recall", "revise", "forget", "ingest")

# What a memory object is built with (the subject and the session it is bound to, and whether it
# asks for the write gate's decision), as against what a tool call or a turn carries.
BOUND = ("subject", "wait", "session_id")


def serve(call: Callable[[str, Dict[str, Any]], Any]) -> int:
    """Answer one line per request line until standard input ends."""
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
            op = request.get("op")
            if op not in OPERATIONS:
                raise ValueError(f"the driver has no operation {op!r}")
            result = call(op, request.get("body") or {})
            if not isinstance(result, dict):
                raise ValueError(f"the adapter did not return the API's answer: {result!r}")
            answer = {"ok": True, "result": result}
        except Exception as e:  # one failed call is one failed step, not the end of the run
            answer = {"ok": False, "error": f"{type(e).__name__}: {e}"}
        sys.stdout.write(json.dumps(answer) + "\n")
        sys.stdout.flush()
    return 0


def is_cleanup(op: str, body: Dict[str, Any]) -> bool:
    """The suite's cleanup after a run: `forget` of a whole subject. It is not a step of the
    scenario, and the adapters give an agent no tool that erases a subject, so the drivers
    carry it out with the bare client."""
    return op == "forget" and "id" not in body


def tool_arguments(body: Dict[str, Any], accepted: List[str]) -> Dict[str, Any]:
    """The arguments of a tool call: the request without what the tools are bound to."""
    arguments = {k: v for k, v in body.items() if k not in BOUND}
    unknown = sorted(set(arguments) - set(accepted))
    if unknown:
        raise ValueError(f"the adapter's tool has no argument {', '.join(unknown)}")
    return arguments


def one_round(body: Dict[str, Any]) -> Tuple[str, str]:
    """The user message and the reply of an `ingest` request, which the adapters' after-turn
    path can carry only when it is exactly one round."""
    unknown = sorted(set(body) - set(BOUND) - {"messages"})
    if unknown:
        raise ValueError(f"the adapter's after-turn path has no place for {', '.join(unknown)}")
    messages = body.get("messages") or []
    if [m.get("role") for m in messages] != ["user", "assistant"]:
        raise ValueError("the adapter's after-turn path carries one round: a user message and the assistant's reply")
    return messages[0]["content"], messages[1]["content"]
