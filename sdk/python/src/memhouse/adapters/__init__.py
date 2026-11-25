# SPDX-License-Identifier: Apache-2.0
"""Adapters that put MemHouse into an agent framework (INT-05).

- `memhouse.adapters.openai_agents`: the OpenAI Agents SDK (install `memhouse[openai-agents]`).
- `memhouse.adapters.langgraph`: LangGraph (install `memhouse[langgraph]`).

Each needs its framework, and so Python 3.10 or newer; importing one without it raises an
`ImportError` that names the extra. Nothing is imported here, so `import memhouse` keeps working
without any of them.

An adapter is wiring only: memory tools and the lifecycle hooks in the framework's own form. It
calls the SDK client and `MemoryHooks` and holds no enforcement (no filtering, gating or label
logic): governance runs in the MemHouse engine (INT-03).
"""
