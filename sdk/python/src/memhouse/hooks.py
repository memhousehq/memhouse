# SPDX-License-Identifier: Apache-2.0
"""Lifecycle hooks for an agent loop (INT-03).

Four moments of a conversation, each mapped to an API call:

| Hook | When | API call |
|---|---|---|
| `before_model_call` | before the model is called | `recall` (with `render`) |
| `after_turn` | after the assistant answered | `ingest` |
| `on_tool_result` | when a tool returned | `remember` |
| `at_session_end` | when the conversation is over | `ingest` of what was buffered |

The hooks hold no enforcement: no filtering, no gating, no labels, no decision about what is
stored or returned. Redaction, the injection screen, the write gate, access control and the
audit log all run in the MemHouse engine, for a caller that uses the hooks and for one that
calls the API itself alike. Removing the hooks changes nothing about what is enforced.
"""

from __future__ import annotations

import json
import uuid
from typing import Any, Dict, List, Optional, Tuple

from ._generated import IngestRequest, IngestResult, Message, RecallResult, RememberRequest, RememberResult
from .client import MemHouse


class MemoryHooks:
    """The hooks of one conversation (`session_id`) about one `subject`.

    - `session_id`: groups the conversation's rounds; a new id when none is given.
    - `buffer_turns`: keep the turns in memory and send them in one `ingest` at session end,
      instead of one `ingest` per turn. A process that dies before `at_session_end` loses the
      buffered turns, which is why it is off by default.
    - `wait`: ask the API to answer with the write gate's decision instead of at once.
    - `source`: the source label of what the hooks write (the API's default when not given).
    """

    def __init__(
        self,
        client: MemHouse,
        subject: str,
        session_id: Optional[str] = None,
        *,
        buffer_turns: bool = False,
        wait: bool = False,
        source: Optional[str] = None,
    ) -> None:
        self.client = client
        self.subject = subject
        self.session_id = session_id or f"session-{uuid.uuid4()}"
        self.buffer_turns = buffer_turns
        self.wait = wait
        self.source = source
        self.last_recall: Optional[RecallResult] = None
        """The whole answer of the latest `before_model_call` (hits, ids, `recall_id`)."""
        self._buffer: List[Message] = []
        # A batch taken from the buffer and not yet known to be stored, with the idempotency
        # key it is sent under.
        self._pending: Optional[Tuple[str, List[Message]]] = None

    def before_model_call(self, query: str, **recall_options: Any) -> str:
        """Recall what is known for `query` and return it as a text block ready for the prompt.

        `recall_options` are further fields of the recall request (`k`, `kinds`, `tags`,
        `token_budget`, `render_format`, `scope`, ...). The whole answer is in `last_recall`.
        An empty string means nothing was recalled.
        """
        request: Dict[str, Any] = {"subject": self.subject, "query": query, "render": True}
        request.update(recall_options)
        result = self.client.recall(request)  # type: ignore[arg-type]
        self.last_recall = result
        return result.get("rendered") or ""

    def after_turn(self, user_message: str, assistant_message: str) -> Optional[IngestResult]:
        """Propose the finished turn as memory. Returns the API's answer, or `None` when the
        turn was buffered for `at_session_end`.

        A turn goes through `ingest`, not `remember`: `ingest` is the operation for a
        conversation. It stores the user message and the reply as one round (an episodic
        record of what was said), screens it for injection, groups it under the session id,
        and leaves extracting facts from it to the engine's background enrichment. `remember`
        proposes one statement that stands alone, which a raw turn is not.
        """
        round_: List[Message] = [{"role": "user", "content": user_message}, {"role": "assistant", "content": assistant_message}]
        if self.buffer_turns:
            self._buffer.extend(round_)
            return None
        return self._ingest(round_)

    def on_tool_result(self, tool_name: str, result: Any) -> RememberResult:
        """Propose a tool's result as a memory. `result` is sent as given: text as it is,
        anything else as JSON.

        A tool result goes through `remember`, not `ingest`: it is one statement from outside
        the conversation, not a user/assistant round, so it should pass the whole write
        pipeline (injection screen, statement gate, routing, duplicate check), and the caller
        gets the record's id and state back. A plan or a guess is then held as a candidate and
        an instruction to the agent is quarantined, by the engine.
        """
        # Compact, as JSON.stringify writes it: both SDKs send the same text for the same result.
        content = result if isinstance(result, str) else json.dumps(result, separators=(",", ":"), ensure_ascii=False)
        request: RememberRequest = {"subject": self.subject, "content": content, "source": self.source or f"tool:{tool_name}", "metadata": {"tool": tool_name, "session_id": self.session_id}}
        if self.wait:
            request["wait"] = True
        return self.client.remember(request)

    def at_session_end(self) -> Optional[IngestResult]:
        """The consolidation trigger: send the buffered turns in one `ingest` under the session
        id. Returns the API's answer, or `None` when nothing was buffered.

        The API has no separate consolidation route. A session is the unit of background
        enrichment: every `ingest` under a session id queues the session for it (when
        enrichment is on), so turns already sent by `after_turn` need nothing more here.

        A call that failed can be made again. The batch is sent under an idempotency key of
        its own, and a repeat sends the same batch under the same key, so the API stores it
        once even if the first request arrived and only its answer was lost. Turns buffered
        since go in a batch of their own after it (the answer returned is then the last one).
        """
        result: Optional[IngestResult] = None
        while True:
            if self._pending is None:
                if not self._buffer:
                    return result
                self._pending = (f"session-end-{uuid.uuid4()}", list(self._buffer))
                self._buffer.clear()
            key, messages = self._pending
            result = self._ingest(messages, key)
            # Let go only once the API has them.
            self._pending = None

    def _ingest(self, messages: List[Message], idempotency_key: Optional[str] = None) -> IngestResult:
        request: IngestRequest = {"subject": self.subject, "session_id": self.session_id, "messages": messages}
        if self.source:
            request["source"] = self.source
        if self.wait:
            request["wait"] = True
        return self.client.ingest(request, idempotency_key=idempotency_key)


__all__ = ["MemoryHooks"]
