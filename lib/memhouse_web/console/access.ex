# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.Console.Access do
  @moduledoc """
  Centralizes lifecycle visibility and UI action checks for the browser console.

  Ash still owns Account and scope authorization. Provisional knowledge is visible only
  to its subject, including for administrators; curators see every other lifecycle state,
  while other roles see settled states plus their own subject knowledge. UI checks only
  control rendering—the operation layer must authorize every write again.
  """

  alias MemHouse.Actor
  alias MemHouse.Knowledge.Lifecycle

  # Lifecycle states a member or reader may see for knowledge that is not about
  # them. These are the states that represent something the system currently
  # believes, or used to believe and has retired in the open. Deliberately
  # absent: `proposed`, `held`, `provisional`, `rejected`, `contested`,
  # `redacted`, `stale`, and `retracted` — those are either undecided proposals
  # that have not passed a gate, or content withdrawn on purpose.
  @settled_states Lifecycle.settled_states()

  @all_states Lifecycle.states()

  # Roles whose holders govern the lifecycle rather than merely reading it.
  @governing_roles [:account_admin, :curator]

  @doc """
  Lifecycle states this actor may be shown for knowledge that is not about them.

  Returns every state for a curator or account administrator, and the settled
  subset for everyone else. The caller must still apply the provisional rule
  and the self-subject exemption; this list alone is not the whole filter, which
  is why `knowledge_filter_terms/1` exists and should be preferred.
  """
  def visible_states(%Actor{role: role}) when role in @governing_roles, do: @all_states
  def visible_states(%Actor{}), do: @settled_states

  @doc """
  Every lifecycle state the knowledge resource defines, oldest-to-newest in the
  order a statement typically travels.

  Used to populate filter controls, so a curator can ask for a state that
  happens to have no rows right now and get an honest empty result rather than
  an absent option.
  """
  def all_states, do: @all_states

  @doc """
  Returns `{visible_states, peer_id}` for a correctly narrowed knowledge query.

  When `peer_id` is `nil`, omit subject clauses; comparing a subject column to `nil`
  would match unrelated subjectless rows.
  """
  def knowledge_filter_terms(%Actor{} = actor), do: {visible_states(actor), actor.peer_id}

  @doc """
  Whether one already-loaded knowledge row should be shown to this actor.

  This is the in-memory twin of `knowledge_filter_terms/1`, for the handful of
  places that receive rows from an operation-layer call rather than building
  their own query — the retrieval search results and the governance history
  bundle. Prefer filtering in the query when there is a query to filter.
  """
  def visible_knowledge?(%Actor{} = actor, item) do
    own_subject? = not is_nil(actor.peer_id) and item.subject_peer_id == actor.peer_id
    governor? = actor.role in @governing_roles

    Lifecycle.console_visible?(item.state, own_subject?, governor?)
  end

  @doc """
  Reports whether the UI should render a console action for this actor.

  State-changing actions require a password identity. Unknown actions return `false`.
  """
  def can?(%Actor{} = actor, :curate),
    do: human?(actor) and actor.role in @governing_roles

  def can?(%Actor{} = actor, :promote),
    do: human?(actor) and actor.role in @governing_roles

  def can?(%Actor{} = actor, :administer),
    do: human?(actor) and actor.role == :account_admin

  def can?(%Actor{} = actor, :self_govern),
    do: human?(actor) and is_binary(actor.peer_id)

  def can?(%Actor{}, _action), do: false

  @doc """
  Whether this actor is the subject of the given knowledge row, and may
  therefore confirm, contest, or redact it.

  Being the subject is independent of holding any role: a person with no grant
  on the scope a statement lives in may still act on a statement about
  themselves, which is precisely why this is a separate question from
  `can?/2`.
  """
  def subject_of?(%Actor{} = actor, item) do
    can?(actor, :self_govern) and item.subject_peer_id == actor.peer_id
  end

  @doc """
  Human-readable label for an actor's effective role, for the console header.

  The effective role is the highest one the actor holds anywhere in the
  Account, so it describes the ceiling of what they can do, not what they can
  do in the scope they happen to be looking at. Pages that offer a scope-
  specific gesture must consult the per-scope role instead.
  """
  def role_label(%Actor{role: :account_admin}), do: "Account admin"
  def role_label(%Actor{role: :curator}), do: "Curator"
  def role_label(%Actor{role: :member}), do: "Member"
  def role_label(%Actor{role: :reader}), do: "Reader"
  def role_label(%Actor{role: role}), do: to_string(role)

  @doc """
  The actor's effective role at one specific scope, or `nil` when no grant
  reaches it.

  A scope absent from the actor's `scope_roles` map is not authorized — either
  no grant applies, or a deny grant removed it. Deny always wins, so an absent
  entry must be read as "no access" and never softened to a default role.
  """
  def scope_role(%Actor{} = actor, scope_id), do: Map.get(actor.scope_roles, scope_id)

  # Curator, subject, and administrative gestures all change stored state, and
  # all of them are reserved for a person who signed in with a password. This
  # is checked separately from the role because the two are independent: an
  # agent credential can hold a high role and still must never drive any of
  # them.
  defp human?(%Actor{identity_kind: :password}), do: true
  defp human?(%Actor{}), do: false
end
