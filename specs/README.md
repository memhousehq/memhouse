<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# MemHouse design documentation

This tree holds everything design-facing: what MemHouse is meant to do, why it
is built the way it is, what has been decided, what is left, and how it is
measured and released. **It is not published.**

User-facing documentation — installation, usage, operations, and how the
running system behaves — lives in `docs/` and is published to
<https://memhousehq.github.io/memhouse/>. Do not put a spec, plan, ADR,
roadmap item, benchmark result, or design rationale there; do not put an
install step, an API parameter, or an operational procedure here.

Development process — workflow, branch and PR rules, required checks, review
expectations — lives in `CONTRIBUTING.md`. The agent and contributor operating
contract is `AGENTS.md`.

## Layout

| Path | Holds | Authoritative for |
| --- | --- | --- |
| `memory-system-product-blueprint.md` | Product positioning, sequencing, go-to-market context. | Product framing. |
| `memory-system-functional-requirements.md` | Functional requirements. | `FR-*` anchors. |
| `memory-system-architecture-and-nfr.md` | Architecture decisions and non-functional targets. | `AD-*`, `AINV-*`, `NFR-*` anchors. |
| `memory-system-evaluation-framework.md` | Evaluation methodology. | `EV-*` anchors. |
| `architecture/` | One implementation-facing note per capability, plus the target decomposition. | Reasoning behind the built system. |
| `adr/` | Architecture decision records: alternatives weighed, outcome chosen. | Decisions. |
| `design/` | Dated design documents that fan out into specific ADRs. | Design history. |
| `roadmap/beta-roadmap.md` | The only roadmap: outstanding work with acceptance criteria, the delivery workflow, and maintainer-owned GitHub setup. | What is left. |
| `implementation-status.md` | What actually runs today, its verification evidence, and its real limitations. | Evidence and debt. |
| `eval/` | Release matrix, deterministic thresholds, surface contract inventory, and recorded reports. | Evaluation evidence. |
| `observability/` | Measurement discipline, local collection, trace and log safety defaults. | How runs are measured. |
| `process/` | Semantic versioning policy and the release checklist. | Release process. |
| `security/` | Threat models, review notes, hardening checklists. | Security posture. |

## Anchors

`FR-*`, `AD-*`, `AINV-*`, `NFR-*`, and `EV-*` are stable review handles.
Preserve their meaning unless a task explicitly asks for a blueprint change.

Anchors belong in these documents, in commit messages, and in pull request
descriptions — never in source comments, which must stand on their own, and
never in `docs/`, which is user-facing prose.

## Files consumed by code

Three files here are read as data at runtime or in CI, so their paths and names
are part of the build rather than prose:

- `eval/release-suite.json` — the release evaluation matrix;
- `eval/deterministic-thresholds.json` — the committed guardrail floors;
- `eval/surface-contract-inventory.json` — which surfaces exist, are gated, or
  are unavailable.

The recorded reports under `eval/results/` are immutable historical evidence.
Do not rename or rewrite them.
