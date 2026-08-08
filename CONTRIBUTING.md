# Contributing to MemHouse

Use one scoped task, one branch, and one pull request. Humans remain the merge
gate.

## Before you edit

1. Read `AGENTS.md`.
2. Read the closest requirement anchors, architecture note, tests, and user
   guide.
3. Check `specs/implementation-status.md` for current behavior and
   `specs/roadmap/beta-roadmap.md` for outstanding work.
4. Inspect the worktree and preserve unrelated changes.

Do not change the meaning of existing `FR-*`, `AD-*`, `AINV-*`, `NFR-*`, or
`EV-*` anchors unless the task calls for a blueprint change.

## Keep changes focused

- Implement only the approved task and its acceptance criteria.
- Put durable writes behind Ash actions.
- Keep migrations and resource snapshots synchronized with `mix ash.codegen`.
- Update code, tests, docs, fixtures, and ADRs together when behavior changes.
- Do not add automation, governance, licensing, or later-roadmap work as
  incidental cleanup.
- Never overwrite another contributor's work.

For coding agents, the task must be labeled `ai-ready` unless a human directly
requests the work.

Query-analysis rules must be justified by shipped behavior. Do not fit
vocabulary, transformations, or ranking rules to a reporting evaluation split.

## Write concise code documentation

Source must stand on its own, but it should not read like a design document.

- Module docs state purpose, ownership, key guarantees, and caller traps.
- Public function docs state purpose, non-obvious inputs, return shape, and
  failures.
- Comments explain a non-obvious reason or constraint. Delete narration.
- State enforced rules in place; do not send readers to a spec for meaning.
- Keep examples short and remove repeated summaries or warnings.
- Do not use retired phase labels. Historical contract strings such as `f7-1`
  remain unchanged.

See `AGENTS.md` for the full writing style and architecture guardrails.

## Put documentation in the right place

| Location | Content |
| --- | --- |
| `docs/` | Published setup, usage, operations, and current behavior |
| `specs/` | Requirements, architecture, ADRs, plans, and evidence |
| `CONTRIBUTING.md` | Development workflow |
| `README.md` | Project orientation |

Do not put design history in `docs/`, or leave user procedures only in specs or
source comments. User docs do not cite blueprint anchors. Add new docs pages to
`mkdocs.yml`; use absolute GitHub URLs for links from `docs/` outside that tree.

Behavior and documentation ship together. Common mappings:

| Change | Update |
| --- | --- |
| HTTP contract | API reference and affected guide |
| Environment or default | Configuration reference and `.env.example` |
| Mix/release command | Mix task reference |
| Install or operations behavior | Affected getting-started/operations page |
| Product behavior | Affected concept and architecture note |
| Contract version | Contract reference, changelog, architecture note |
| Surface availability | Limitations and surface inventory |

## Branch and PR workflow

1. Start from current `main` and create a task branch.
2. Make one reviewable change.
3. Run applicable checks and inspect the final diff.
4. Commit with a short, scoped message.
5. Open one PR with scope, reason, relevant anchors, real check results, and
   deliberate limitations.

Do not rewrite or revert others' work without explicit authorization.

## Checks

Run the standard gate:

```bash
git status --short
mix deps.get
mix ash.codegen --check
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Run these when relevant:

```bash
mix credo --strict
mix dialyzer
mix sobelow --config
```

For documentation:

```bash
pip install -r docs/requirements.txt
mkdocs build
```

For evaluation or release work:

```bash
mix memhouse.eval.release --no-model --assert-thresholds \
  --output /private/tmp/memhouse-release-eval.json
mix memhouse.release.check \
  --eval-report /private/tmp/memhouse-release-eval.json
```

Report unavailable checks instead of implying they passed. Database-mode
changes need evidence for supervised pg0 and external PostgreSQL paths.

## Review checklist

Confirm the PR:

- preserves one codebase and identical deployment guarantees;
- maintains Account isolation, inherited scope access, Gate B promotion, and
  pipeline-only knowledge writes;
- keeps durable data separate from rebuildable caches;
- commits related state, audit, and job effects together;
- preserves provider neutrality and license boundaries;
- leaves source comments concise and self-contained;
- updates user documentation in the same patch;
- reports current, reproducible checks.

The `core` team decides when a PR is ready to merge.
