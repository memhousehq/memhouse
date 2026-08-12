<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# MemHouse design documentation

The source and its tests are the specification of what MemHouse does. This tree
holds only what running code cannot state: why a decision was made, what is not
built yet, how a release is measured, and what the security posture is. **It is
not published.**

Do not add a document here that describes implemented behavior. It will drift
from the code, and the code will still be right.

User-facing documentation — installation, usage, operations, and how the
running system behaves — lives in `docs/` and is published to
<https://memhousehq.github.io/memhouse/>.

Development process — workflow, branch and PR rules, required checks, review
expectations — lives in `CONTRIBUTING.md`. The agent and contributor operating
contract is `AGENTS.md`, which also carries the product invariants and the
architecture boundaries.

## Layout

| Path | Holds | Authoritative for |
| --- | --- | --- |
| `adr/` | Architecture decision records: alternatives weighed, outcome chosen. | Decisions, and what they rule out. |
| `roadmap/beta-roadmap.md` | The only roadmap: outstanding work with acceptance criteria, the delivery workflow, and maintainer-owned GitHub setup. | What is left. |
| `architecture/` | Module boundaries and contracts that span more code than one module can show. | Where the seams are. |
| `eval/` | Release matrix, deterministic thresholds, surface contract inventory, and recorded reports. | Evaluation evidence. |
| `observability/` | Measurement discipline, local collection, trace and log safety defaults. | How runs are measured. |
| `process/` | Semantic versioning policy and the release checklist. | Release process. |
| `security/` | Threat models, review notes, hardening checklists. | Security posture. |

## Writing an ADR

Write one when a decision closes off an alternative that someone would
otherwise re-propose. The value is the rejected option and the reason, not the
chosen one — the code already shows that.

Do not write an ADR to record what the code says.

## Contract identities

Strings such as `f7-1` and `memhouse-account-1` version public contracts. They
are listed in `AGENTS.md` and in the published contract reference. They are not
phase labels. Never rename one as incidental cleanup.

## Files consumed by code

Three files here are read as data at runtime or in CI, so their paths and names
are part of the build rather than prose:

- `eval/release-suite.json` — the release evaluation matrix;
- `eval/deterministic-thresholds.json` — the committed guardrail floors;
- `eval/surface-contract-inventory.json` — which surfaces exist, are gated, or
  are unavailable.

The recorded reports under `eval/results/` are immutable historical evidence.
Do not rename or rewrite them.
