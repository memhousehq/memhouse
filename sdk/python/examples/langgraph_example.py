#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""An agent with MemHouse memory as a LangGraph graph: two conversations about one customer.

    recall -> model -> (tools -> model)* -> propose

The recall node puts what MemHouse knows for the user's message into the state before the model
node runs; the propose node hands the finished turn to MemHouse after it. In the first
conversation the agent stores what it is told with the `remember` tool; the second is a new
thread, answered from memory.

    cd sdk/python
    uv run --python 3.12 --extra langgraph python examples/langgraph_example.py

It needs a MemHouse server: MEMHOUSE_URL (default http://127.0.0.1:7077) and MEMHOUSE_API_KEY.
The model is a stand-in function, so no model provider is called. To use a real model, name it
in EXAMPLE_MODEL and add the package `langchain-openai`, which reads its key from
OPENAI_API_KEY:

    EXAMPLE_MODEL=<model name> uv run --python 3.12 --extra langgraph --with langchain-openai python examples/langgraph_example.py
"""

import os
import uuid
from typing import Any, List, Optional, Sequence

from langchain_core.messages import AIMessage, AnyMessage, HumanMessage, SystemMessage, ToolMessage
from langchain_core.tools import BaseTool
from langgraph.graph import END, START, MessagesState, StateGraph
from langgraph.prebuilt import ToolNode, tools_condition

from memhouse import MemHouse
from memhouse.adapters.langgraph import SUBJECT_KEY, MemHouseMemory

INSTRUCTIONS = "You are a support agent. Store what the customer tells you that is worth keeping with the remember tool. Answer questions from what you know about the customer."
CONVERSATIONS = ["Our contract renews on 2027-03-01.", "When does our contract renew?"]


class State(MessagesState):
    memory: str  # what the recall node found, for the model's prompt


# ---- The model: the only part that differs between the stand-in and a real one. ----


def call_model(system: str, messages: Sequence[AnyMessage], tools: List[BaseTool]) -> AIMessage:
    """One model call: the model EXAMPLE_MODEL names, or the stand-in."""
    name = os.environ.get("EXAMPLE_MODEL")
    if not name:
        return stand_in_model(system, messages)
    from langchain_openai import ChatOpenAI  # type: ignore[import-not-found]

    reply: AIMessage = ChatOpenAI(model=name).bind_tools(tools).invoke([SystemMessage(system), *messages])
    return reply


def stand_in_model(system: str, messages: Sequence[AnyMessage]) -> AIMessage:
    """Not a model: no provider, no key. It does what a model would be expected to."""
    last = messages[-1]
    if isinstance(last, ToolMessage):
        return AIMessage("Thanks, I have noted that.")
    said = str(last.content)
    if not said.endswith("?"):
        return AIMessage("", tool_calls=[{"name": "remember", "args": {"content": said}, "id": "call-1", "type": "tool_call"}])
    known = system.replace(INSTRUCTIONS, "").strip()
    return AIMessage(f"From memory: {known}" if known else "I don't know that yet.")


# ---- The graph: the same for either model. ----


def build(client: MemHouse) -> Any:
    # No fixed subject: each run names its own in its config, so one graph serves every customer.
    # `wait` so that the next conversation sees what this one stored.
    memory = MemHouseMemory(client, wait=True)

    def model(state: State) -> Any:
        system = f"{INSTRUCTIONS}\n\n{state['memory']}" if state.get("memory") else INSTRUCTIONS
        return {"messages": [call_model(system, state["messages"], memory.tools)]}

    graph = StateGraph(State)
    graph.add_node("recall", memory.recall)
    graph.add_node("model", model)
    graph.add_node("tools", ToolNode(memory.tools))
    graph.add_node("propose", memory.propose)
    graph.add_edge(START, "recall")
    graph.add_edge("recall", "model")
    graph.add_conditional_edges("model", tools_condition, {"tools": "tools", END: "propose"})
    graph.add_edge("tools", "model")
    graph.add_edge("propose", END)
    return graph.compile()


def run(client: MemHouse, subject: str) -> List[str]:
    app = build(client)
    answers = []
    for conversation, message in enumerate(CONVERSATIONS):
        config = {"configurable": {SUBJECT_KEY: subject, "thread_id": f"conversation-{conversation}"}}
        state = app.invoke({"messages": [HumanMessage(message)]}, config=config)
        answer = str(state["messages"][-1].content)
        print(f"user:  {message}\nagent: {answer}\n")
        answers.append(answer)
    return answers


def main(client: Optional[MemHouse] = None) -> List[str]:
    client = client or MemHouse()
    subject = f"example:langgraph:{uuid.uuid4().hex[:12]}"
    try:
        return run(client, subject)
    finally:
        client.forget({"subject": subject})  # the example leaves nothing behind


if __name__ == "__main__":
    main()
