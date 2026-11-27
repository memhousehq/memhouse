<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# MemHouse documentation

| Guide | Read it when you want to… |
|---|---|
| [API reference](api.md) | call MemHouse from code or an agent: REST, MCP, request and response examples, client snippets, deprecations |
| [API stability policy](api-stability.md) | know what can change in API v1 and what can't, how deprecation works, and how compatibility is checked |
| [Install](install.md) | get MemHouse: the install script, Homebrew, the container image, the Helm chart, Cargo, or a build from source; which platforms have a release binary |
| [Configuration reference](configuration.md) | change a setting: every key, its default, its environment variable, templates, recipes |
| [Operations guide](operations.md) | run it on a server or in the cloud: deployment, TLS, sizing, enrichment workers, backups, upgrades, monitoring, troubleshooting |
| [Governance and compliance](governance.md) | answer a security or privacy review: data flows, redaction, quarantine, erasure, audit chain, control mapping, known gaps |
| [Developer guide](development.md) | change MemHouse itself: crate layout, build and test, extension points, schema changes, benchmarking a change |
| [Architecture](architecture.md) | understand how recall, writes and enrichment work inside |
| [Memory types, scopes, promotion and sharing](memory-types.md) | use working memory in a session, scope memories and preferences, promote a note to a fact, or share one agent's memory with another |
| [The coding template](coding.md) | give a coding agent memory of a repository: memories linked to files, hooks for Claude Code and Gemini CLI, staleness when a file changes, revalidation, procedures learned from corrections |
| [The admin console](console.md) | look at memories, review candidates and quarantined records, manage principals and keys, see policy versions, evaluation results and the profile advisor; and know how its session, CSP and CORS allow-list work |
| [The Lite profile](lite.md) | run MemHouse without a database server: one SQLite file, `memhouse up --lite`, backup and restore, what Lite does not do |
| [Conformance kits](conformance.md) | write a store, model or authorizer adapter and prove it conforms; check that REST, MCP and the CLI behave the same |
| [Languages](languages.md) | enable more languages than English, see each language's support level, or write and test your own language pack |
| [Logical schema](schema.md) and [Memory Format](memory-format.md) | see what a record holds, its lifecycle, how upgrades work, and the export format with its conformance vectors |
| [Benchmarks](benchmarks.md) | see the results and reproduce them |
| [Roadmap](roadmap.md) | see what is planned next, goal by goal, and how each change is benchmarked |
| [Secrets](security/secrets.md) | handle credentials in development, CI and the cloud |
| [Supply chain](security/supply-chain.md) | verify a download (checksum, signature, provenance, SBOM), and see what protects a release |
| [Release guide](release.md) | cut a release: versioning, the pipeline job by job, the dry run, the maintainer's one-time setup |
| [Threat model](threat-model.md) and [security baseline](security/baseline.md) | review threats, controls and the AP-10 baseline every profile must keep |
| [Decision records](adr/README.md) | see why the stores, formats, queue, authorization, pooler and gRPC were chosen, with evidence |

Requirement IDs in the code and docs (`CORE-06`, `PR-3`, `TR-MS-01`) refer to the design
requirements the project was planned from; the [roadmap](roadmap.md) says which goal covers each.
