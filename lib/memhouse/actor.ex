# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Actor do
  @moduledoc """
  Immutable authorization context passed to Ash actions.

  It carries identity-derived Account, role, and authorized scopes as a point-in-time snapshot.
  Internal system and pipeline capabilities must never be constructed from request input; resolve
  a fresh actor after grants or topology change.
  """

  @enforce_keys [:account_id, :account_key]
  defstruct [
    :account_id,
    :account_key,
    :peer_id,
    :identity_id,
    :identity_kind,
    :assurance,
    :credential_scope_id,
    role: :member,
    scope_ids: :all,
    scope_roles: %{},
    pipeline?: false
  ]

  @typedoc """
  Effective authorization role.

  `:reader`, `:member`, `:curator`, and `:account_admin` are the four roles a
  human or agent can be granted, in increasing order of power. `:system` is not
  grantable: it marks internal server-side work and is checked separately by
  policies, so it deliberately has no place in the grant ranking.
  """
  @type role :: :account_admin | :curator | :member | :reader | :system

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          account_key: String.t(),
          peer_id: Ecto.UUID.t() | nil,
          identity_id: Ecto.UUID.t() | nil,
          identity_kind: :password | :api_key | :system | nil,
          assurance: :low | :medium | :high | nil,
          credential_scope_id: Ecto.UUID.t() | nil,
          role: role(),
          scope_ids: :all | [Ecto.UUID.t()],
          scope_roles: %{optional(Ecto.UUID.t()) => role()},
          pipeline?: boolean()
        }

  @doc """
  Builds the throwaway actor used to look up or create an Account by key.

  This is the chicken-and-egg case: the Account row is not known yet, so there
  is no `account_id` to authorize against. It returns a plain map rather than a
  `%MemHouse.Actor{}`, since every field of the struct is meant to name a
  resolved Account. Both Account policies that this map can satisfy match on
  `key == actor(:account_key)`, and the surrounding transaction has already
  pinned the same key into the transaction-local PostgreSQL setting that
  row-level security reads, so the map cannot see rows belonging to any other
  Account.

  Use it only from the infrastructure layer that opens Account transactions.
  Passing it to domain actions would grant `:system` privileges with no
  resolved Account behind them.
  """
  def bootstrap(account_key) do
    %{
      account_id: nil,
      account_key: account_key,
      identity_kind: :system,
      assurance: :high,
      role: :system,
      scope_ids: :all,
      scope_roles: %{},
      pipeline?: false
    }
  end

  @doc """
  Builds an internal actor bound to an already-resolved Account record.

  `account` must be a loaded Account (its `id` and `key` are copied verbatim).
  `overrides` is a keyword list merged over the defaults, and is how callers ask
  for `role: :system`, a restricted `scope_ids` list, or `pipeline?: true`.

  The defaults are deliberately unauthenticated-looking: `identity_kind:
  :system`, no `peer_id`, `role: :member`, and `scope_ids: :all`. That means the
  result already sees every scope in the Account, so this is an internal
  helper — infrastructure transactions, the pipeline, migrations, and tests. It
  is not a substitute for resolving a real caller's grants. An actor for someone
  who authenticated over HTTP must come from role resolution against their Peer,
  otherwise scope restrictions and deny grants are silently skipped.

  Raises `KeyError` when `overrides` names a field the struct does not have, and
  raises whatever `account.id` or `account.key` raises when `account` is not a
  record carrying both.
  """
  def for_account(account, overrides \\ []) do
    struct!(
      __MODULE__,
      Keyword.merge(
        [
          account_id: account.id,
          account_key: account.key,
          identity_kind: :system,
          assurance: :high,
          role: :member,
          scope_ids: :all,
          scope_roles: %{},
          pipeline?: false
        ],
        overrides
      )
    )
  end
end
