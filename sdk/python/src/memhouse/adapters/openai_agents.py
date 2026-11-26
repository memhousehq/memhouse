# SPDX-License-Identifier: Apache-2.0
"""MemHouse for the OpenAI Agents SDK (the package `openai-agents`).

    from agents import Agent, Runner
    from memhouse import MemHouse
    from memhouse.adapters.openai_agents import MemHouseMemory

    memory = MemHouseMemory(MemHouse(), "customer:acme", session_id="ticket-8812")
    agent = Agent(name="Support", instructions="...", tools=memory.tools)
    result = await Runner.run(agent, "When does Acme renew?", hooks=memory.run_hooks, run_config=memory.run_config())
    await memory.end_session()

`MemHouseMemory` is the memory of one conversation about one subject, in the framework's forms:

| Part | Form in the Agents SDK | API call |
|---|---|---|
| `tools` | function tools `remember`, `recall`, `revise`, `forget` | the operation of the same name |
| `recall_before_model_call` (set by `run_config()`) | `RunConfig.call_model_input_filter` | `recall`, added to the instructions |
| `run_hooks.on_agent_end` | `RunHooks` | `ingest` of the turn |
| `run_hooks.on_tool_end` | `RunHooks` | `remember` of a tool's result |
| `end_session()` | called by you: the framework has no such event | `ingest` of buffered turns |

It is wiring only. Every part calls the SDK client or `MemoryHooks` and nothing is decided
here: what is stored, held, quarantined or returned is decided by the MemHouse engine (INT-03).

There is no `Session` implementation. A `Session` must return a conversation's items exactly as
they were added, in order, and remove the latest one on request; MemHouse stores turns as
governed memory (screened, deduplicated, possibly quarantined), which is not that. Keep the
framework's own session for the transcript and use this for memory.

Needs `openai-agents` (Python 3.10 or newer): install `memhouse[openai-agents]`.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any, Collection, Dict, List, Optional, Union

try:
    from agents import Agent, AgentHookContext, FunctionTool, RunConfig, RunContextWrapper, RunHooks, Tool, default_tool_error_function, function_tool
    from agents.run import CallModelData, ModelInputData
except ImportError as e:  # the framework is an optional extra
    raise ImportError("memhouse.adapters.openai_agents needs the OpenAI Agents SDK (Python 3.10 or newer): install `memhouse[openai-agents]`") from e

from .._generated import IngestResult, MemoryKind
from ..client import MemHouse, MemHouseError
from ..hooks import MemoryHooks
from . import _tools


def memory_tools(client: MemHouse, subject: str, *, wait: bool = False) -> List[FunctionTool]:
    """The memory tools `remember`, `recall`, `revise` and `forget`, bound to `subject`.

    Each is one API call and returns the API's answer as JSON text. `wait` asks the API for the
    write gate's decision in the answer of `remember` and `revise`, so the model sees whether a
    memory was stored or held. An error answer of the API (an unknown id, say) reaches the
    model as text with the API's error code and message; any other failure as the framework's
    own tool-error message.
    """

    def remember(content: str, kind: Optional[MemoryKind] = None) -> str:
        return json.dumps(client.remember(_tools.remember_request(subject, content, kind, wait)))

    def recall(query: str, k: Optional[int] = None) -> str:
        return json.dumps(client.recall(_tools.recall_request(subject, query, k)))

    def revise(id: str, content: str) -> str:
        return json.dumps(client.revise(_tools.revise_request(id, content, wait)))

    def forget(id: str) -> str:
        return json.dumps(client.forget(_tools.forget_request(id)))

    remember.__doc__, recall.__doc__, revise.__doc__, forget.__doc__ = _tools.REMEMBER_DOC, _tools.RECALL_DOC, _tools.REVISE_DOC, _tools.FORGET_DOC
    # The functions are synchronous (the client is): the framework runs them in a worker thread.
    return [function_tool(f, failure_error_function=_api_error) for f in (remember, recall, revise, forget)]


def _api_error(context: RunContextWrapper[Any], error: Exception) -> str:
    """What the model is told when a memory tool fails. The framework's default hides every
    error; an error answer of the API is meant for the caller, so the model gets that one."""
    if isinstance(error, MemHouseError) and error.code != "transport":
        return f"MemHouse answered {error.code}: {error.error}"
    return default_tool_error_function(context, error)


class MemHouseMemory:
    """MemHouse for one conversation (`session_id`) of an agent about one `subject`.

    - `wait`, `source`, `buffer_turns`: as for `MemoryHooks`; `wait` also applies to the tools.
    - `recall_options`: further fields of the recall made before each model call (`k`, `kinds`,
      `token_budget`, `render_format`, ...).
    - `tool_results`: which tools' results are proposed as memory when they return: `True` for
      every tool but the memory tools themselves (their results are already memory), `False`
      for none, or the names of the tools.

    `hooks` is the `MemoryHooks` behind it; `hooks.last_recall` is the latest recall's whole
    answer and `last_turn` the API's answer to the latest proposed turn.
    """

    def __init__(
        self,
        client: MemHouse,
        subject: str,
        session_id: Optional[str] = None,
        *,
        wait: bool = False,
        source: Optional[str] = None,
        buffer_turns: bool = False,
        recall_options: Optional[Dict[str, Any]] = None,
        tool_results: Union[bool, Collection[str]] = True,
    ) -> None:
        self.hooks = MemoryHooks(client, subject, session_id, buffer_turns=buffer_turns, wait=wait, source=source)
        self.tools: List[FunctionTool] = memory_tools(client, subject, wait=wait)
        self.recall_options: Dict[str, Any] = dict(recall_options or {})
        self.tool_results = tool_results
        self.last_turn: Optional[IngestResult] = None
        self.run_hooks: RunHooks[Any] = _MemoryRunHooks(self)

    def run_config(self, **options: Any) -> RunConfig:
        """A `RunConfig` with `recall_before_model_call` as its `call_model_input_filter`;
        `options` are further fields of `RunConfig`."""
        return RunConfig(call_model_input_filter=self.recall_before_model_call, **options)

    async def recall_before_model_call(self, data: CallModelData[Any]) -> ModelInputData:
        """A `RunConfig.call_model_input_filter`: recall for the latest user message and add the
        rendered memories to the instructions of this model call. The input is left as it is;
        with nothing recalled, so are the instructions."""
        model_data = data.model_data
        query = _last_user_text(model_data.input)
        if not query:
            return model_data
        block = await asyncio.to_thread(self.hooks.before_model_call, query, **self.recall_options)
        if not block:
            return model_data
        instructions = f"{model_data.instructions}\n\n{block}" if model_data.instructions else block
        return ModelInputData(input=model_data.input, instructions=instructions)

    async def end_session(self) -> Optional[IngestResult]:
        """The end of the conversation: `MemoryHooks.at_session_end` (sends buffered turns)."""
        return await asyncio.to_thread(self.hooks.at_session_end)

    def _wants_result_of(self, tool_name: str) -> bool:
        if isinstance(self.tool_results, bool):
            return self.tool_results and tool_name not in _tools.TOOL_NAMES
        return tool_name in self.tool_results


class _MemoryRunHooks(RunHooks[Any]):
    """The run's lifecycle events that have a memory hook. Pass it as `Runner.run(..., hooks=)`."""

    def __init__(self, memory: MemHouseMemory) -> None:
        self.memory = memory

    async def on_tool_end(self, context: RunContextWrapper[Any], agent: Agent[Any], tool: Tool, result: object) -> None:
        if self.memory._wants_result_of(tool.name):
            await asyncio.to_thread(self.memory.hooks.on_tool_result, tool.name, _tools.text_of(result))

    async def on_agent_end(self, context: AgentHookContext[Any], agent: Agent[Any], output: Any) -> None:
        # The turn is the latest user message of the run's input and the agent's final output.
        # Without a user message there is no round to propose.
        user = _last_user_text(context.turn_input)
        if user:
            self.memory.last_turn = await asyncio.to_thread(self.memory.hooks.after_turn, user, _tools.text_of(output))


def _last_user_text(items: Any) -> str:
    """The text of the latest user message among the input items of a run."""
    if isinstance(items, str):
        return items
    for item in reversed(list(items or [])):
        if isinstance(item, dict) and item.get("role") == "user":
            return _tools.message_text(item.get("content"))
    return ""


__all__ = ["MemHouseMemory", "memory_tools"]
