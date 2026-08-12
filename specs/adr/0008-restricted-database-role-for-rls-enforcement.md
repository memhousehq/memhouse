<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# ADR 0008: A restricted database role is what makes row-level security enforce

## Status

Accepted.

## Context

`AD-DATA-6` describes cross-Account isolation as two independent layers: the
Ash `:context` tenant filter in application code, and PostgreSQL row-level
security underneath it, keyed on the same Account setting, as DB-enforced
defense-in-depth. `MemHouse.DataLayer`'s moduledoc calls this "two independent
locks on the same door" and states the database layer is the backstop for
exactly the mistakes the application layer is capable of making.

That second lock was inert in every shipped configuration. PostgreSQL exempts
superusers from row-level security unconditionally, and `FORCE ROW LEVEL
SECURITY` — which every migration in this repository applies to every
Account-scoped table — removes only the *table owner's* exemption, never the
superuser's. Every connection MemHouse made was a superuser connection:
`postgres` in `mix test`, in every CI lane, and — decisively — in the pg0
single-node install that `ADR-0003` made the turnkey default, because
`postgres` there is the bootstrap role pg0's `initdb` creates, which is always
a superuser.

This was not a data leak. The Ash actor and tenant filter run on every query
and are the layer that actually enforced isolation. It was a missing backstop,
invisible by construction: a test written to prove "an unscoped read returns
nothing" passed vacuously, because the read returned rows regardless and the
assertion was checked against whatever the application layer had already
filtered. Filed as GitHub issue #55, discovered while writing regression tests
for the transactional-writes work in issue #54.

## Decision

**The node's connections run as a role that cannot bypass row-level security,
in every deployment mode.** `MemHouse.Database.AppRole` creates a role —
`memhouse_app` by default — with `NOSUPERUSER NOBYPASSRLS NOCREATEDB
NOCREATEROLE`, granted `SELECT, INSERT, UPDATE, DELETE` on the schema and
`EXECUTE` on its functions, and nothing else. It owns no table. Three
supervised boot steps carry this out, added to `MemHouse.Application`'s child
list in the position each needs:

1. `MemHouse.Database.RoleProvisioner` creates and grants the role, before the
   repository opens its pool. It runs over its own short-lived, unrestricted
   connection, because the role does not exist yet for anything to have
   switched to.
2. The repository's `:after_connect` callback (`MemHouse.Database.AppRole.set_role/1`)
   issues `SET ROLE` on every pooled connection as it opens, for the life of
   that connection. This is session-level, not transaction-local: a
   transaction-local switch would be undone by the first rollback and hand the
   rest of the connection's life back to the unrestricted role.
3. `MemHouse.Database.RoleGuard` runs after migrations and before anything
   that serves a request. It reads `pg_roles` for the connection's own
   effective role and raises — refusing to boot — if that role is still a
   superuser or holds `BYPASSRLS`, unless the deployment has explicitly opted
   out via `MEMHOUSE_ALLOW_UNRESTRICTED_DATABASE_ROLE=true`.

**Migrations and provisioning stay privileged, deliberately.** Both issue DDL,
which the restricted role must not be able to do — a role that could alter its
own tables could also alter its own row-level-security policies. Both run over
a short-lived, unnamed repository instance obtained through
`MemHouse.Database.AppRole.with_privileged_repo/1`, which starts a second
Ecto.Repo instance from the same connection configuration but without the
`after_connect` role switch. `mix ecto.migrate` and `bin/migrate`
(`MemHouse.Release.migrate/0`) already ran outside the supervised application
boot and were never affected; the supervised migration step
(`MemHouse.Release.Migrator`, used by the pg0 turnkey path) now explicitly
detours through the privileged instance rather than inheriting the pool
beside it. Every migration re-applies the role's grants afterward, because
`ALTER DEFAULT PRIVILEGES` only covers objects the granting role creates going
forward, not the tables a fresh migration just created behind it.

**Two supported shapes reach the same guarantee.** A deployment may let this
node provision the role itself (its connection role needs `CREATEROLE`), or an
operator may instead point `DATABASE_URL` at a login role already created with
`NOSUPERUSER NOBYPASSRLS` — the stronger arrangement, since that connection has
no path back to elevated access at all. `RoleGuard` checks the *effective*
role's attributes rather than how it got there, so both shapes pass the same
assertion.

**The test suite proves the enforcement, not just the intent.** The regression
this issue calls out — a suite that connects as a superuser cannot detect a
missing tenant filter — is fixed at the root: `mix test` now boots the same
supervised application any deployment does, so its own connections run as the
restricted role. `test/memhouse/database/app_role_test.exs` asserts the
running connection's own `pg_roles` attributes. A new assertion in
`test/memhouse/f1_ash_domain_backbone_test.exs` seeds a row, clears every
Account setting, and asserts a plain `SELECT` returns nothing — the isolation
test issue #55 asked for, which a superuser connection could not have passed
honestly. The existing RLS test, which previously had to create and switch to
a throwaway unprivileged role to mean anything (because the suite's own
connection was privileged), no longer needs that scaffolding: the connection
already is the restricted role.

## Consequences

Row-level security is now a real second lock rather than a documented
intention. A future defect in an Ash policy, a tenant assignment, or a
hand-written query in `MemHouse.Retrieval.Store` is caught by the database
rather than reaching across Accounts silently.

Boot gains two supervised steps and a database round trip each start:
provisioning (idempotent, a handful of `GRANT`/`ALTER DEFAULT PRIVILEGES`
statements) and the guard (one `pg_roles` read). Both are cheap relative to
migrations, which already run in the same position.

An operator who has not granted `CREATEROLE` to the connection role, and has
not created a restricted login by hand, now fails to boot instead of running
with an inert backstop. This is the intended behavior change and the reason
`MEMHOUSE_ALLOW_UNRESTRICTED_DATABASE_ROLE` exists: an upgrade must not
silently strand a running install, so the escape hatch is available, loud
(logged at error level on every boot while set), and off by default.

The Compose path connects as `memhouse`, created via the official Postgres
image's `POSTGRES_USER`, which `initdb --username` makes a superuser exactly
like pg0's bootstrap role — the issue flagged this as unverified and it is
not, in fact, exempt. It goes through the same provisioning and guard steps as
every other mode; no compose-specific carve-out was needed or added.

## Anchors

- `AINV-1` — one codebase, two modes, identical guarantees. The restricted role
  is provisioned and enforced identically in pg0 and external-Postgres mode.
- `AINV-8` — cross-account isolation is absolute; this closes the gap between
  that invariant's stated guarantee and what the database actually enforced.
- `AD-DATA-6` — isolation; the RLS half of the "app filter plus RLS"
  defense-in-depth this anchor describes now has an enforcing role behind it.
- `AD-TOPO-3` / `AD-CFG-3` — infrastructure seam boundaries; role provisioning
  is an infrastructure concern added at the same seam as pg0 and the
  repository, not a domain strategy.
- `ADR-0003` — the pg0 decision whose turnkey default made the superuser
  connection the common case; this ADR does not change pg0's design, only
  what role its bootstrap connection is used to provision and switch away
  from.

## Related Documents

- `specs/architecture/ash-domain-backbone.md`
- `docs/concepts/deployment-modes.md`
- `docs/reference/configuration.md`
- GitHub issue #55
