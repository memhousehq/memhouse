<!-- SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0 -->

# Identity, Tenancy, And Basic RBAC

Status: implemented

Authenticated, Account-bound Peers replace HTTP Account selection. This
free-core boundary implements `FR-TOP-1`, `FR-TOP-2`, `FR-TOP-6`, `FR-API-3`, `FR-GOV-18`,
`FR-GOV-19`, `AD-SEC-1` through `AD-SEC-5`, and `AINV-6`.

## Identity paths

Humans use the AshAuthentication password strategy. A successful password
sign-in returns a signed 12-hour JWT containing the Peer subject and the
community Account tenant. Agents use the AshAuthentication API-key strategy.
API keys are generated once, stored only as SHA-256 hashes, bound to one Peer
and Account, and may be restricted to one scope subtree. New keys use the
`memhouse_` prefix. The bearer dispatcher also accepts the legacy `cartulary_`
prefix so the rename does not invalidate an existing beta credential.

Both paths resolve to `MemHouse.Actor`:

- `account_id` and `peer_id` come from the verified identity;
- the linked `ExternalIdentity` supplies `identity_kind` and assurance;
- `RoleGrant` resolution supplies effective `scope_ids`, `scope_roles`, and the
  highest effective basic role;
- the actor is installed as the Ash actor/tenant and as transaction-local
  `memhouse.account_id` before domain work runs.

`POST /api/auth/password` is the human sign-in endpoint. Every `/api/v1`
memory route requires `Authorization: Bearer <JWT-or-API-key>`. The deprecated
`x-memhouse-account-key` header and Account fields in request bodies are
ignored. Health remains unauthenticated.

## Account bootstrap and free-edition enforcement

Bootstrap the first operator with:

```bash
MEMHOUSE_BOOTSTRAP_PASSWORD='a long password' \
  mix memhouse.identity.bootstrap \
    --email admin@example.test \
    --name 'Local Admin'
```

This provisions `MEMHOUSE_FREE_ACCOUNT_KEY`, a medium-assurance password
identity, the containment root, and a propagating `account-admin` grant.

The `accounts.edition_slot` partial unique index permits exactly one
`community-free` Account. Account-key helpers from the frozen API baseline and
the Ash domain backbone remain internal for eval fixtures and migration
compatibility, but they cannot create another authenticated free slot and no
HTTP route calls them.

Enterprise enablement must replace the free-slot constraint through a licensed
provisioning action without changing identity-to-actor, Ash tenancy/policy, or
RLS. Free core neither implements nor enables that action.

## API-key bootstrap and RLS

Before Account RLS is established, `MemHouse.Identity.CredentialLocator`
passes the API key's opaque credential id to
`SECURITY DEFINER` function `memhouse_resolve_api_key_account(uuid)`. The
function returns only `account_id`; it cannot return peer data, hashes, or
content. The key hash is then verified by AshAuthentication inside the
resolved Account transaction.

The API-key path additionally requires the resolved Account to own the one
`community-free` edition slot. A valid key attached to a legacy or foreign
Account receives the same unauthorized response as an unknown credential.

This named direct-Repo exception performs only bootstrap lookup, never a durable
write or authorization decision.

`api_keys` carries `account_id`, has forced Account RLS, and joins the existing
RLS policy inventory. Password/JWT resolution uses the one configured free
Account and rejects a signed subject that is absent from that tenant.

## Basic scope RBAC

Roles are `account-admin`, `curator`, `member`, and `reader`. Each grant records
`effect=allow|deny`, `propagate`, grantor, and grant time.

For a target scope, the resolver:

1. collects exact grants plus grants on containment ancestors whose
   `propagate` flag is true;
2. rejects the scope if any applicable deny exists;
3. otherwise chooses the highest applicable allow;
4. intersects the result with an API key's optional scope restriction.

Containment affects inheritance; cross-links do not. A `ScopeRelation` is
readable only if both its source and target scopes are authorized. This keeps
cross-linked retrieval from bypassing `FR-API-3`.

Advanced roles, relationship-based adapters, and enterprise RBAC administration
remain out of scope.

## Contract and evidence

The `poc-0` payloads, downward inheritance, raw-message persistence, and
pipeline-only knowledge writes remain unchanged. `poc-0` is a historical
contract tag. Only Account selection changed: identity is required and the old
header is inert.

Evidence lives in:

- `test/memhouse/f3_identity_tenancy_basic_rbac_test.exs`;
- `test/memhouse_web/controllers/memory_controller_test.exs`;
- `priv/repo/migrations/20260727155503_f3_identity_tenancy_basic_rbac.exs`;
- `priv/resource_snapshots/`; and
- the baseline-contract, Ash domain backbone, and transactional writes, audit,
  and jobs regression suites listed in `AGENTS.md`.

The suite covers password/API-key authentication, assurance, single-Account
enforcement, opaque failures, hash storage, cross-link authorization, and
property-based Account-wall and inheritance/deny cases.
