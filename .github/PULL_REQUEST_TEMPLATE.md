## Summary

- What changed?
- Why is this the smallest useful change for the linked issue?

## Linked issue

<!-- Required: always mention the issue this PR implements. Use a closing keyword when appropriate, for example: `Closes #9` or `Closes https://github.com/memhousehq/memhouse/issues/9`. -->

Closes #

## Reference docs

<!-- List the internal docs actually used to scope, implement, and review this PR. Include the closest specific document(s), not every possible doc. Use `N/A` only when a category truly does not apply. -->

- Modules and tests that define the behavior being changed:
- ADRs: `specs/adr/README.md` or `specs/adr/<adr-file>.md`:
- Architecture notes: `specs/architecture/README.md` or `specs/architecture/<note>.md`:
- Roadmap/process docs: `specs/roadmap/beta-roadmap.md`, `specs/process/`:
- Security/eval docs: `specs/security/README.md`, `specs/eval/README.md`, or a specific note:
- Published user documentation affected: the page(s) under `docs/`:
- Other internal docs:

## Product invariants

Name the invariants from `AGENTS.md` this PR depends on or preserves, and the test that proves it. Use `N/A` only for truly mechanical changes.

- One codebase, two deployment modes, identical guarantees:
- Account isolation; Account derived from identity, never a request parameter:
- Pipeline-only knowledge writes and governed promotion:
- Other invariants:

## Self-explanatory code

Every touched file must be readable on its own, without opening `specs/` or
`docs/`. See the "Coding conventions" section of `AGENTS.md`.

- [ ] Every module touched has a real `@moduledoc`; no `@moduledoc false` added
- [ ] New or changed public functions have a `@doc` covering return shape and failure modes
- [ ] No comment or docstring points at a spec, ADR, or roadmap item for its meaning
- [ ] Comments explain why, not what, and no comment contradicts the code it sits next to

## Documentation

User-visible changes ship their `docs/` update in the same patch. Design
material goes to `specs/`; development process goes to `CONTRIBUTING.md`. See
the "Documentation layout" section of `AGENTS.md`.

- [ ] Every changed route, parameter, default, environment variable, Mix task, or operational step is reflected in the affected `docs/` page
- [ ] Any new `docs/` page is listed in the `nav:` of `mkdocs.yml`
- [ ] `mkdocs build` passes, or the PR states that the toolchain was unavailable
- [ ] No design document, roadmap item, ADR, or benchmark result was added under `docs/`

## Risk class

Select one and explain the reviewer attention needed.

- [ ] Low — docs, tests, or internal cleanup only
- [ ] Medium — behavior, schema, dependency, or operational change
- [ ] High — security, tenancy, audit, data-loss, migration, release, or production-risk change

Risk rationale:

## AI usage accountability

- [ ] No AI used
- [ ] AI-assisted implementation
- [ ] AI-assisted review
- [ ] AI-assisted test generation
- [ ] AI-assisted documentation

If AI was used, name the tool/model and summarize human verification performed:

## Test evidence

List every check actually run. Include command, result, and any relevant output or artifact link.

```bash
# command
# result/output summary
```

If a standard check was not run, explain why:

## Backend parity

Does this PR affect pg0 single-node mode, external-Postgres queue-mode, queues, storage, retrieval, or derived caches?

- [ ] No backend-parity impact
- [ ] Parity evidence provided for packaged pg0/single-node
- [ ] Parity evidence provided for external Postgres/queue-mode
- [ ] Parity lane not yet available; limitation explained below

Parity notes:

## Security, tenancy, and audit impact

- [ ] No security, tenancy, or audit impact
- [ ] Security impact reviewed
- [ ] Tenancy/account-isolation impact reviewed
- [ ] Audit/ledger/history impact reviewed

Notes, including how Account isolation is preserved when relevant:

## Migration impact

- [ ] No migrations or data backfills
- [ ] Reversible migration included
- [ ] Irreversible migration or backfill; rollback/restore plan documented

Migration notes:

## Release-note impact

- [ ] No release note needed
- [ ] User-facing change; release note drafted
- [ ] Operator-facing change; release note drafted
- [ ] Breaking change; migration/upgrade note drafted

Release note draft or rationale:
