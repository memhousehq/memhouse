<!-- SPDX-License-Identifier: Apache-2.0 -->
# MemHouse SDK for Python

The Python client for [MemHouse](https://github.com/memhousehq/memhouse), a governed memory
service for AI agents. Python 3.9 or newer, no runtime dependencies (HTTP goes through the
standard library).

```python
from memhouse import MemHouse, MemoryHooks

mh = MemHouse()  # MEMHOUSE_URL (default http://127.0.0.1:7077) and MEMHOUSE_API_KEY

mh.remember({"subject": "customer:acme", "content": "Acme renews on 2027-03-01", "wait": True})
answer = mh.recall({"subject": "customer:acme", "query": "when does Acme renew?", "render": True})
print(answer["rendered"])
```

- **Client.** `MemHouse` has one method per operation of the API (`remember`, `recall`, `revise`,
  `forget`, `ingest`, `get_memory`, `list_memories`, ...), with typed requests and responses.
  They are generated from the OpenAPI specification (`src/memhouse/_generated.py`, written by
  `cargo xtask sdk`; do not edit it). An error answer raises `MemHouseError` with the API's
  stable `code`, its message `error` and the HTTP `status`.
- **Hooks.** `MemoryHooks(client, subject, session_id=None)` gives an agent loop four calls:
  `before_model_call(query)` (recall, returns a prompt-ready block), `after_turn(user_message,
  assistant_message)` (ingest), `on_tool_result(tool_name, result)` (remember) and
  `at_session_end()` (sends buffered turns). They only call the API: nothing is enforced in them.
- **Embedded.** `MemHouse.embedded(path)` runs the Lite engine in this process instead of calling
  a server; it needs the package `memhouse-lite` (`bindings/python` of the repository).
- **Framework adapters.** Optional extras, for Python 3.10 or newer: `memhouse[openai-agents]`
  (`memhouse.adapters.openai_agents`, tested with `openai-agents` 0.26.0) and
  `memhouse[langgraph]` (`memhouse.adapters.langgraph`, tested with `langgraph` 1.2.24). Each
  gives the memory tools (`remember`, `recall`, `revise`, `forget`) and the lifecycle hooks in
  its framework's own form: run hooks and a model-input filter for the OpenAI Agents SDK; graph
  nodes and a `BaseStore` for LangGraph. They only call the client and the hooks: nothing is
  enforced in them. Examples are in [`examples/`](examples).

The full guide is [docs/sdk.md](../../docs/sdk.md).

## Development

```bash
uv sync                 # a virtual environment with pytest
uv run pytest           # offline tests; with MEMHOUSE_URL and MEMHOUSE_API_KEY set, the live ones too

# with the framework adapters (their tests are skipped when the framework is missing)
uv run --python 3.12 --extra openai-agents --extra langgraph pytest
uv run --python 3.12 --extra openai-agents --extra langgraph --with mypy mypy src tests conformance examples

# the examples, against a MemHouse server, with a stand-in model (no model provider, no key)
uv run --python 3.12 --extra openai-agents python examples/openai_agents_example.py
uv run --python 3.12 --extra langgraph python examples/langgraph_example.py
```

`conformance/driver.py` serves the profile conformance suite
([docs/conformance.md](../../docs/conformance.md#the-sdks)), and `driver_openai_agents.py` and
`driver_langgraph.py` serve it through the two adapters: `scripts/sdk-conformance.sh` from the
repository root runs the suite through this SDK and both adapters against a throwaway
deployment.
