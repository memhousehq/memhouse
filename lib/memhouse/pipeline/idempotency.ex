# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Pipeline.Idempotency do
  @moduledoc """
  The deterministic keys that make every background job replay-safe.

  Pipeline runs are unique by Account and key. Retries, reconciliation, duplicate events, and
  connector redelivery therefore converge on one run.

  ## What makes a good key

  Keys combine a family with immutable input identity, such as id plus content hash or scope plus
  watermark. Families are not lanes. Never include per-call timestamps, random ids, attempts, or
  mutable state.

  A content hash in the key is what makes changed input *new* work: the same
  message id with different bytes is a different key, so an edit is processed
  while a redelivery is not.

  ## Content safety

  Keys are durable and operator-visible. Digest cursors and other sensitive components; never use
  raw statements, messages, or secrets.

  ## Stability

  Key encoding is a durable format. Changing it can rerun completed work.
  """

  @doc """
  Key for extracting one raw message.

  The content hash is part of the identity, so re-submitting identical content
  reuses the run while genuinely edited content becomes separate work.
  """
  @spec message_extraction(Ecto.UUID.t(), String.t()) :: String.t()
  def message_extraction(message_id, content_hash),
    do: key(:message_extraction, [message_id, content_hash])

  @doc """
  Key for extracting one immutable document version.

  Versions are append-only and content-addressed, so this pair is stable for the
  life of the version: a re-upload of identical bytes reuses the run, and new
  bytes arrive as a new version with its own key.
  """
  @spec document_extraction(Ecto.UUID.t(), String.t()) :: String.t()
  def document_extraction(document_version_id, content_hash),
    do: key(:document_extraction, [document_version_id, content_hash])

  @doc """
  Key for one connector sync pass.

  Includes the cursor, because a pass is defined by where it starts, and the
  scheduled slot, so the next due pass is distinct work rather than a repeat of
  the current one. The cursor is hashed into the digest and never stored in
  readable form.
  """
  @spec connector_sync(Ecto.UUID.t(), map(), term()) :: String.t()
  def connector_sync(connector_id, cursor, scheduled_at),
    do: key(:connector_sync, [connector_id, cursor, scheduled_at])

  @doc """
  Key for a dream-time reasoning pass over one scope.

  The watermark names the pass, so many changes sharing one watermark coalesce
  into a single background pass instead of one pass per change.
  """
  @spec dream_time(Ecto.UUID.t(), term()) :: String.t()
  def dream_time(scope_id, watermark), do: key(:dream_time, [scope_id, watermark])

  @doc """
  Key for refreshing a scope's projections up to a watermark.

  Projections are rebuildable caches, so re-running is harmless; the key exists
  to stop a burst of writes from queueing one rebuild each.
  """
  @spec projection_refresh(Ecto.UUID.t(), term()) :: String.t()
  def projection_refresh(scope_id, watermark),
    do: key(:projection_refresh, [scope_id, watermark])

  @doc "Key for derived-cache work caused by ordinary governed writes in one scope."
  @spec derived_refresh(Ecto.UUID.t(), atom(), DateTime.t(), pos_integer()) :: String.t()
  def derived_refresh(scope_id, kind, %DateTime{} = changed_at, window_seconds)
      when kind in [:projection_refresh, :entity_resolution] and window_seconds > 0 do
    bucket = div(DateTime.to_unix(changed_at, :second), window_seconds)
    key(kind, [scope_id, bucket])
  end

  @doc """
  Key for rebuilding a scope's entity and mention caches up to a watermark.

  Like projections, those rows are derived and disposable; the watermark
  collapses repeated requests into one rebuild.
  """
  @spec entity_resolution(Ecto.UUID.t(), term()) :: String.t()
  def entity_resolution(scope_id, watermark),
    do: key(:entity_resolution, [scope_id, watermark])

  @doc """
  Key for rebuilding one derived cache after a logical archive import.

  `import_id` identifies the thing being rebuilt (a scope or a document
  version); the manifest hash identifies the archive it came from. Together they
  keep two imports of different archives distinct while making a retried import
  of the same archive reuse its runs.
  """
  @spec import_rebuild(String.t(), String.t()) :: String.t()
  def import_rebuild(import_id, manifest_hash),
    do: key(:import_rebuild, [import_id, manifest_hash])

  @doc """
  Key for correlating an answer with the question that prompted it.

  Keyed by the asked question and the session the answer arrived in, so a
  replayed or redelivered resolution reuses the same run.
  """
  @spec answer_correlation(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def answer_correlation(question_id, session_id),
    do: key(:answer_correlation, [question_id, session_id])

  @doc """
  Key for one reconciliation sweep of an Account.

  The watermark distinguishes sweeps. Callers that want to collapse concurrent
  requests into a single sweep must pass the same watermark; a per-call
  timestamp makes every request its own sweep.
  """
  @spec reconciler(Ecto.UUID.t(), term()) :: String.t()
  def reconciler(account_id, watermark), do: key(:reconciler, [account_id, watermark])

  @doc """
  Key for one Account's lifecycle sweep in one scheduler slot.

  `kind` distinguishes expiry from revalidation. `scheduled_at` comes from the
  Cron job, not the time a delayed worker happened to run, so a retry resumes
  the same durable work instead of creating a second sweep.
  """
  @spec lifecycle_sweep(Ecto.UUID.t(), String.t(), DateTime.t()) :: String.t()
  def lifecycle_sweep(account_id, kind, %DateTime{} = scheduled_at)
      when kind in ["revalidation", "expiry"] do
    key(:lifecycle_sweep, [account_id, kind, DateTime.to_iso8601(scheduled_at)])
  end

  @doc "Key for one Account-wide dream-time pass in one Cron slot."
  @spec account_dream_time(Ecto.UUID.t(), DateTime.t()) :: String.t()
  def account_dream_time(account_id, %DateTime{} = scheduled_at),
    do: key(:account_dream_time, [account_id, DateTime.to_iso8601(scheduled_at)])

  @doc """
  Key for rebuilding all derived vectors into one embedding identity.

  A retry of the same transition resumes its durable run. A later model,
  version, or dimension change creates separate work.
  """
  def reembed(account_id, identity), do: key(:reembed, [account_id, identity])

  @doc """
  The system's standard content digest: lowercase hex SHA-256 of raw bytes.

  Used for message content, document blobs, and statement text. It is what lets
  identity, deduplication, and audit evidence refer to content without storing
  it, so the encoding is a durable format — every stored hash was produced this
  way, and changing the algorithm or the casing invalidates all of them.
  """
  @spec content_hash(binary()) :: String.t()
  def content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Builds a key from a family name and its identifying components.

  The components are serialised with deterministic term encoding before
  hashing, so the same values always produce the same key across processes,
  nodes, and releases — ordinary term encoding does not guarantee that for maps
  and would make keys unstable. The result is
  `"<family>:<url-safe base64 SHA-256>"`: the family stays readable for
  operators while every component value is reduced to a digest, keeping cursors
  and other potentially sensitive components out of durable queue rows.

  Component order is part of the identity. Reordering the list, adding a
  component, or changing a component's type produces different keys and lets
  already-completed work run again.
  """
  @spec key(atom(), list()) :: String.t()
  def key(kind, components) when is_atom(kind) and is_list(components) do
    digest =
      components
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "#{kind}:#{digest}"
  end
end
