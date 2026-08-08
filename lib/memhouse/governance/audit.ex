# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.Audit do
  @moduledoc """
  Writer for the append-only, hash-chained, per-Account audit log.

  Every governed mutation appends one row. Rows are immutable and link to the previous hash, so
  verification detects insertion, editing, reordering, or deletion.

  ## Content safety is the rule this module exists to enforce

  Audit holds references, never content. `attrs`, especially verbatim `metadata`, may contain ids,
  counts, class names, or digests. Never pass messages, statements, prompts, answers, document
  data, cursors, keys, or secrets.

  ## Transaction and tenancy

  `append/3` uses the Account's `record` action in the caller's transaction. Mutation and evidence
  therefore commit or roll back together. Each Account has an isolated chain.

  Append uses a system-pipeline copy of the caller only for the audit insert.
  """

  alias MemHouse.Clock
  alias MemHouse.Governance.AuditEvent

  # Reserved vocabulary for the `category` field. Keeping it small is what makes
  # the log queryable: an operator can filter by category without knowing every
  # action name a subsystem might emit.
  @categories ~w(
    lifecycle gate attribution deletion configuration governance observation
  )

  @doc """
  Returns the reserved audit categories.

  `append/3` does not reject an unknown category — the stored attribute is a
  plain string — so callers are expected to choose from this list. Adding a
  category should therefore be a deliberate vocabulary change here, not a typo
  that silently creates a new bucket at a call site.
  """
  @spec categories() :: [String.t()]
  def categories, do: @categories

  @doc """
  Appends one event to an Account's audit chain.

  `actor` may be a `MemHouse.Actor` struct or a plain map; a copy with
  `role: :system` and `pipeline?: true` is used for the insert so the append
  succeeds regardless of the caller's own role. `account_id` names the tenant
  whose chain is extended. `attrs` carries the `record` action fields:
  `:category`, `:action`, `:resource_type`, `:resource_id`, and the optional
  `:scope_id`, `:actor_peer_id`, `:content_hash`, `:metadata`, and
  `:occurred_at`, which defaults to the current time.

  Returns `{:ok, event}` or `{:error, reason}` from Ash. Raises
  `FunctionClauseError` when `account_id` is not a binary or `attrs` is not a
  map, because an untenanted audit event is a programming error rather than a
  recoverable condition.

  Everything in `attrs` becomes durable, so all of it must be content-safe:
  ids, counts, class names, and digests only.
  """
  @spec append(map(), Ecto.UUID.t(), map()) :: {:ok, AuditEvent.t()} | {:error, term()}
  def append(actor, account_id, attrs) when is_map(attrs) and is_binary(account_id) do
    actor = pipeline_actor(actor)

    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:occurred_at, Clock.utc_now())

    AuditEvent
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{audit_actor: actor})
    |> Ash.Changeset.for_create(:record, attrs)
    |> Ash.create(actor: actor)
  end

  @doc """
  Same as `append/3`, but returns the event and raises `RuntimeError` on failure.

  Use this wherever losing the audit event would leave a governed mutation
  unrecorded. Raising aborts the enclosing transaction and takes the mutation
  down with it, which is the intended outcome: no governed change may commit
  without its evidence.
  """
  @spec append!(map(), Ecto.UUID.t(), map()) :: AuditEvent.t()
  def append!(actor, account_id, attrs) do
    case append(actor, account_id, attrs) do
      {:ok, event} -> event
      {:error, error} -> raise "Audit append failed: #{inspect(error)}"
    end
  end

  @doc """
  Hashes a term to lowercase hex SHA-256 for content-free evidence.

  Deterministic Erlang term encoding makes equal terms hash equally. This is an internal
  fingerprint, not a cross-language checksum.
  """
  @spec content_hash(term()) :: String.t()
  def content_hash(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The audit resource's `record` policy wants a governance role or the pipeline
  # flag, but any caller must be able to leave a trail, so the actor is copied
  # with both set. Both clauses build a copy; the caller keeps its real role
  # everywhere else, and the copied `account_id` still binds the write to one
  # Account.
  defp pipeline_actor(%MemHouse.Actor{} = actor),
    do: %{actor | role: :system, pipeline?: true}

  defp pipeline_actor(actor) do
    actor
    |> Map.put(:role, :system)
    |> Map.put(:pipeline?, true)
  end
end

defmodule MemHouse.Governance.Changes.HashAuditEvent do
  @moduledoc """
  Ash change that links a new audit event into its Account's hash chain.

  It runs in `before_action`, so reading the current chain tip and computing
  the new hash happen inside the same transaction as the insert. For the rest
  of that transaction it holds an Account-scoped advisory lock. That lock
  serialises concurrent appends for one Account while leaving every other
  Account free; without it two concurrent appends could read the same tip and
  each claim it as their predecessor, forking the chain and making
  verification ambiguous forever after.

  The stored event hash covers the Account id, category, action, resource type
  and id, content hash, metadata, the ISO-8601 event time, and the previous
  event's hash. Metadata is hashed and stored exactly as given, which is the
  concrete reason callers must keep raw content and secrets out of it.

  The predecessor is chosen by insertion order (`inserted_at`, then `id`), not
  by `occurred_at`. `occurred_at` describes when the audited thing happened and
  may be supplied by the caller, so it is hashed but does not decide where a row
  sits in the chain.
  """

  use Ash.Resource.Change

  alias MemHouse.Clock
  alias MemHouse.Governance.Audit
  alias MemHouse.Governance.AuditEvent
  alias MemHouse.Pipeline.Lock

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      # An append raised from another resource's after_action does not always
      # carry an actor in the change context, so fall back to the one stashed
      # on the changeset by the audit writer, then to the private actor Ash
      # threads through the changeset.
      actor =
        context.actor || changeset.context[:audit_actor] ||
          get_in(changeset.context, [:private, :actor])

      account_id = changeset.tenant || context.tenant || actor.account_id

      # Holds until this transaction ends: one writer per Account chain tip.
      Lock.acquire!(account_id, "audit-chain")

      previous =
        AuditEvent
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(1)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read_one!(actor: actor)

      occurred_at = Ash.Changeset.get_attribute(changeset, :occurred_at) || Clock.utc_now()

      # nil for the Account's very first event. `MemHouse.Portability.AuditVerifier`
      # uses that nil to identify the one row a chain may start from.
      previous_hash = previous && previous.event_hash

      # Only ids, hashes, timings, and the content-safe metadata map are hashed
      # and persisted. The audited content itself never appears in either.
      payload = %{
        account_id: account_id,
        category: Ash.Changeset.get_attribute(changeset, :category),
        action: Ash.Changeset.get_attribute(changeset, :action),
        resource_type: Ash.Changeset.get_attribute(changeset, :resource_type),
        resource_id: Ash.Changeset.get_attribute(changeset, :resource_id),
        content_hash: Ash.Changeset.get_attribute(changeset, :content_hash),
        metadata: Ash.Changeset.get_attribute(changeset, :metadata) || %{},
        occurred_at: DateTime.to_iso8601(occurred_at),
        previous_hash: previous_hash
      }

      changeset
      |> Ash.Changeset.force_change_attribute(:occurred_at, occurred_at)
      |> Ash.Changeset.force_change_attribute(:previous_hash, previous_hash)
      |> Ash.Changeset.force_change_attribute(:event_hash, Audit.content_hash(payload))
    end)
  end
end

defmodule MemHouse.Governance.Changes.AuditResource do
  @moduledoc """
  Ash change that appends one audit event after a resource action succeeds.

  Attach it to a create or update with the `category`, `action`, and
  `resource_type` options, plus an optional `content_fields` list and a static
  `metadata` map. It runs in `after_action`, so it sees the persisted row and
  can record its real id, and it still runs inside the action's transaction:
  if the append fails the change returns that error and the whole action —
  audit event included — rolls back.

  `content_fields` names the attributes whose *values* identify this version of
  the row. Those values are hashed together into a single digest and only the
  digest is stored, so a later reader can prove which version was written
  without the log ever holding the values. Do not extend the options to copy
  field values into `metadata`: metadata is persisted verbatim and must stay
  free of content and secrets.
  """

  use Ash.Resource.Change

  alias MemHouse.Governance.Audit

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      actor = get_in(changeset.context, [:private, :actor])
      fields = Keyword.get(opts, :content_fields, [])
      content_hash = Audit.content_hash(Map.take(result, fields))

      Audit.append(actor, result.account_id, %{
        scope_id: Map.get(result, :scope_id),
        actor_peer_id: Map.get(actor, :peer_id),
        category: Keyword.fetch!(opts, :category),
        action: Keyword.fetch!(opts, :action),
        resource_type: Keyword.fetch!(opts, :resource_type),
        resource_id: result.id,
        content_hash: content_hash,
        metadata: Keyword.get(opts, :metadata, %{})
      })
      |> case do
        {:ok, _event} -> {:ok, result}
        {:error, error} -> {:error, error}
      end
    end)
  end
end
