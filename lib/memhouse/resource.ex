# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Resource do
  @moduledoc """
  Defines the shared PostgreSQL, authorization, and portability contract for durable resources.

  Installs the single Repo, policy authorizer, keyset-paginated private export, and exact-row
  private import. Import bypasses normal validations to restore ids, timestamps, and history, so
  only pipeline or non-grantable system actors may use it. Resources still own multitenancy and
  domain policies.

  Requires `:domain` and `:table`; `:extensions` defaults to none.
  """

  @doc """
  Declares the calling module as a MemHouse Ash resource.

  Injects the PostgreSQL data layer, the policy authorizer, the private
  portability export/import actions, and the policy that limits them to
  internal actors. Raises at compile time when `:domain` or `:table` is
  missing.
  """
  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    table = Keyword.fetch!(opts, :table)
    extensions = Keyword.get(opts, :extensions, [])

    quote do
      use Ash.Resource,
        otp_app: :memhouse,
        domain: unquote(domain),
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: unquote(extensions)

      postgres do
        table unquote(table)
        repo MemHouse.Repo
      end

      actions do
        # Keyset paging avoids offset skips or duplicates during concurrent writes.
        read :portability_export do
          public? false

          pagination do
            keyset? true
            required? false
          end
        end

        # Force-write archived values so ids, timestamps, and history survive restore.
        create :portability_import do
          public? false
          accept []
          argument :attributes, :map, allow_nil?: false
          change MemHouse.Portability.Changes.RestoreAttributes
        end
      end

      policies do
        # Portability spans the Account and is internal-only.
        policy action([:portability_export, :portability_import]) do
          authorize_if actor_attribute_equals(:pipeline?, true)
          authorize_if {MemHouse.Policy.RoleIn, roles: [:system]}
        end
      end
    end
  end
end

defmodule MemHouse.Policy.ScopeAccess do
  @moduledoc """
  Narrows a read to the scopes the caller is actually allowed to see.

  Unauthorized rows are filtered, not revealed as forbidden. `:all` is internal-only; missing or
  empty scope lists fail closed. `attribute:` defaults to `:scope_id`. Account isolation remains a
  separate resource policy.
  """

  use Ash.Policy.FilterCheck

  # Authorization explanations must never include row content.
  @impl true
  def describe(opts), do: "actor may read the #{opts[:attribute] || :scope_id} scope"

  @impl true
  def filter(%{scope_ids: :all}, _context, _opts), do: true

  def filter(%{scope_ids: scope_ids}, _context, opts) when is_list(scope_ids) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    expr(^ref(attribute) in ^scope_ids)
  end

  # Missing resolved scopes fail closed.
  def filter(_actor, _context, _opts), do: false
end

defmodule MemHouse.Policy.RoleIn do
  @moduledoc """
  Passes when the caller's single strongest role is one of the listed roles.

  Use only for Account-wide actions; scope-sensitive decisions need a per-scope check. `:system`
  is non-grantable internal authority. Missing `:roles` raises and malformed actors fail closed.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor role is one of #{inspect(Keyword.fetch!(opts, :roles))}"

  @impl true
  def match?(%{role: role}, _context, opts), do: role in Keyword.fetch!(opts, :roles)

  # Unauthenticated or malformed actors fail closed.
  def match?(_actor, _context, _opts), do: false
end

defmodule MemHouse.Policy.HumanRoleIn do
  @moduledoc """
  Passes only for a human session that also holds one of the listed roles.

  Curator decisions require a password-backed session. API keys and system actors fail regardless
  of role; automation may submit observations but never approve them. Missing `:roles` raises.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts),
    do: "authenticated human actor has one of #{inspect(Keyword.fetch!(opts, :roles))}"

  @impl true
  def match?(%{identity_kind: :password, role: role}, _context, opts),
    do: role in Keyword.fetch!(opts, :roles)

  # Only password-backed human sessions qualify.
  def match?(_actor, _context, _opts), do: false
end

defmodule MemHouse.Policy.HumanScopeRole do
  @moduledoc """
  Passes for a human session holding one of the listed roles *at the row's own scope*.

  Filters by the password session's resolved per-scope roles, including deny-wins resolution.
  API keys fail. `attribute:` defaults to `:scope_id`; missing `:roles` raises.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts),
    do: "authenticated human has a permitted role at #{opts[:attribute] || :scope_id}"

  @impl true
  def filter(%{identity_kind: :password, scope_roles: scope_roles}, _context, opts)
      when is_map(scope_roles) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    roles = Keyword.fetch!(opts, :roles)

    scope_ids =
      for {scope_id, role} <- scope_roles,
          role in roles,
          do: scope_id

    expr(^ref(attribute) in ^scope_ids)
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule MemHouse.Policy.HumanOwns do
  @moduledoc """
  Passes for a human session acting on a row that is about that same person.

  Enforces subject-only consent: curator authority and API keys cannot substitute for a password-
  backed subject. `attribute:` defaults to `:subject_peer_id`; non-matches are filtered.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts),
    do: "authenticated human owns #{opts[:attribute] || :subject_peer_id}"

  @impl true
  def filter(%{identity_kind: :password, peer_id: peer_id}, _context, opts)
      when is_binary(peer_id) do
    attribute = Keyword.get(opts, :attribute, :subject_peer_id)
    expr(^ref(attribute) == ^peer_id)
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule MemHouse.Policy.ScopeRelationAccess do
  @moduledoc """
  Passes only when the caller is authorized at *both* ends of a cross-scope link.

  Cross-links never grant access. Both endpoint ids must be authorized before retrieval may follow
  a relation. Internal `:all` sees every link; missing scopes see none. Both endpoint attributes
  are required.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "actor may read both ends of the scope relation"

  @impl true
  def filter(%{scope_ids: :all}, _context, _opts), do: true

  def filter(%{scope_ids: scope_ids}, _context, opts) when is_list(scope_ids) do
    source_attribute = Keyword.fetch!(opts, :source_attribute)
    target_attribute = Keyword.fetch!(opts, :target_attribute)

    expr(
      ^ref(source_attribute) in ^scope_ids and
        ^ref(target_attribute) in ^scope_ids
    )
  end

  def filter(_actor, _context, _opts), do: false
end

defmodule MemHouse.Policy.ScopeRole do
  @moduledoc """
  Passes when the caller holds one of the listed roles at the row's own scope.

  Uses resolved per-scope roles after inheritance and deny-wins. Machine credentials may use it
  for permitted non-curator work; system actors bypass scope maps. `attribute:` defaults to
  `:scope_id`; missing `:roles` raises.
  """

  use Ash.Policy.FilterCheck

  @impl true
  def describe(opts), do: "actor has a permitted role at #{opts[:attribute] || :scope_id}"

  @impl true
  def filter(%{role: :system}, _context, _opts), do: true

  def filter(%{scope_roles: scope_roles}, _context, opts) when is_map(scope_roles) do
    attribute = Keyword.get(opts, :attribute, :scope_id)
    roles = Keyword.fetch!(opts, :roles)

    scope_ids =
      for {scope_id, role} <- scope_roles,
          role in roles,
          do: scope_id

    expr(^ref(attribute) in ^scope_ids)
  end

  def filter(_actor, _context, _opts), do: false
end
