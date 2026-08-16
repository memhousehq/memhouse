# Domain-document convention

This repository uses one root `CONTEXT.md` for agent wayfinding. It is a
short index, not a second specification.

- Current behavior belongs in source and tests.
- Published procedures belong in `docs/`.
- Decisions and rejected alternatives belong in `specs/adr/`.
- Cross-cutting boundaries belong in `specs/architecture/`.
- Outstanding work belongs in `specs/roadmap/beta-roadmap.md`.

Do not create a `CONTEXT-MAP.md` or package-specific context files unless the
repository becomes genuinely multi-package.
