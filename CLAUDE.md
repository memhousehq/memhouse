<!-- SPDX-License-Identifier: Apache-2.0 -->
# MemHouse — notes for Claude Code

MemHouse is a governed memory service for AI agents: one Rust binary on Postgres + pgvector.
This repository is **public** (`memhousehq/memhouse`, Apache-2.0 code, CC BY 4.0 docs).

## How work is organised

Work is a sequence of numbered goals in [docs/roadmap.md](docs/roadmap.md). A session usually
starts from a goal's `/goal` line. Then:

1. Read the goal's section, its "Done when", and the ordering principles (roadmap section 2:
   expand-only schema changes; seams, not shortcuts).
2. Follow [roadmap section 5](docs/roadmap.md#5-how-to-run-a-goal): implement with unit tests,
   add a governance check for every new safety property, run the guard tier the goal names,
   update the docs it touches.
3. Log as you go ([Logging a goal](docs/roadmap.md#logging-a-goal)): tick deliverable boxes in
   the commit that completes them, never delete a box (strike it through with the reason), add a
   dated `**Result (YYYY-MM-DD):**` entry, and update the goal tracker and the progress count when
   the goal is done.
4. Commit messages name the goal (`G10: intake queue and job runner`).

Goals run in order; each assumes the earlier ones are done. Don't start work from a later goal
early unless the roadmap says so, and mark it "done early" where it lives.

If a goal changes the Memory Format (`memory-format/`, `docs/memory-format.md`), the change lands
here first; also update `ROADMAP.md` in [memhousehq/memory-format](https://github.com/memhousehq/memory-format).

## Commands

```bash
cargo xtask ci                 # everything CI runs, plus the benchmark guard (~5 min)
cargo xtask ci --fix           # apply rustfmt and add missing SPDX headers
cargo xtask ci --tier 2        # guard tier 2: cached enrichment, about $0.01
cargo xtask ci --skip-e2e      # without Docker
memhouse bench guard           # the guard alone (tier 1, free)
cargo xtask secrets --staged   # the secret scan the pre-commit hook runs
cargo xtask links              # relative links and anchors in the docs
```

- Use `MEMHOUSE_HOME=$PWD/.dev-home` for local runs, never `~/.memhouse`.
- Paid tiers and benchmarks run only locally, on demand, with the key given for that one run as an
  environment variable. Never in hosted CI, never written to a file.
- Build, test and guard details: [docs/development.md](docs/development.md); benchmarks:
  [docs/benchmarks.md](docs/benchmarks.md).

## Rules

- **Sign off every commit** (`git commit -s`, DCO). The `commit-msg` hook and CI reject commits
  without it.
- **`main` is protected:** pull requests only, linear history, required checks `checks` and
  `end-to-end and governance suite`. Work on a branch; never force-push `main`.
- **SPDX header** on every source and doc file: `Apache-2.0` for code, `CC-BY-4.0` under `docs/`.
- **No secrets** in any file, commit or log; refer to them by environment-variable name
  ([docs/security/secrets.md](docs/security/secrets.md)).
- **Public repository:** only material meant to be public goes here: no private planning notes,
  partner or customer names, in files or commit messages.
- **Governance suite stays at 100%**; the guard's quality metrics must not drop. Update
  `bench/baselines.json` (`memhouse bench guard --update`) only after a deliberate improvement.
- **Conventions** ([development.md § Conventions](docs/development.md#conventions)): no LLM on the
  hot path; every data change writes an audit event; every new config key gets a default, a doc
  comment and a row in `docs/configuration.md`; comments explain why and cite requirement ids.
- **Docs** change in the same pull request as the code they describe.
