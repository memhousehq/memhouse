<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# SDKs: Python and TypeScript

MemHouse has two SDKs, with the same shape in both languages:

- a **client** with one method per operation of the [API](api.md), generated from the OpenAPI
  specification, with typed requests and responses;
- four **lifecycle hooks** for an agent loop, which only call the API (requirement INT-03);
- a pluggable **transport**: HTTP by default, or the [embedded Lite engine](lite.md#embedded-python-and-node)
  in your own process.

| | Python | TypeScript |
|---|---|---|
| Package | `memhouse` ([sdk/python](../sdk/python/README.md)) | `@memhouse/sdk` ([sdk/typescript](../sdk/typescript/README.md)) |
| Runtime | Python 3.9 or newer | Node.js 20 or newer (ESM), or any runtime with a global `fetch` |
| Runtime dependencies | none (`urllib` from the standard library) | none (the global `fetch`) |
| Calls | synchronous | `async` |

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [The client](#the-client)
- [Lifecycle hooks](#lifecycle-hooks)
- [The embedded transport](#the-embedded-transport)
- [Framework adapters](#framework-adapters)
- [How the clients are generated](#how-the-clients-are-generated)
- [Tests and the conformance run](#tests-and-the-conformance-run)

## Install

From release 2.0.0 the packages are `memhouse` on PyPI and `@memhouse/sdk` on npm
([install guide](install.md#sdks-and-embedded-bindings)). Until that release is out, install
them from a checkout of this repository:

```bash
uv add ./sdk/python                 # or: pip install ./sdk/python
```

```bash
cd sdk/typescript && pnpm install && pnpm build     # builds dist/
pnpm add /path/to/memhouse/sdk/typescript           # in your project
```

Both read the deployment's address and key from the environment:

| Variable | Meaning | Default |
|---|---|---|
| `MEMHOUSE_URL` | the server's base URL | `http://127.0.0.1:7077` |
| `MEMHOUSE_API_KEY` | a principal's API key, an agent token, or the bootstrap key ([authentication](api.md#conventions)) | none |

The key is sent as `Authorization: Bearer ...`. The SDKs never log it, print it or put it in an
error message.

## Quick start

A deployment to talk to: `memhouse up --lite && memhouse serve`, then `export
MEMHOUSE_API_KEY=$(memhouse key)`.

```python
from memhouse import MemHouse

mh = MemHouse()
written = mh.remember({"subject": "customer:acme", "content": "Acme renews on 2027-03-01", "wait": True})
print(written["status"])          # committed

answer = mh.recall({"subject": "customer:acme", "query": "when does Acme renew?", "render": True})
print(answer["rendered"])         # a text block ready for a prompt
```

```ts
import { MemHouse } from "@memhouse/sdk";

const mh = new MemHouse();
const written = await mh.remember({ subject: "customer:acme", content: "Acme renews on 2027-03-01", wait: true });
console.log(written.status); // committed

const answer = await mh.recall({ subject: "customer:acme", query: "when does Acme renew?", render: true });
console.log(answer.rendered); // a text block ready for a prompt
```

## The client

```python
MemHouse(base_url=None, api_key=None, *, user=None, actor=None, timeout=30.0, transport=None)
```

```ts
new MemHouse({ baseUrl?, apiKey?, user?, actor?, timeoutMs?, transport? })
```

- `base_url` / `baseUrl` is `http(s)://host[:port]`, with a path prefix when the API is served
  under one (`https://example.com/memhouse`). A URL with credentials in it, a query string or a
  fragment is refused, with a message that does not repeat the URL: the key goes in `api_key` /
  `apiKey` or `MEMHOUSE_API_KEY`. A key with a character an HTTP header cannot carry (a line
  break, a space, a control or non-ASCII character; in practice a trailing newline from a file)
  is refused when the client is built, with a message that does not repeat it. The key is sent
  to that origin only: a redirect to another
  origin is not followed by the Python client (the call fails with the redirect's status), and
  `fetch` drops the `Authorization` header when it follows one.
- `user` is the user every call acts for (the `x-memhouse-user` header), unless a call names
  another. `actor` is sent as `x-memhouse-actor`, which the API has ignored since 1.1.
- **One method per operation.** The method is the operation's id in the specification, in the
  language's own style: `remember`, `recall`, `revise`, `forget`, `ingest`, `get_memory` /
  `getMemory`, `list_memories` / `listMemories`, `review`, `promote`, `whoami`, and so on for
  all operations of [the reference](api.md). A method takes the path parameters first, then the
  request body as one object with the fields the reference lists, then the optional query and
  header parameters (keyword arguments in Python, an `options` object in TypeScript):

  ```python
  mh.remember({"subject": "customer:acme", "content": "Acme's champion is Priya"}, idempotency_key="crm-sync-8812")
  page = mh.list_memories("customer:acme", limit=20, include_inactive=True)
  ```

  ```ts
  await mh.remember({ subject: "customer:acme", content: "Acme's champion is Priya" }, { idempotencyKey: "crm-sync-8812" });
  const page = await mh.listMemories("customer:acme", { limit: 20, includeInactive: true });
  ```

  A path parameter is percent-encoded. One that is empty, `.` or `..` is refused before
  anything is sent (`ValueError`, `TypeError`): in a URL it would name another route.

- **Types.** Every schema of the specification is a type: a `TypedDict` in Python (a request
  is a plain `dict`, checked by a type checker), an interface in TypeScript. They are exported
  by `memhouse._generated` and by `@memhouse/sdk`.
- **Stability.** Each method's documentation says whether its operation is `stable`, `preview`
  or deprecated, as the [stability policy](api-stability.md) defines them. Deprecated
  operations are marked `@deprecated` in TypeScript.
- **Errors.** An error answer raises `MemHouseError` (Python) or rejects with one
  (TypeScript). It carries `status` (the HTTP status), `code` (the API's
  [stable code](api.md#errors): `invalid_request`, `unauthorized`, `forbidden`, `not_found`,
  `conflict`, `internal`, `unavailable`) and `error` (the message, for people). Branch on
  `code`. A request that got no answer at all has `status` 0 and the code `transport`.
- **A write is a proposal.** `remember` answers at once with `status: "candidate"`; the write
  gate decides in the background. Send `wait: true` to get the decision in the answer, or read
  it later with `get_memory` / `getMemory` ([how a write is decided](api.md#post-v1remember-propose-a-memory)).

### Transports

A transport carries one request and returns the status and the body's text. Anything with this
method can replace HTTP (a test double, a proxy, the embedded engine):

```python
def request(self, method: str, path: str, body: Optional[str], headers: Dict[str, str]) -> Tuple[int, str]: ...
```

```ts
request(method: string, path: string, body: string | null, headers: Record<string, string>): Promise<{ status: number; body: string }>;
```

`path` starts with `/` and includes the query string. Pass it as `transport=` /
`{ transport }`. An optional `close()` is called by the client's `close()`.

## Lifecycle hooks

`MemoryHooks` maps four moments of an agent's conversation to API calls:

| Hook | When to call it | What it does |
|---|---|---|
| `before_model_call(query, **recall_options)` / `beforeModelCall(query, recallOptions?)` | before each model call | `recall` with `render`: returns the memories as a text block for the prompt (an empty string when there are none). The whole answer is kept in `last_recall` / `lastRecall` |
| `after_turn(user_message, assistant_message)` / `afterTurn(...)` | when the assistant has answered | `ingest` of the round, under the session id |
| `on_tool_result(tool_name, result)` / `onToolResult(...)` | when a tool has returned something worth keeping | `remember` of the result (text as given, anything else as JSON), with the source `tool:<name>` |
| `at_session_end()` / `atSessionEnd()` | when the conversation is over | `ingest` of the turns that were buffered, in one call |

```python
from memhouse import MemHouse, MemoryHooks

hooks = MemoryHooks(MemHouse(), subject="customer:acme", session_id="ticket-8812")

known = hooks.before_model_call(user_message, k=8)
reply = call_your_model(system=f"What we know:\n{known}", user=user_message)
hooks.after_turn(user_message, reply)
hooks.on_tool_result("crm_lookup", "Acme is on the Enterprise plan.")
hooks.at_session_end()
```

```ts
import { MemHouse, MemoryHooks } from "@memhouse/sdk";

const hooks = new MemoryHooks(new MemHouse(), "customer:acme", "ticket-8812");

const known = await hooks.beforeModelCall(userMessage, { k: 8 });
const reply = await callYourModel({ system: `What we know:\n${known}`, user: userMessage });
await hooks.afterTurn(userMessage, reply);
await hooks.onToolResult("crm_lookup", "Acme is on the Enterprise plan.");
await hooks.atSessionEnd();
```

Options: `session_id` / `sessionId` (a new id when not given), `buffer_turns` / `bufferTurns`,
`wait` (ask for the write gate's decision in the answer) and `source` (the source label of what
the hooks write).

**Why a turn is ingested and a tool result is remembered.** [`ingest`](api.md#post-v1ingest-store-a-conversation-as-episodic-memory)
is the operation for a conversation: it stores the user message and the reply as one round, an
episodic record of what was said, screened for injection, grouped under the session id, with
fact extraction left to background enrichment. A tool result is one statement from outside the
conversation, so it goes through [`remember`](api.md#post-v1remember-propose-a-memory) and the
whole write pipeline: the injection screen, the statement gate (a plan or a guess is held as a
candidate), routing and the duplicate check, with the record's id and state in the answer.

**The session end.** The API has no separate consolidation route. A session is the unit of
background enrichment: every `ingest` under a session id queues that session for it, when
enrichment is on. So by default, where `after_turn` sends each turn as it happens,
`at_session_end` has nothing left to send and calls nothing. With `buffer_turns`, the turns are
kept in memory and `at_session_end` sends the whole conversation in one `ingest`; a process that
stops before then loses them, which is why buffering is off by default.

If that `ingest` fails, call `at_session_end` again. The batch is sent under an
[idempotency key](api.md#conventions) of its own and a repeat sends the same batch under the
same key, so it is stored once even when the first request arrived and only its answer was
lost. Turns buffered since then follow in a batch of their own. In TypeScript, where calls can
overlap, one flush runs at a time: an `atSessionEnd` called while another is under way resolves
with that one's outcome, and no buffered turn is sent twice or dropped.

### The hooks hold no enforcement

The hooks contain no filtering, no gating and no label logic: each one builds a request and
calls the API. Redaction, the injection screen, the write gate, access control, retention and
the audit log run in the MemHouse engine, on every request, for a caller that uses the hooks and
for one that does not. Removing the hooks, or calling the API in some other way, changes nothing
about what is enforced.

Each SDK tests this in two ways:

- with a recording transport, every hook issues exactly the one expected API call and passes
  what it was given unchanged, an injection attempt included;
- against a live deployment, an injection attempt and a plan are written once through the hooks
  and once through the bare client. Both times the injection attempt is quarantined and never
  recalled, and the plan is held as a candidate.

## The embedded transport

`MemHouse.embedded` runs the Lite engine inside your process instead of calling a server: one
SQLite file, no socket. It is the same API and the same engine, so the same governance applies
([Lite, embedded](lite.md#embedded-python-and-node)).

```python
with MemHouse.embedded("/home/ada/.memhouse/memhouse.db") as mh:   # MemHouse.embedded(path=None, config=None)
    mh.remember({"subject": "user:ada", "content": "Ada prefers tea", "wait": True})
```

```ts
const mh = await MemHouse.embedded({ path: "/home/ada/.memhouse/memhouse.db" }); // { path?, config? }
await mh.remember({ subject: "user:ada", content: "Ada prefers tea", wait: true });
await mh.close();
```

It needs the binding for the language: the Python module `memhouse_lite`
([bindings/python](../bindings/python/README.md)) or the Node.js package `@memhouse/lite`
([bindings/node](../bindings/node/README.md)). Without it, `embedded` fails with a message that
names the package. The SDK sends no key to the embedded engine; the binding uses the
deployment's own. Call `close()` when done: it stops the engine's background workers and
releases the file.

## Framework adapters

The Python SDK has adapters for two agent frameworks. An adapter gives the memory tools and the
lifecycle hooks the form its framework expects, so that an agent built with it gets MemHouse
memory without writing the glue. More adapters are planned in roadmap goal G23.

| Framework | Module | Extra | Tested with |
|---|---|---|---|
| [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/) | `memhouse.adapters.openai_agents` | `memhouse[openai-agents]` | `openai-agents` 0.26.0 |
| [LangGraph](https://langchain-ai.github.io/langgraph/) | `memhouse.adapters.langgraph` | `memhouse[langgraph]` | `langgraph` 1.2.24 (`langchain-core` 1.8.4) |

```bash
uv add "./sdk/python[openai-agents]"      # or [langgraph], or both
```

The frameworks need **Python 3.10 or newer**, and so do the adapters; the rest of the SDK keeps
working on 3.9 and still has no dependencies. Importing an adapter without its framework raises
an `ImportError` that names the extra. The versions in the table are the ones the adapters were
tested with (on Python 3.12), and the lowest the extras accept.

**Adapters hold no enforcement.** An adapter only calls the SDK's client and `MemoryHooks`: it
builds a request from what the framework hands it and returns the API's answer. It has no
filtering, gating or label logic. Whether a memory is stored, held as a candidate, quarantined
or returned by a recall is decided by the MemHouse engine, exactly as for a caller that uses the
API directly ([the hooks hold no enforcement](#the-hooks-hold-no-enforcement)). The
[conformance run](#tests-and-the-conformance-run) shows it: the profile scenario gives the same
outcome at every step through each adapter as through plain REST.

Both adapters offer the same four **memory tools** to the model: `remember(content, kind?)`,
`recall(query, k?)`, `revise(id, content)` and `forget(id)`. Each is one API call of the same
name on the subject the tools are bound to, and returns the API's answer as JSON. With
`wait=True` the answer of `remember` and `revise` carries the write gate's decision, so the
model sees whether its memory was stored or held. There is no tool that erases a whole subject.

### OpenAI Agents SDK

`MemHouseMemory(client, subject, session_id=None, *, wait=False, source=None,
buffer_turns=False, recall_options=None, tool_results=True)` is the memory of one conversation
about one subject:

| Part | What it is in the Agents SDK | What it does |
|---|---|---|
| `memory.tools` | function tools (`FunctionTool`) | the four memory tools. Also `memory_tools(client, subject, wait=False)` on its own |
| `memory.run_config(**options)` | a `RunConfig` whose `call_model_input_filter` is `memory.recall_before_model_call` | before each model call: `recall` for the latest user message; the rendered memories are added to the instructions of that call |
| `memory.run_hooks` | `RunHooks`, for `Runner.run(..., hooks=)` | `on_agent_end`: `ingest` of the turn (the latest user message and the final output). `on_tool_end`: `remember` of a tool's result |
| `await memory.end_session()` | called by you: the framework has no such event | `ingest` of the turns buffered with `buffer_turns` |

```python
from agents import Agent, Runner
from memhouse import MemHouse
from memhouse.adapters.openai_agents import MemHouseMemory

memory = MemHouseMemory(MemHouse(), "customer:acme", session_id="ticket-8812")
agent = Agent(name="Support", instructions="You are a support agent.", tools=[*memory.tools, crm_lookup])

result = await Runner.run(agent, "When does Acme renew?", hooks=memory.run_hooks, run_config=memory.run_config())
await memory.end_session()
```

- `tool_results` says which tools' results are proposed as memory: `True` (the default) for
  every tool except the memory tools themselves, `False` for none, or a list of tool names.
- `recall_options` are further fields of the recall request (`k`, `kinds`, `token_budget`,
  `render_format`, ...). `memory.hooks` is the `MemoryHooks` behind it; `memory.last_turn` is
  the API's answer to the latest proposed turn.
- The recall runs before every model call of a run, so a run with tool calls recalls more than
  once, with the same query.
- An error answer of the API in a tool (an unknown id, say) is given to the model as text with
  the API's error code and message. Any other failure gets the framework's own tool-error text.
- There is **no `Session` implementation**. A `Session` has to return a conversation's items
  exactly as they were added and remove the latest on request. MemHouse stores turns as governed
  memory (screened, deduplicated, possibly quarantined), which is something else. Keep the
  framework's own session for the transcript, and use the adapter for memory.

Example: [`sdk/python/examples/openai_agents_example.py`](../sdk/python/examples/openai_agents_example.py).

### LangGraph

`MemHouseMemory(client, subject=None, *, wait=False, source=None, recall_options=None,
messages_key="messages", memory_key="memory", result_key=None, tool_results=True)` gives the
tools and the hooks as graph nodes:

| Part | What it is in LangGraph | What it does |
|---|---|---|
| `memory.tools` | LangChain tools, for `ToolNode` and `bind_tools` | the four memory tools. Also `memory_tools(client, subject=None, wait=False)` on its own |
| `memory.recall` | a node for before the model node | `recall` for the latest user message; writes the rendered memories to the state key `memory_key` (an empty string when there are none) |
| `memory.propose` | a node for after the model node, on the path where it has answered | `ingest` of the turn: the latest user message and the assistant's reply. With `result_key`, the API's answer is written to that state key |
| `memory.propose_tool_results` | a node for after the tool node | `remember` of each tool result the tool node just added (`tool_results` as above) |

```python
from langgraph.graph import END, START, MessagesState, StateGraph
from memhouse import MemHouse
from memhouse.adapters.langgraph import MemHouseMemory

class State(MessagesState):
    memory: str                                   # written by the recall node

memory = MemHouseMemory(MemHouse(), "customer:acme")

def model(state: State):
    reply = call_your_model(system=f"What we know:\n{state['memory']}", messages=state["messages"])
    return {"messages": [reply]}

graph = StateGraph(State)
graph.add_node("recall", memory.recall)
graph.add_node("model", model)
graph.add_node("propose", memory.propose)
graph.add_edge(START, "recall")
graph.add_edge("recall", "model")
graph.add_edge("model", "propose")
graph.add_edge("propose", END)
app = graph.compile()
```

- **Subject and session.** With `subject=None`, each run names its subject in
  `config["configurable"]["memhouse_subject"]`, so one compiled graph serves many subjects. The
  session id is the run's `thread_id`, when it has one.
- The nodes are synchronous functions of `(state, config)`; LangGraph runs them in a worker
  thread in an asynchronous graph. Turns are never buffered, so there is nothing to do at the
  end of a session.

**`MemHouseStore(client, *, subject_of=None, wait=False)`** is a LangGraph `BaseStore` over
MemHouse, as far as the two agree. A namespace is a subject (its labels joined with `:`, or
what `subject_of` returns for it), an item's key is the record's id, and its value is the
record as the API returns it:

| `BaseStore` | MemHouse |
|---|---|
| `search(namespace, query=..., limit=...)` | `recall` in that subject; each item has the hit's `score` |
| `search(namespace)` | the subject's current records ([`list_memories`](api.md)) |
| `get(namespace, key)` | the record with that id; `None` when the subject has no such record |
| `put(namespace, key, value)` | `revise` of the record `key`, when the subject has it: `value["content"]` is the corrected text, the other entries are fields of the request |
| `delete(namespace, key)` | `forget` of the record `key`, when the subject has it; nothing otherwise |

- **One namespace, one subject.** Labels joined with `:` must not be empty or contain `:`
  themselves (`ValueError`): `("customer", "a:b")` and `("customer:a", "b")` would be the same
  subject, and each would read and change the other's records. For namespaces of another form
  give `subject_of`; it must map different namespaces to different subjects.
- **The namespace is part of the address.** `get`, `put` and `delete` read the record first
  and touch it only when it belongs to the namespace's subject, also when the client's key
  could reach the other subject.
- **A corrected record gets a new key.** MemHouse keeps versions: `revise` stores the corrected
  text as a new record with a new id and marks the old one superseded. After `put`, the old
  key still names the old version (`get` returns it with `status: "superseded"`, and a second
  `put` to it fails with the API's `conflict`), and `BaseStore.put` returns nothing. To correct
  a record and get the new key, call `store.revise(namespace, key, content, **fields)` (not
  part of `BaseStore`): its answer's `id` is the new version. `search` also finds it.

A `BaseStore` is a key-value store, and MemHouse is not one. What cannot be expressed raises
`NotImplementedError` instead of being imitated:

- **`put` under a key of your own.** MemHouse assigns the ids, and a write is a proposal that
  the engine may deduplicate, hold or quarantine. So "store this value under my key" has no
  equivalent: `put` only replaces a record that exists. Write new memories with
  `store.remember(namespace, content, **fields)` (not part of `BaseStore`), the `remember` tool
  or the propose node.
- `put` with `index` or `ttl`, `search` with `filter` or `offset`, and `list_namespaces` (use
  the client's `list_subjects`).
- A search covers its own namespace only, not the namespaces below it: subjects do not nest.

Code written for another `BaseStore` that stores items under its own keys therefore does not
run unchanged on this one.

Example: [`sdk/python/examples/langgraph_example.py`](../sdk/python/examples/langgraph_example.py).

### The examples

Each example is two short conversations about one customer: the agent is told something and
stores it with the `remember` tool, then answers a question in a new conversation from what
MemHouse recalled. They run against a MemHouse server (`MEMHOUSE_URL`, `MEMHOUSE_API_KEY`) and
erase their subject when done:

```bash
cd sdk/python
uv run --python 3.12 --extra openai-agents python examples/openai_agents_example.py
uv run --python 3.12 --extra langgraph python examples/langgraph_example.py
```

The model is a stand-in that follows a script, so no model provider is called and no key is
needed. The model call is one function in each example. To use a real model, name it in
`EXAMPLE_MODEL`; the framework reads your key from `OPENAI_API_KEY` (the LangGraph example
then also needs the package `langchain-openai`: add `--with langchain-openai`).

## How the clients are generated

`cargo xtask sdk` reads [`api/openapi.json`](../api/openapi.json), the published specification,
and writes the low-level clients:

- `sdk/python/src/memhouse/_generated.py`
- `sdk/typescript/src/generated.ts`

Each has one type per schema and one method per operation, with the specification's
descriptions, stability and deprecation notes as documentation. The generator is part of this
repository (`xtask/src/sdk.rs`): no external tool and no network. Its output is deterministic.
A schema construct it cannot express becomes a permissive type (`Any`, `unknown`).

The generated files are committed and must not be edited. `cargo xtask sdk --check` fails when
they differ from what the specification gives, and `cargo xtask ci` runs that check: an API
change without regenerated SDKs does not pass CI ([changing the API](development.md#change-the-api)).

The hand-written parts are small: the client's transport and error handling (`client.py`,
`client.ts`), the hooks (`hooks.py`, `hooks.ts`) and the Python
[framework adapters](#framework-adapters) (`adapters/`).

## Tests and the conformance run

```bash
(cd sdk/python && uv run pytest)                        # Python
(cd sdk/typescript && pnpm install && pnpm test)        # TypeScript: type check, build, node --test
```

Without a deployment these run the offline tests. With `MEMHOUSE_URL` and `MEMHOUSE_API_KEY` set
they also run the live test of the hooks (it writes under subjects of its own, `sdk-hooks:...`,
and erases them).

The tests of the [framework adapters](#framework-adapters) are skipped when their framework is
not installed. To run them, and to type-check the package with the frameworks in place:

```bash
cd sdk/python
uv run --python 3.12 --extra openai-agents --extra langgraph pytest
uv run --python 3.12 --extra openai-agents --extra langgraph --with mypy mypy src tests conformance examples
```

Offline they check, with a recording transport, the API calls each tool, hook, node and store
operation makes, and that a whole run or graph with a stand-in model makes those and no other.
With a deployment they also run the two examples and the LangGraph store against it.

The **conformance run** puts both SDKs and both framework adapters through the
[profile scenario](conformance.md#the-profile-suite) against a live deployment, next to plain
REST:

```bash
cargo build --release -p memhouse-cli
scripts/sdk-conformance.sh
```

The script starts a throwaway Lite deployment (a temporary `MEMHOUSE_HOME`; your own deployment
is not touched), runs the scenario through REST, the Python SDK, the TypeScript SDK, the OpenAI
Agents SDK adapter and the LangGraph adapter, then each SDK's tests with the live ones (the
Python ones a second time with the framework extras). It needs `python3`, `uv`, `node` and
`pnpm`; `uv` builds the adapters' environment from `sdk/python/uv.lock` on Python 3.12, which
downloads the two frameworks the first time. It fails on any unmet expectation, any difference
between the ways, and any failed test. With
`MEMHOUSE_URL` and `MEMHOUSE_API_KEY` set it uses that deployment instead; `--embedded` adds a
run of the scenario through both SDKs over the embedded bindings, which must be built.
Details: [conformance.md](conformance.md#the-sdks).
