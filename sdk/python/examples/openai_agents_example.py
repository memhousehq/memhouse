#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""An agent with MemHouse memory on the OpenAI Agents SDK: two conversations about one customer.

In the first the agent is told something and stores it with the `remember` tool. The second is
a new conversation: what MemHouse recalls for the question is added to the agent's instructions
before the model is called, so the agent can answer from memory.

    cd sdk/python
    uv run --python 3.12 --extra openai-agents python examples/openai_agents_example.py

It needs a MemHouse server: MEMHOUSE_URL (default http://127.0.0.1:7077) and MEMHOUSE_API_KEY.
The model is a stand-in that follows a script, so no model provider is called. To use a real
model, name it in EXAMPLE_MODEL; the Agents SDK reads its key from OPENAI_API_KEY:

    EXAMPLE_MODEL=<model name> uv run --python 3.12 --extra openai-agents python examples/openai_agents_example.py
"""

import asyncio
import os
import uuid
from typing import Any, List, Optional

from agents import Agent, Runner
from agents.testing import ModelCall, ModelStep, ScriptedModel, assistant_message, function_call

from memhouse import MemHouse
from memhouse.adapters.openai_agents import MemHouseMemory

INSTRUCTIONS = "You are a support agent. Store what the customer tells you that is worth keeping with the remember tool. Answer questions from what you know about the customer."
CONVERSATIONS = ["Our contract renews on 2027-03-01.", "When does our contract renew?"]


# ---- The model: the only part that differs between the stand-in and a real one. ----


def model(conversation: int) -> Any:
    """The model of the agent: the one EXAMPLE_MODEL names, or the stand-in."""
    return os.environ.get("EXAMPLE_MODEL") or stand_in_model(conversation)


def stand_in_model(conversation: int) -> ScriptedModel:
    """A scripted model: no provider, no key. It does what a model would be expected to."""

    def store_what_was_said(call: ModelCall) -> Any:
        return [function_call("remember", {"content": call.input[-1]["content"], "kind": None}, call_id="call-1")]

    def answer_from_instructions(call: ModelCall) -> Any:
        # The memories are the part of the instructions that the adapter added.
        known = (call.system_instructions or "").replace(INSTRUCTIONS, "").strip()
        return [assistant_message(f"From memory: {known}" if known else "I don't know that yet.")]

    if conversation == 0:
        return ScriptedModel([ModelStep.respond(store_what_was_said), [assistant_message("Thanks, I have noted that.")]])
    return ScriptedModel([ModelStep.respond(answer_from_instructions)])


# ---- The agent: the same code for either model. ----


async def converse(client: MemHouse, subject: str, conversation: int, message: str) -> str:
    # One MemHouseMemory per conversation: `wait` so that the next one sees what this one stored.
    memory = MemHouseMemory(client, subject, session_id=f"conversation-{conversation}", wait=True)
    agent = Agent(name="Support", instructions=INSTRUCTIONS, tools=list(memory.tools), model=model(conversation))
    # Tracing would upload the run to the model provider: off when there is none.
    config = memory.run_config(tracing_disabled="EXAMPLE_MODEL" not in os.environ)
    result = await Runner.run(agent, message, hooks=memory.run_hooks, run_config=config)
    await memory.end_session()
    return str(result.final_output)


async def run(client: MemHouse, subject: str) -> List[str]:
    answers = []
    for conversation, message in enumerate(CONVERSATIONS):
        answer = await converse(client, subject, conversation, message)
        print(f"user:  {message}\nagent: {answer}\n")
        answers.append(answer)
    return answers


def main(client: Optional[MemHouse] = None) -> List[str]:
    client = client or MemHouse()
    subject = f"example:openai-agents:{uuid.uuid4().hex[:12]}"
    try:
        return asyncio.run(run(client, subject))
    finally:
        client.forget({"subject": subject})  # the example leaves nothing behind


if __name__ == "__main__":
    main()
