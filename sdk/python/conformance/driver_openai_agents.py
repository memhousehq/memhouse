#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The OpenAI Agents SDK adapter as a way into a deployment, for the profile conformance suite.

Speaks the protocol of `driver.py`. Each operation is carried out through the adapter
(`memhouse.adapters.openai_agents`) the way the framework invokes it, with no model in the
loop:

- `remember`, `recall`, `revise`, `forget`: the function tool's `on_invoke_tool` with a tool
  context and the arguments as JSON text, as the runner calls it for a model's tool call. The
  tool's output, JSON text, is the API's answer.
- `ingest`: the run hook `on_agent_end` with the user message as the run's input and the reply
  as the agent's final output: the adapter's after-turn path. The API's answer is the
  adapter's `last_turn`.

The deployment is the one at MEMHOUSE_URL with MEMHOUSE_API_KEY. Needs `memhouse[openai-agents]`.
"""

import asyncio
import json
import sys
from typing import Any, Dict, Optional

from agents import Agent, AgentHookContext
from agents.tool_context import ToolContext

from _serve import is_cleanup, one_round, serve, tool_arguments
from memhouse import MemHouse
from memhouse.adapters.openai_agents import MemHouseMemory

AGENT: Agent[Any] = Agent(name="profile-suite")


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
        memory = MemHouseMemory(self.client, self.subject, body.get("session_id"), wait=bool(body.get("wait")))
        return asyncio.run(self.ingest(memory, body) if op == "ingest" else self.tool_call(memory, op, body))

    async def tool_call(self, memory: MemHouseMemory, op: str, body: Dict[str, Any]) -> Any:
        tool = next(t for t in memory.tools if t.name == op)
        arguments = json.dumps(tool_arguments(body, list(tool.params_json_schema["properties"])))
        self.calls += 1
        context: ToolContext[Any] = ToolContext(context=None, tool_name=tool.name, tool_call_id=f"call-{self.calls}", tool_arguments=arguments)
        output = await tool.on_invoke_tool(context, arguments)
        try:
            return json.loads(output)
        except ValueError:
            # The framework's tool-error message, which is what the model would get.
            raise RuntimeError(str(output)) from None

    async def ingest(self, memory: MemHouseMemory, body: Dict[str, Any]) -> Any:
        user, reply = one_round(body)
        context: AgentHookContext[Any] = AgentHookContext(context=None, turn_input=[{"role": "user", "content": user}])
        await memory.run_hooks.on_agent_end(context, AGENT, reply)
        return memory.last_turn


def main() -> int:
    client = MemHouse()
    try:
        return serve(Driver(client).call)
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
