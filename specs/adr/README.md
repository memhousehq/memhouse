<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Architecture Decision Records

Use this directory for ADRs that record implementation decisions not already
settled by the blueprint specs.

| ADR | Decision |
| --- | --- |
| `0001-repo-automation-model.md` | How repository automation is structured. |
| `0002-l3-automation-boundary.md` | What autonomous agents may and may not decide. |
| `0003-embedded-postgres-pg0.md` | One data layer everywhere; pg0 as the local launcher. |
| `0004-multi-strategy-retrieval.md` | Candidate generation, fusion, and rerank as three seams under a deadline. |
| `0005-peer-inline-validation-over-mcp.md` | Validation questions attached to read-tool results. |
| `0006-entity-resolution.md` | Canonical referents resolved at dream-time, exposed through no public surface. |
| `0007-unattended-governance-consent.md` | Declared-account/deployment auto-grant of subject consent, off by default. |
| `0008-restricted-database-role-for-rls-enforcement.md` | A NOSUPERUSER NOBYPASSRLS role is what makes Postgres row-level security actually enforce. |
| `0009-scope-bounded-entity-cards.md` | Per-scope entity summaries are projections over governed statements, never content on the entity cache. |
| `0010-query-independent-retrieval-applicability.md` | Query-independent retrieval runs only for explicit temporal or blank-context requests. |
| `0011-scope-local-entity-card-labels.md` | A card names its referent with a surface form from its own scope, and recomputes the kind rather than reading the entity row. |
| `0012-deterministic-gate-a-evidence.md` | Gate A automates only schema-derived source evidence, never model confidence. |
| `0013-dream-time-knowledge-consolidation.md` | Dream-time merges corroborated facts and derives bounded set aggregates. |
| `0014-lifecycle-sweep-scheduling.md` | Cron starts Account-scoped, replay-safe expiry and revalidation runs. |

Conventions for future ADRs:

- Name files `NNNN-short-title.md`.
- Cite relevant `FR-*`, `AD-*`, `AINV-*`, or `NFR-*` anchors.
- Keep status explicit: `Proposed`, `Accepted`, `Superseded`, or `Rejected`.
- Do not use ADRs to override blueprint requirements without an explicit
  blueprint update in the same or a preceding PR.
- Longer design documents that fan out into an ADR live in `specs/design/`.
- ADRs are never published to the documentation site. If a decision changes
  what a user sees, update the affected page under `docs/` in the same patch.
