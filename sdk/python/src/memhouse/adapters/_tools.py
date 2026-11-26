# SPDX-License-Identifier: Apache-2.0
"""What the adapters share: the memory tools' texts for the model, and their requests.

No framework is imported here. Each function builds the request of one API operation from a
tool's arguments and nothing else: what is stored, held, quarantined or returned is decided by
the MemHouse engine (INT-03).
"""

from __future__ import annotations

import json
from typing import Any, List, Optional, Tuple

from .._generated import ForgetRequest, MemoryKind, RecallRequest, RememberRequest, ReviseRequest

# The tools' names, as the model sees them.
TOOL_NAMES: Tuple[str, ...] = ("remember", "recall", "revise", "forget")

# Docstrings in the Google style: both frameworks read the description and the arguments from them.
REMEMBER_DOC = """Store one thing worth keeping in long-term memory: a fact, a preference, an event or a commitment, as one statement that can be understood on its own. The answer is JSON with the memory's `id` and its `status`: `committed` (stored), `candidate` (held until confirmed, or still being checked), `quarantined` or `rejected`.

Args:
    content: The statement to remember, complete and self-contained.
    kind: The kind of memory, when it is not a plain fact (`semantic`): for example `preference`, `episodic`, `procedural` or `commitment`.
"""

RECALL_DOC = """Look up what long-term memory holds that is relevant to a question. The answer is JSON: `hits` lists the memories, most relevant first, each with its `memory.id` and `memory.content`.

Args:
    query: What you need to know, in natural language.
    k: How many memories to return at most.
"""

REVISE_DOC = """Correct a memory that is wrong or out of date: the corrected statement replaces it and the old version is kept as history. The answer is JSON with the new memory's `id` and `status`.

Args:
    id: The id of the memory to correct, as `recall` returned it.
    content: The corrected statement, complete and self-contained.
"""

FORGET_DOC = """Delete one memory permanently, when the user asks for it to be forgotten. The answer is JSON with the number of memories `deleted`.

Args:
    id: The id of the memory to delete, as `recall` returned it.
"""


def remember_request(subject: str, content: str, kind: Optional[MemoryKind], wait: bool) -> RememberRequest:
    request: RememberRequest = {"subject": subject, "content": content}
    if kind is not None:
        request["kind"] = kind
    if wait:
        request["wait"] = True
    return request


def recall_request(subject: str, query: str, k: Optional[int]) -> RecallRequest:
    request: RecallRequest = {"subject": subject, "query": query}
    if k is not None:
        request["k"] = k
    return request


def revise_request(id: str, content: str, wait: bool) -> ReviseRequest:
    request: ReviseRequest = {"id": id, "content": content}
    if wait:
        request["wait"] = True
    return request


def forget_request(id: str) -> ForgetRequest:
    return {"id": id}


def text_of(value: Any) -> str:
    """Text as it is, anything else as compact JSON (as `MemoryHooks.on_tool_result` sends it)."""
    return value if isinstance(value, str) else json.dumps(value, separators=(",", ":"), ensure_ascii=False, default=str)


def message_text(content: Any) -> str:
    """The text of a message's content: a string, or a list of parts of which the text ones count."""
    if isinstance(content, str):
        return content
    parts: List[str] = []
    for part in content if isinstance(content, (list, tuple)) else []:
        if isinstance(part, str):
            parts.append(part)
        elif isinstance(part, dict) and isinstance(part.get("text"), str):
            parts.append(part["text"])
    return "".join(parts)
