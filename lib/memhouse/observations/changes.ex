# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Observations.Changes.HashContent do
  @moduledoc """
  Ash change that derives a message's SHA-256 content hash.

  The hash is computed from stored content and is not accepted independently from callers.
  """

  use Ash.Resource.Change

  alias MemHouse.Pipeline.Idempotency

  @doc """
  Sets `content_hash` to the lowercase hex SHA-256 of the changeset's `content`.

  Returns the changeset unchanged when no binary content is present. Never raises.
  """
  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :content) do
      content when is_binary(content) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :content_hash,
          Idempotency.content_hash(content)
        )

      _other ->
        changeset
    end
  end
end

defmodule MemHouse.Observations.Changes.HashContentIfMissing do
  @moduledoc """
  Fills a document version's content hash when the caller omitted it.

  A connector-supplied hash is preserved; otherwise the change derives one from the version's
  stored bytes.
  """

  use Ash.Resource.Change

  alias MemHouse.Pipeline.Idempotency

  @doc """
  Ensures `content_hash` is set: keeps a supplied non-empty hash, otherwise hashes `content`.

  Returns the changeset unchanged when neither is usable. Never raises.
  """
  @impl true
  def change(changeset, _opts, _context) do
    case {
      Ash.Changeset.get_attribute(changeset, :content_hash),
      Ash.Changeset.get_attribute(changeset, :content)
    } do
      # A supplied hash is the blob's content address; keep it verbatim.
      {hash, _content} when is_binary(hash) and hash != "" ->
        changeset

      {_hash, content} when is_binary(content) ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :content_hash,
          Idempotency.content_hash(content)
        )

      _other ->
        changeset
    end
  end
end

defmodule MemHouse.Observations.Changes.AuditAndEnqueueMessage do
  @moduledoc """
  Atomically audits a new message and schedules extraction.

  The message, content-safe audit entry, durable idempotency row, and AshOban enqueue share one
  transaction. Job arguments contain ids only, never message text.
  """

  use Ash.Resource.Change

  alias MemHouse.Governance.Audit
  alias MemHouse.Pipeline

  @doc """
  Registers the after-action hook that audits the message and enqueues its pipeline work.

  Returns the changeset. At run time the hook returns `{:ok, message}` once the audit entry, the
  extraction run, and the reconciler run are all durable, or the first error, which aborts the
  transaction.
  """
  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, message ->
      # The actor may arrive through the Ash context, through the explicit context key used by
      # callers that build changesets by hand, or through Ash's private context.
      actor =
        context.actor || changeset.context[:memhouse_actor] ||
          get_in(changeset.context, [:private, :actor])

      with {:ok, _audit} <-
             Audit.append(actor, message.account_id, %{
               scope_id: message.scope_id,
               actor_peer_id: message.peer_id,
               category: "observation",
               action: "message.ingested",
               resource_type: "message",
               resource_id: message.id,
               # The hash stands in for the text; the metadata stays to non-content facts.
               content_hash: message.content_hash,
               metadata: %{
                 "role" => message.role,
                 "session_id" => message.session_id
               }
             }),
           {:ok, _run} <- Pipeline.enqueue_message_extraction(message, actor),
           {:ok, _reconciler} <- Pipeline.enqueue_reconciler(message.account_id, actor),
           :ok <- maybe_fail(changeset) do
        {:ok, message}
      end
    end)
  end

  # Test-only escape hatch. Setting the private context flag below makes this hook fail *after*
  # the message row, the audit entry, and both jobs have been written, which is the only way to
  # prove from the outside that all four really do roll back together. Nothing in production
  # sets the flag; do not remove it without replacing that regression evidence.
  #
  # The `f2_` in the flag name and the "F2" in the failure message are a frozen legacy tag with
  # no current meaning. The regression test matches on that exact string, so renaming them is a
  # coordinated change across both files rather than a cleanup.
  defp maybe_fail(changeset) do
    if get_in(changeset.context, [:private, :f2_force_rollback?]) do
      {:error, "forced F2 rollback"}
    else
      :ok
    end
  end
end

defmodule MemHouse.Observations.Changes.AuditAndEnqueueDocument do
  @moduledoc """
  Atomically audits a document version and schedules extraction.

  The version, content-safe audit, idempotency record, and enqueue commit together. Document
  bytes, extracted text, cursors, metadata, and secrets never enter audit or job arguments.
  """

  use Ash.Resource.Change

  alias MemHouse.Governance.Audit
  alias MemHouse.Pipeline

  @doc """
  Registers the after-action hook that audits the version and enqueues its pipeline work.

  Returns the changeset. At run time the hook returns `{:ok, version}` once the audit entry, the
  extraction run, and the reconciler run are durable, or the first error, which aborts the
  transaction.
  """
  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, version ->
      # Same three-way actor lookup as the message hook: Ash context, explicit context key, or
      # Ash's private context.
      actor =
        context.actor || changeset.context[:memhouse_actor] ||
          get_in(changeset.context, [:private, :actor])

      with {:ok, _audit} <-
             Audit.append(actor, version.account_id, %{
               scope_id: version.scope_id,
               category: "observation",
               action: "document_version.ingested",
               resource_type: "document_version",
               resource_id: version.id,
               content_hash: version.content_hash,
               metadata: %{
                 "document_id" => version.document_id,
                 "version" => version.version,
                 "media_type" => version.media_type,
                 "byte_size" => version.byte_size
               }
             }),
           {:ok, _run} <- Pipeline.enqueue_document_extraction(version, actor),
           {:ok, _reconciler} <- Pipeline.enqueue_reconciler(version.account_id, actor) do
        {:ok, version}
      end
    end)
  end
end
