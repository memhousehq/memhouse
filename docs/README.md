<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# MemHouse documentation

| Guide | Read it when you want to… |
|---|---|
| [API reference](api.md) | call MemHouse from code or an agent: REST, MCP, request and response examples, client snippets |
| [Configuration reference](configuration.md) | change a setting: every key, its default, its environment variable, templates, recipes |
| [Operations guide](operations.md) | run it on a server or in the cloud: deployment, TLS, sizing, enrichment workers, backups, upgrades, monitoring, troubleshooting |
| [Governance and compliance](governance.md) | answer a security or privacy review: data flows, redaction, quarantine, erasure, audit chain, control mapping, known gaps |
| [Developer guide](development.md) | change MemHouse itself: crate layout, build and test, extension points, schema changes, benchmarking a change |
| [Architecture](architecture.md) | understand how recall, writes and enrichment work inside |
| [Benchmarks](benchmarks.md) | see the results and reproduce them |
| [Roadmap](roadmap.md) | see what is planned next, goal by goal, and how each change is benchmarked |
| [Secrets](security/secrets.md) | handle credentials in development, CI and the cloud |
| [Threat model](threat-model.md) and [security baseline](security/baseline.md) | review threats, controls and the AP-10 baseline every profile must keep |
| [Decision records](adr/README.md) | see why the stores, formats, queue, authorization, pooler and gRPC were chosen, with evidence |

Design documents written before the code are in [`design/`](design/).
