#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The LangGraph adapter as a way into a deployment, for the profile conformance suite.

Speaks the protocol of `driver.py`. Each operation is carried out through the adapter
(`memhouse.adapters.langgraph`) by a compiled graph, with no model in the loop:

- `remember`, `recall`, `revise`, `forget`: a graph of one `ToolNode` with the adapter's tools,
  given an assistant message that carries the tool call, as a model would have produced it.
  The content of the resulting `ToolMessage`, JSON text, is the API's answer.
- `ingest`: a graph of the adapter's propose node, given the user message and the reply, with
  the session as the run's thread: the adapter's after-turn path. The API's answer is what the
  node writes to the state.

The deployment is the one at MEMHOUSE_URL with MEMHOUSE_API_KEY. Needs `memhouse[langgraph]`.
"""

import json
import sys
from typing import Any, Dict, Optional

from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.runnables import RunnableConfig
from langgraph.graph import END, START, MessagesState, StateGraph
from langgraph.prebuilt import ToolNode

from _serve import is_cleanup, one_round, serve, tool_arguments
from memhouse import MemHouse
from memhouse.adapters.langgraph import MemHouseMemory


class State(MessagesState, total=False):
    proposed: Dict[str, Any]


class Driver:
    def __init__(self, client: MemHouse) -> None:
        self.client = client
        # `revise` and `forget` name a record, not a subject: they go to the tools of the
        # subject the scenario is running on.
        self.subject: Optional[str] = None
        self.calls = 0

    def call(self, op: str, body: Dict[str, Any]) -> Any:
        if is_cleanup(op, body):
            return self.client.forget(body)  # type: ignore[arg-type]
        self.subject = body.get("subject") or self.subject
        if not self.subject:
            raise ValueError(f"{op} before any request named a subject")
        memory = MemHouseMemory(self.client, self.subject, wait=bool(body.get("wait")), result_key="proposed")
        return self.ingest(memory, body) if op == "ingest" else self.tool_call(memory, op, body)

    def tool_call(self, memory: MemHouseMemory, op: str, body: Dict[str, Any]) -> Any:
        tool = next(t for t in memory.tools if t.name == op)
        arguments = tool_arguments(body, list(tool.args))
        graph = StateGraph(State)
        # An error of the API fails the step instead of becoming a message for the model.
        graph.add_node("tools", ToolNode(memory.tools, handle_tool_errors=False))
        graph.add_edge(START, "tools")
        graph.add_edge("tools", END)
        self.calls += 1
        call = {"name": op, "args": arguments, "id": f"call-{self.calls}", "type": "tool_call"}
        state = graph.compile().invoke({"messages": [AIMessage(content="", tool_calls=[call])]})
        return json.loads(state["messages"][-1].content)

    def ingest(self, memory: MemHouseMemory, body: Dict[str, Any]) -> Any:
        user, reply = one_round(body)
        graph = StateGraph(State)
        graph.add_node("propose", memory.propose)
        graph.add_edge(START, "propose")
        graph.add_edge("propose", END)
        config: RunnableConfig = {"configurable": {"thread_id": body["session_id"]}} if body.get("session_id") else {}
        state = graph.compile().invoke({"messages": [HumanMessage(user), AIMessage(reply)]}, config=config)
        return state.get("proposed")


def main() -> int:
    client = MemHouse()
    try:
        return serve(Driver(client).call)
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
