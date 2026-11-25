# SPDX-License-Identifier: Apache-2.0
"""MemHouse for LangGraph (the package `langgraph`).

    from langgraph.graph import END, START, MessagesState, StateGraph
    from memhouse import MemHouse
    from memhouse.adapters.langgraph import MemHouseMemory

    class State(MessagesState):
        memory: str                      # the recalled memories, for the model node's prompt

    memory = MemHouseMemory(MemHouse(), "customer:acme")
    graph = StateGraph(State)
    graph.add_node("recall", memory.recall)       # before the model node
    graph.add_node("model", call_model)           # yours: reads state["memory"]
    graph.add_node("propose", memory.propose)     # after it
    graph.add_edge(START, "recall"); graph.add_edge("recall", "model")
    graph.add_edge("model", "propose"); graph.add_edge("propose", END)

| Part | Form in LangGraph | API call |
|---|---|---|
| `MemHouseMemory.tools` | LangChain tools `remember`, `recall`, `revise`, `forget` (for `ToolNode`, `bind_tools`) | the operation of the same name |
| `MemHouseMemory.recall` | a node for before the model node | `recall`; the rendered memories go to the state |
| `MemHouseMemory.propose` | a node for after the model node | `ingest` of the turn |
| `MemHouseMemory.propose_tool_results` | a node for after the tool node | `remember` of each tool result |
| `MemHouseStore` | a `BaseStore`: search, get, replace and delete records by id | `recall`, `list_memories`, `get_memory`, `revise`, `forget` |

It is wiring only. Every part calls the SDK client or `MemoryHooks` and nothing is decided
here: what is stored, held, quarantined or returned is decided by the MemHouse engine (INT-03).

Needs `langgraph` (Python 3.10 or newer): install `memhouse[langgraph]`.
"""

from __future__ import annotations

import asyncio
import re
import uuid
from datetime import datetime, timezone
from typing import Any, Callable, Collection, Dict, Iterable, List, Optional, Sequence, Tuple, Union

try:
    from langchain_core.messages import AIMessage, AnyMessage, HumanMessage, ToolMessage
    from langchain_core.runnables import RunnableConfig
    from langchain_core.tools import BaseTool, StructuredTool
    from langgraph.store.base import BaseStore, GetOp, Item, ListNamespacesOp, Op, PutOp, Result, SearchItem, SearchOp
except ImportError as e:  # the framework is an optional extra
    raise ImportError("memhouse.adapters.langgraph needs LangGraph (Python 3.10 or newer): install `memhouse[langgraph]`") from e

from .._generated import ForgetResult, Memory, MemoryKind, RecallResult, RememberResult
from ..client import MemHouse, MemHouseError
from ..hooks import MemoryHooks
from . import _tools

SUBJECT_KEY = "memhouse_subject"
"""The key of a run's `config["configurable"]` that names the subject, when none is fixed."""


def _subject(fixed: Optional[str], config: Optional[RunnableConfig]) -> str:
    if fixed is not None:
        return fixed
    subject = ((config or {}).get("configurable") or {}).get(SUBJECT_KEY)
    if not isinstance(subject, str) or not subject:
        raise ValueError(f'no subject: give `subject=`, or set config["configurable"]["{SUBJECT_KEY}"] for the run')
    return subject


def memory_tools(client: MemHouse, subject: Optional[str] = None, *, wait: bool = False) -> List[BaseTool]:
    """The memory tools `remember`, `recall`, `revise` and `forget` as LangChain tools.

    They are bound to `subject`; without one, each call reads the subject from the run's
    `config["configurable"]["memhouse_subject"]`. Each is one API call and returns the API's
    answer (JSON text in the `ToolMessage`). `wait` asks the API for the write gate's decision in
    the answer of `remember` and `revise`.
    """

    def remember(content: str, kind: Optional[MemoryKind] = None, *, config: RunnableConfig) -> RememberResult:
        return client.remember(_tools.remember_request(_subject(subject, config), content, kind, wait))

    def recall(query: str, k: Optional[int] = None, *, config: RunnableConfig) -> RecallResult:
        return client.recall(_tools.recall_request(_subject(subject, config), query, k))

    def revise(id: str, content: str) -> RememberResult:
        return client.revise(_tools.revise_request(id, content, wait))

    def forget(id: str) -> ForgetResult:
        return client.forget(_tools.forget_request(id))

    remember.__doc__, recall.__doc__, revise.__doc__, forget.__doc__ = _tools.REMEMBER_DOC, _tools.RECALL_DOC, _tools.REVISE_DOC, _tools.FORGET_DOC
    return [StructuredTool.from_function(f, parse_docstring=True) for f in (remember, recall, revise, forget)]


class MemHouseMemory:
    """MemHouse for the graphs of an agent: the memory tools, and the lifecycle hooks as nodes.

    - `subject`: whose memory it is. Without one, each run names its own in
      `config["configurable"]["memhouse_subject"]`, so one compiled graph can serve many.
    - The session id of a run is its `config["configurable"]["thread_id"]`, when it has one.
    - `wait`, `source`: as for `MemoryHooks`; `wait` also applies to the tools.
    - `recall_options`: further fields of the recall node's request (`k`, `kinds`,
      `token_budget`, `render_format`, ...).
    - `messages_key`: the state key that holds the messages. `memory_key`: the state key the
      recall node writes the rendered memories to (an empty string when there are none).
    - `result_key`: a state key the propose node writes the API's answer to; nothing when `None`.
    - `tool_results`: which tools' results `propose_tool_results` proposes: `True` for every
      tool but the memory tools themselves, `False` for none, or the names of the tools.

    The nodes are synchronous functions of `(state, config)`: LangGraph runs them in a worker
    thread in an asynchronous graph. Turns are never buffered, so there is nothing to send at
    the end of a session.
    """

    def __init__(
        self,
        client: MemHouse,
        subject: Optional[str] = None,
        *,
        wait: bool = False,
        source: Optional[str] = None,
        recall_options: Optional[Dict[str, Any]] = None,
        messages_key: str = "messages",
        memory_key: str = "memory",
        result_key: Optional[str] = None,
        tool_results: Union[bool, Collection[str]] = True,
    ) -> None:
        self.client = client
        self.subject = subject
        self.wait = wait
        self.source = source
        self.recall_options: Dict[str, Any] = dict(recall_options or {})
        self.messages_key = messages_key
        self.memory_key = memory_key
        self.result_key = result_key
        self.tool_results = tool_results
        self.tools: List[BaseTool] = memory_tools(client, subject, wait=wait)

    def hooks(self, config: Optional[RunnableConfig] = None) -> MemoryHooks:
        """The `MemoryHooks` of one run: its subject, and its thread as the session."""
        thread = ((config or {}).get("configurable") or {}).get("thread_id")
        return MemoryHooks(self.client, _subject(self.subject, config), str(thread) if thread else None, wait=self.wait, source=self.source)

    def recall(self, state: Any, config: RunnableConfig) -> Dict[str, Any]:
        """Node for before the model node: recall for the latest user message and write the
        rendered memories to `memory_key`."""
        user, _ = _turn(state[self.messages_key])
        return {self.memory_key: self.hooks(config).before_model_call(user, **self.recall_options) if user else ""}

    def propose(self, state: Any, config: RunnableConfig) -> Dict[str, Any]:
        """Node for after the model node (on the path where it has answered): propose the turn,
        the latest user message and the assistant's reply to it, as memory."""
        user, reply = _turn(state[self.messages_key])
        # Without both there is no round to propose.
        if not user or not reply:
            return {}
        result = self.hooks(config).after_turn(user, reply)
        return {self.result_key: result} if self.result_key else {}

    def propose_tool_results(self, state: Any, config: RunnableConfig) -> Dict[str, Any]:
        """Node for after the tool node: propose each tool result it just added as a memory."""
        results: List[ToolMessage] = []
        for message in reversed(state[self.messages_key]):
            if not isinstance(message, ToolMessage):
                break
            results.append(message)
        hooks = self.hooks(config) if results else None
        for message in reversed(results):
            name = message.name or "tool"
            if hooks is not None and self._wants_result_of(name):
                hooks.on_tool_result(name, _tools.message_text(message.content))
        return {}

    def _wants_result_of(self, tool_name: str) -> bool:
        if isinstance(self.tool_results, bool):
            return self.tool_results and tool_name not in _tools.TOOL_NAMES
        return tool_name in self.tool_results


def _turn(messages: Sequence[AnyMessage]) -> Tuple[str, str]:
    """The latest user message, and the text of the last assistant message after it ("" for
    what is missing)."""
    reply: Optional[str] = None
    for message in reversed(messages):
        if isinstance(message, HumanMessage):
            return _tools.message_text(message.content), reply or ""
        if isinstance(message, AIMessage) and reply is None:
            reply = _tools.message_text(message.content)
    return "", reply or ""


class MemHouseStore(BaseStore):
    """A LangGraph `BaseStore` over MemHouse, as far as the two agree.

    A namespace is a subject: its labels joined with `:` (`("customer", "acme")` is
    `customer:acme`), or what `subject_of` makes of it. An item's key is the record's id, and
    its value the record as the API returns it (`content`, `kind`, `status`, `tags`, ...).

    | `BaseStore` | MemHouse |
    |---|---|
    | `search(namespace, query=...)` | `recall` in that subject, `limit` as `k`; items carry the hit's `score` |
    | `search(namespace)` | `list_memories` of that subject (current committed records) |
    | `get(namespace, key)` | `get_memory`; `None` when there is no such record in that subject |
    | `put(namespace, key, value)` | `revise` of the record `key`: `value["content"]` is the corrected text, its other entries are fields of the request |
    | `delete(namespace, key)` | `forget` of the record `key` |

    What MemHouse cannot express raises `NotImplementedError`:

    - `put` under a key that is not a record's id. MemHouse assigns ids, and a write is a
      proposal that the engine may deduplicate, hold or quarantine, so "store this value under
      my key" has no equivalent. Write new memories with `remember` here (not part of
      `BaseStore`), the `remember` tool or the propose node.
    - `put` with `index` or `ttl`; `search` with `filter` or `offset`; `list_namespaces` (use
      the client's `list_subjects`).
    - A search covers its namespace only, not the namespaces below it: subjects do not nest.
    """

    def __init__(self, client: MemHouse, *, subject_of: Optional[Callable[[Tuple[str, ...]], str]] = None, wait: bool = False) -> None:
        self.client = client
        self.subject_of: Callable[[Tuple[str, ...]], str] = subject_of or ":".join
        self.wait = wait

    def remember(self, namespace: Tuple[str, ...], content: str, **fields: Any) -> RememberResult:
        """Propose a new memory in the namespace's subject (`fields`: further fields of the
        `remember` request). The answer has the record's id, which is its key in this store."""
        request: Dict[str, Any] = {"subject": self.subject_of(tuple(namespace)), "content": content}
        if self.wait:
            request["wait"] = True
        request.update(fields)
        return self.client.remember(request)  # type: ignore[arg-type]

    def batch(self, ops: Iterable[Op]) -> List[Result]:
        return [self._run(op) for op in ops]

    async def abatch(self, ops: Iterable[Op]) -> List[Result]:
        # The client is synchronous: off the event loop.
        return await asyncio.get_running_loop().run_in_executor(None, self.batch, list(ops))

    def _run(self, op: Op) -> Result:
        if isinstance(op, GetOp):
            return self._get(op)
        if isinstance(op, SearchOp):
            return self._search(op)
        if isinstance(op, PutOp):
            self._put(op)
            return None
        if isinstance(op, ListNamespacesOp):
            raise NotImplementedError("MemHouseStore has no list_namespaces: namespaces are MemHouse subjects, listed by the client's list_subjects()")
        raise NotImplementedError(f"MemHouseStore has no operation {type(op).__name__}")

    def _get(self, op: GetOp) -> Optional[Item]:
        if not _is_id(op.key):
            return None
        try:
            memory = self.client.get_memory(op.key)
        except MemHouseError as e:
            if e.code == "not_found":
                return None
            raise
        # A record of another subject is not in this namespace.
        if memory.get("subject") != self.subject_of(tuple(op.namespace)):
            return None
        return _item(Item, tuple(op.namespace), memory)

    def _search(self, op: SearchOp) -> List[SearchItem]:
        if op.filter:
            raise NotImplementedError("MemHouseStore.search has no `filter`: MemHouse does not match records by the entries of a value. Use `query`, or the client's recall with `kinds`, `tags` or `exact`")
        if op.offset:
            raise NotImplementedError("MemHouseStore.search has no `offset`: a MemHouse recall is not paged. Use `limit`")
        namespace = tuple(op.namespace_prefix)
        subject = self.subject_of(namespace)
        if op.query is None:
            page = self.client.list_memories(subject, limit=op.limit)
            return [_item(SearchItem, namespace, memory) for memory in page["items"]]
        result = self.client.recall({"subject": subject, "query": op.query, "k": op.limit})
        return [_item(SearchItem, namespace, hit["memory"], score=hit.get("score")) for hit in result["hits"]]

    def _put(self, op: PutOp) -> None:
        if op.value is None:  # how BaseStore.delete arrives
            self.client.forget(_tools.forget_request(op.key))
            return
        if op.index is not None:
            raise NotImplementedError("MemHouseStore.put has no `index`: MemHouse indexes a record's text itself")
        if op.ttl is not None:
            raise NotImplementedError("MemHouseStore.put has no `ttl`: give `expires_at` in the value instead")
        content = op.value.get("content")
        if not isinstance(content, str):
            raise ValueError('MemHouseStore.put: the value needs the text under "content"')
        request: Dict[str, Any] = dict(op.value)
        request["id"] = op.key
        if self.wait:
            request.setdefault("wait", True)
        if _is_id(op.key):
            try:
                self.client.revise(request)  # type: ignore[arg-type]
                return
            except MemHouseError as e:
                if e.code != "not_found":
                    raise
        raise NotImplementedError(
            f"MemHouseStore.put can only replace a record MemHouse holds, and {op.key!r} is not the id of one. MemHouse assigns ids itself: "
            "write a new memory with MemHouseStore.remember(), the remember tool or the propose node"
        )


def _is_id(key: str) -> bool:
    """Whether `key` has the form of a record id (a UUID): no other key can name a record."""
    try:
        uuid.UUID(key)
    except ValueError:
        return False
    return True


def _item(cls: Any, namespace: Tuple[str, ...], memory: Memory, **more: Any) -> Any:
    # A record is one immutable version: it was last changed when it was created.
    at = _time(memory.get("created_at"))
    return cls(namespace=namespace, key=memory["id"], value=dict(memory), created_at=at, updated_at=at, **more)


def _time(text: Optional[str]) -> datetime:
    """An RFC 3339 time as a `datetime`. Python 3.10 reads neither `Z` nor a fraction that is
    not of three or six digits."""
    normal = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), (text or "").replace("Z", "+00:00"))
    try:
        return datetime.fromisoformat(normal)
    except ValueError:
        return datetime.fromtimestamp(0, timezone.utc)


__all__ = ["SUBJECT_KEY", "MemHouseMemory", "MemHouseStore", "memory_tools"]
