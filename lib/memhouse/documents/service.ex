# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Documents.Service do
  @moduledoc """
  Implements document ingest, derivation, sync, tombstoning, and rebuild.

  Caller writes store raw bytes and metadata, then queue work. Only the internal pipeline parses,
  chunks, embeds, extracts, governs, and supersedes knowledge.

  Identical hashes are no-ops, chunk writes upsert, and connector cursors advance only after a
  page commits. Version, audit, extraction job, and reconciler job commit together in an
  Account-scoped transaction.

  Audit, telemetry, and jobs may carry ids, hashes, counts, media types, parser names, and error
  classes. Never include bytes, text, statements, cursors, source metadata, secrets, or provider
  error messages.
  """

  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Documents.BlobStore
  alias MemHouse.Documents.Chunker
  alias MemHouse.Documents.Connector
  alias MemHouse.Documents.ConnectorConfig
  alias MemHouse.Documents.DocumentChunk
  alias MemHouse.Documents.Parser
  alias MemHouse.Governance.Audit
  alias MemHouse.Governance.Engine
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.KnowledgeRelation
  alias MemHouse.Knowledge.Provenance
  alias MemHouse.Memory
  alias MemHouse.Observability
  alias MemHouse.Observations.Document
  alias MemHouse.Observations.DocumentVersion
  alias MemHouse.Pipeline
  alias MemHouse.Pipeline.Extractor
  alias MemHouse.Pipeline.Idempotency
  alias MemHouse.Topology.Scope

  require Ash.Query

  @doc """
  Accepts one document payload: stores the bytes, then appends a version if the content changed.

  `attrs` may use atom or string keys. `"scope_id"` and `"bytes"` are required and a missing one
  raises `KeyError`. `"external_id"` identifies the document within its source and defaults to a
  fresh UUID, which makes each anonymous upload its own document. `"connector_config_id"`,
  `"title"`, `"source_kind"`, `"source_uri"`, `"source_metadata"`, `"media_type"`,
  `"occurred_at"`, and `"owner_peer_id"` are optional.

  Returns `{:ok, %{status: :created | :unchanged, document: document, version: version}}`.
  On `:unchanged`, `version` is the document's existing current version (or `nil` if it somehow
  has none) and nothing was written.

  A blob-store failure returns `{:error, reason}` before any database work happens. After that
  point the writes are raising Ash calls, so an authorization or validation failure raises.
  """
  def ingest_bytes(%Actor{} = actor, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    bytes = Map.fetch!(attrs, "bytes")
    content_hash = Idempotency.content_hash(bytes)

    # Store content-addressed bytes first: rollback may orphan a blob but cannot commit a dangling
    # reference or overwrite different content.
    with {:ok, blob_ref} <-
           BlobStore.put(actor.account_id, content_hash, bytes,
             media_type: Map.get(attrs, "media_type", "application/octet-stream")
           ) do
      result =
        DataLayer.with_actor(actor, fn account, current_actor ->
          do_ingest(account.id, current_actor, attrs, bytes, content_hash, blob_ref)
        end)

      {:ok, result}
    end
  end

  @doc """
  Runs the full derivation for one durable document version: parse, chunk, embed, extract.

  Called from the queued extraction job rather than by a caller, which is why it takes an
  Account id instead of an actor: it opens its own transactions under a system actor with
  pipeline privileges, the only identity allowed to write chunks or mark a version processed.

  Uses a short read transaction, external derivation without a database connection, then a short
  write transaction. This avoids holding a pooled connection across storage and model calls.

  Returns `{:ok, version}` with processing bookkeeping recorded, or `{:error, reason}`. On
  failure the version is marked failed with an error *class* and the raw version, its blob, its
  audit entry, and its retryable job all survive, so nothing has to be re-ingested.
  """
  def process_version_for_account(version_id, account_id)
      when is_binary(version_id) and is_binary(account_id) do
    Observability.with_span(:documents, "memhouse.documents.process_version", fn ->
      # The actor is a plain Account/role struct and remains valid after the read transaction.
      {actor, version, document, owner, scope} =
        DataLayer.with_account_id(
          account_id,
          [role: :system, pipeline?: true],
          fn _account, actor ->
            {version, document, owner, scope} =
              read_version_for_processing(version_id, account_id, actor)

            {actor, version, document, owner, scope}
          end
        )

      case derive_version(version, document, owner, scope, account_id, actor) do
        {:ok, derived} ->
          DataLayer.with_account_id(
            account_id,
            [role: :system, pipeline?: true],
            fn _account, write_actor ->
              persist_derivation!(derived, version, document, account_id, write_actor)
            end
          )

        {:error, error} ->
          DataLayer.with_account_id(
            account_id,
            [role: :system, pipeline?: true],
            fn _account, write_actor -> mark_version_failed!(version, write_actor, error) end
          )

          {:error, error}
      end
    end)
  end

  @doc """
  Registers an external document source and queues its first sync immediately.

  `attrs` requires `"scope_id"`, `"name"`, and `"kind"`; the kind must match an adapter the
  deployment registered in configuration, though that lookup happens at sync time rather than
  here. `"schedule_seconds"` defaults to one hour, `"status"` to `"active"`, and
  `"next_sync_at"` to now, so a freshly registered connector runs at once. `"config"` must
  hold secret *references*, not credentials; the resource validation rejects settings keys
  whose names look like credentials.

  Returns the created connector. Raises on authorization or validation failure — the resource
  policy admits only an authenticated human holding an admin or curator grant in the scope, or
  a pipeline actor.
  """
  def register_connector(%Actor{} = actor, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    DataLayer.with_actor(actor, fn account, current_actor ->
      connector =
        create!(
          ConnectorConfig,
          :create,
          %{
            scope_id: Map.fetch!(attrs, "scope_id"),
            owner_peer_id: Map.get(attrs, "owner_peer_id", current_actor.peer_id),
            name: Map.fetch!(attrs, "name"),
            kind: Map.fetch!(attrs, "kind"),
            schedule_seconds: Map.get(attrs, "schedule_seconds", 3600),
            config: Map.get(attrs, "config", %{}),
            secret_ref: Map.get(attrs, "secret_ref"),
            cursor: Map.get(attrs, "cursor", %{}),
            status: Map.get(attrs, "status", "active"),
            next_sync_at: Map.get(attrs, "next_sync_at", Clock.utc_now())
          },
          account.id,
          current_actor
        )

      # Record connector shape, never settings or secret references.
      Audit.append!(current_actor, account.id, %{
        scope_id: connector.scope_id,
        actor_peer_id: current_actor.peer_id,
        category: "configuration",
        action: "connector.created",
        resource_type: "connector_config",
        resource_id: connector.id,
        metadata: %{
          "kind" => connector.kind,
          "schedule_seconds" => connector.schedule_seconds
        }
      })

      {:ok, _run} = Pipeline.enqueue_connector_sync(connector, current_actor)
      connector
    end)
  end

  @doc """
  Queues a sync for every active connector in the Account that is due to run.

  Nothing polls connectors on a timer. The Account reconciler runs an equivalent sweep of its
  own, so this entry point is the standalone way to trigger one. Sync jobs carry a
  deterministic key derived from the connector, its cursor, and the scheduled time, so a
  connector swept twice before its job runs does not produce two runs.

  Returns a list of enqueue results, one per due connector.
  """
  def enqueue_due_connectors(account_id) when is_binary(account_id) do
    DataLayer.with_account_id(
      account_id,
      [role: :system, pipeline?: true],
      fn _account, actor ->
        now = Clock.utc_now()

        # A connector with no schedule has never run and is due.
        ConnectorConfig
        |> Ash.Query.filter(status == "active" and (is_nil(next_sync_at) or next_sync_at <= ^now))
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)
        |> Enum.map(&Pipeline.enqueue_connector_sync(&1, actor))
      end
    )
  end

  @doc """
  Runs one sync pass for a connector: pull a page, apply every item, then move the cursor.

  The adapter is resolved from the connector's kind and asked for the items following its
  current cursor. Every item is applied first — new bytes become a version, identical bytes are
  a no-op, a deletion becomes a tombstone — and the cursor is written only after the whole page
  has been handled. That ordering is the durability guarantee: interrupting this function
  re-fetches the same page next time, which is safe, instead of skipping it, which is not.

  Returns `{:ok, %{connector: connector, counts: counts}}` with per-outcome counts, and queues
  a follow-up sync when the adapter says more pages remain. An adapter error returns
  `{:error, reason}` after recording the error class, bumping the failure counter, and pushing
  the connector's next scheduled sync out by one interval; the cursor is left untouched.

  Raises `ArgumentError` when the connector's kind has no adapter registered in this build, and
  `Ash.Error.Query.NotFound` when the connector does not exist in the Account.
  """
  def sync_connector_for_account(connector_id, account_id)
      when is_binary(connector_id) and is_binary(account_id) do
    Observability.with_span(:documents, "memhouse.documents.sync_connector", fn ->
      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn account, actor ->
          connector = read_one!(ConnectorConfig, connector_id, account.id, actor)
          adapter = Connector.adapter!(connector.kind)

          case adapter.pull(connector, connector.cursor) do
            {:ok, page} ->
              apply_connector_page(account.id, actor, connector, page)

            {:error, error} ->
              mark_connector_failed!(connector, actor, error)
              {:error, error}
          end
        end
      )
    end)
  end

  @doc """
  Records that a document no longer exists at its source, without destroying any history.

  The document is looked up under the caller's own authorization, so a caller cannot tombstone
  something they may not see; the mutation itself then runs as the pipeline, because it has to
  touch chunks and knowledge lifecycle rows the caller cannot write.

  Returns the tombstoned document. Raises `Ash.Error.Query.NotFound` when the document is not
  visible to the actor.
  """
  def tombstone_document(%Actor{} = actor, document_id) when is_binary(document_id) do
    DataLayer.with_actor(actor, fn account, current_actor ->
      document = read_one!(Document, document_id, account.id, current_actor)
      tombstone_document_record!(account.id, pipeline_actor(current_actor), document)
    end)
  end

  @doc """
  Regenerates a version's derived caches by re-running processing over the stored bytes.

  Rebuild and first-time processing are the same operation: chunks upsert by position and the
  extractor re-runs, so this is how a changed chunk geometry, a new parser, or a new embedding
  identity is applied to already-ingested documents. Same returns and failure modes as
  `process_version_for_account/2`.
  """
  def rebuild_version_for_account(version_id, account_id),
    do: process_version_for_account(version_id, account_id)

  # Read legacy inline content before blob storage; immutable historical rows were not rewritten.
  @doc false
  def load_version_bytes(%DocumentVersion{content: content}) when is_binary(content),
    do: {:ok, content}

  def load_version_bytes(%DocumentVersion{blob_ref: blob_ref}), do: BlobStore.get(blob_ref)

  # Shared upload/sync path inside an Account transaction after bytes are stored and hashed.
  defp do_ingest(account_id, actor, attrs, bytes, content_hash, blob_ref) do
    connector_config_id = Map.get(attrs, "connector_config_id")
    # Anonymous uploads get fresh identities and never collide.
    external_id = Map.get(attrs, "external_id", Ecto.UUID.generate())

    document =
      find_document(account_id, actor, connector_config_id, external_id) ||
        create!(
          Document,
          :create,
          %{
            scope_id: Map.fetch!(attrs, "scope_id"),
            owner_peer_id: Map.get(attrs, "owner_peer_id", actor.peer_id),
            connector_config_id: connector_config_id,
            external_id: external_id,
            title: Map.get(attrs, "title", external_id),
            source_kind: Map.get(attrs, "source_kind", "upload"),
            source_uri: Map.get(attrs, "source_uri"),
            source_metadata: Map.get(attrs, "source_metadata", %{}),
            status: "active"
          },
          account_id,
          actor
        )

    # Identical bytes create no version, audit entry, or job, making page replay safe.
    if document.current_content_hash == content_hash do
      %{
        status: :unchanged,
        document: document,
        version: current_version(document, account_id, actor)
      }
    else
      # The create hook commits audit, extraction, and reconciliation with the version.
      version =
        create!(
          DocumentVersion,
          :create,
          %{
            document_id: document.id,
            scope_id: document.scope_id,
            version: next_version(document.id, account_id, actor),
            content_hash: content_hash,
            byte_size: byte_size(bytes),
            blob_ref: blob_ref,
            media_type: Map.get(attrs, "media_type", "application/octet-stream"),
            source_metadata: Map.get(attrs, "source_metadata", %{}),
            occurred_at: Map.get(attrs, "occurred_at", Clock.utc_now())
          },
          account_id,
          actor
        )

      pipeline_actor = pipeline_actor(actor)

      # Pipeline-only pointer update revives a tombstoned source without losing history.
      published =
        document
        |> Ash.Changeset.for_update(:publish_version, %{
          current_version_id: version.id,
          current_content_hash: content_hash,
          status: "active",
          tombstoned_at: nil
        })
        |> Ash.Changeset.set_tenant(account_id)
        |> Ash.update!(actor: pipeline_actor)

      %{status: :created, document: published, version: version}
    end
  end

  # Read all derivation inputs, including allowed peer keys, in one short transaction.
  defp read_version_for_processing(version_id, account_id, actor) do
    version = read_one!(DocumentVersion, version_id, account_id, actor)
    document = read_one!(Document, version.document_id, account_id, actor)
    owner = read_one!(MemHouse.Accounts.Peer, document.owner_peer_id, account_id, actor)
    scope = read_one!(Scope, document.scope_id, account_id, actor)

    {version, document, owner, scope}
  end

  # External phase: bytes, text, chunks, then candidates. Never hold a database transaction here.
  defp derive_version(version, document, owner, scope, account_id, actor) do
    context = %{account_id: account_id, scope_id: version.scope_id, actor: actor}

    with {:ok, bytes} <- load_version_bytes(version),
         {:ok, parsed} <- Parser.extract(bytes, version.media_type),
         {:ok, chunks} <- Chunker.chunk_and_embed(parsed.text, parsed.format, context) do
      # Keep source separate from subject; document candidates enter ordinary governance.
      {observation, extract_context} =
        Memory.document_observation(account_id, actor, %{
          id: version.id,
          scope_id: document.scope_id,
          peer_id: owner.id,
          peer_key: owner.key,
          scope_path: scope.path,
          role: "document",
          content: parsed.text,
          occurred_at: version.occurred_at
        })

      with {:ok, items} <- Extractor.extract(observation, extract_context) do
        {:ok, %{parsed: parsed, chunks: chunks, observation: observation, items: items}}
      end
    end
  end

  # Commit chunks, governed knowledge, supersession, and bookkeeping together. Supersession runs
  # after the new version's support is known.
  defp persist_derivation!(derived, version, document, account_id, actor) do
    %{parsed: parsed, chunks: chunks, observation: observation, items: items} = derived

    :ok = persist_chunks(version, chunks, actor)

    knowledge = Memory.persist_document_knowledge!(account_id, actor, observation, items)

    :ok = supersede_prior_derivations(document, version, knowledge, actor)

    processed =
      version
      |> Ash.Changeset.for_update(:mark_processed, %{
        extracted_text: parsed.text,
        extraction_metadata: parsed.metadata,
        chunk_count: length(chunks),
        embedded_chunk_count: Enum.count(chunks, &(not is_nil(&1.embedding))),
        processing_status: "complete",
        extraction_completed_at: Clock.utc_now()
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)

    # Content-safe tracing only: ids, sizes, counts, and parser name.
    Observability.set_attributes(:documents, %{
      "memhouse.document.version_id" => version.id,
      "memhouse.document.byte_size" => version.byte_size,
      "memhouse.document.chunk_count" => length(chunks),
      "memhouse.document.knowledge_count" => length(knowledge),
      "memhouse.document.parser" => Map.get(parsed.metadata, "parser", "unknown")
    })

    {:ok, processed}
  end

  # Upsert derived chunks by version/position so reprocessing converges.
  defp persist_chunks(version, chunks, actor) do
    Enum.each(chunks, fn chunk ->
      create!(
        DocumentChunk,
        :upsert_from_pipeline,
        Map.merge(chunk, %{
          document_id: version.document_id,
          document_version_id: version.id,
          scope_id: version.scope_id,
          status: "active"
        }),
        version.account_id,
        actor
      )
    end)

    :ok
  end

  # Supersede old chunks freely. Retire knowledge through governance only when the new version did
  # not reproduce it, all provenance belongs to older versions of this document, and state is not
  # terminal. Shared support always survives.
  defp supersede_prior_derivations(document, version, knowledge, actor) do
    prior_chunks =
      DocumentChunk
      |> Ash.Query.filter(document_id == ^document.id and document_version_id != ^version.id)
      |> Ash.Query.set_tenant(document.account_id)
      |> Ash.read!(actor: actor)

    Enum.each(prior_chunks, fn chunk ->
      chunk
      |> Ash.Changeset.for_update(:supersede, %{status: "superseded"})
      |> Ash.Changeset.set_tenant(document.account_id)
      |> Ash.update!(actor: actor)
    end)

    # Reproduced statements retain identity through merged provenance.
    current_ids = MapSet.new(knowledge, & &1["id"])
    # Use one new statement as replacement; no new statement means no relation.
    replacement_id = knowledge |> List.first() |> then(&(&1 && &1["id"]))

    prior_version_ids = prior_version_ids(document, version, actor)

    prior_knowledge(document, prior_version_ids, actor)
    |> Enum.reject(&MapSet.member?(current_ids, &1.id))
    |> Enum.filter(fn knowledge ->
      solely_supported_by_versions?(knowledge, prior_version_ids, actor) and
        knowledge.state not in ~w(superseded expired rejected retracted redacted)
    end)
    |> Enum.each(fn old ->
      updated =
        Engine.transition!(
          old,
          actor,
          %{state: "superseded", verification: "document_version_changed"},
          reason: "f6_document_version_superseded",
          channel: "document_sync"
        )

      if replacement_id do
        create!(
          KnowledgeRelation,
          :create_from_pipeline,
          %{
            scope_id: old.scope_id,
            source_knowledge_id: replacement_id,
            target_knowledge_id: old.id,
            kind: "supersedes",
            confidence: 1.0
          },
          old.account_id,
          actor
        )
      end

      updated
    end)

    :ok
  end

  # Find prior supported knowledge through provenance, never text.
  defp prior_knowledge(document, prior_version_ids, actor) do
    knowledge_ids =
      Provenance
      |> Ash.Query.filter(source_type == "document" and document_version_id in ^prior_version_ids)
      |> Ash.Query.set_tenant(document.account_id)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.knowledge_item_id)
      |> Enum.uniq()

    KnowledgeItem
    |> Ash.Query.filter(id in ^knowledge_ids)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
  end

  # Compare version numbers so out-of-order processing still supersedes correctly.
  defp prior_version_ids(document, version, actor) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document.id and version < ^version.version)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  # Handle every item before committing the cursor in the same Account transaction. Reordering
  # this can silently skip documents; replay is safe.
  defp apply_connector_page(account_id, actor, connector, page) do
    items = Map.fetch!(page, :items)

    counts =
      Enum.reduce(items, %{created: 0, unchanged: 0, tombstoned: 0}, fn item, counts ->
        apply_connector_item(account_id, actor, connector, item, counts)
      end)

    now = Clock.utc_now()
    cursor = Map.fetch!(page, :cursor)

    # Successful progress advances the cursor and clears failures.
    updated =
      connector
      |> Ash.Changeset.for_update(:advance_cursor, %{
        cursor: cursor,
        last_synced_at: now,
        next_sync_at: DateTime.add(now, connector.schedule_seconds, :second),
        last_error_class: nil,
        consecutive_failures: 0
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)

    # Audit counts only, never titles, external ids, or cursor.
    Audit.append!(actor, account_id, %{
      scope_id: connector.scope_id,
      category: "observation",
      action: "connector.synced",
      resource_type: "connector_config",
      resource_id: connector.id,
      metadata: Map.merge(stringify_keys(counts), %{"item_count" => length(items)})
    })

    # Key the next page by its new cursor so deduplication does not discard it.
    if Map.get(page, :has_more?, false) do
      {:ok, _run} = Pipeline.enqueue_connector_sync(updated, actor)
    end

    {:ok, %{connector: updated, counts: counts}}
  end

  # Page items are replay-safe: tombstone, unchanged no-op, or appended version.
  defp apply_connector_item(account_id, actor, connector, item, counts) do
    external_id = Map.fetch!(item, :external_id)

    if Map.get(item, :deleted?, false) do
      case find_document(account_id, actor, connector.id, external_id) do
        nil ->
          counts

        document ->
          tombstone_document_record!(account_id, actor, document)
          Map.update!(counts, :tombstoned, &(&1 + 1))
      end
    else
      bytes = Map.fetch!(item, :bytes)
      content_hash = Idempotency.content_hash(bytes)
      {:ok, blob_ref} = BlobStore.put(account_id, content_hash, bytes)

      result =
        do_ingest(
          account_id,
          actor,
          %{
            "scope_id" => connector.scope_id,
            "owner_peer_id" => connector.owner_peer_id,
            "connector_config_id" => connector.id,
            "external_id" => external_id,
            "title" => Map.get(item, :title, external_id),
            "source_kind" => "connector",
            "source_uri" => Map.get(item, :source_uri),
            "source_metadata" => Map.get(item, :metadata, %{}),
            "media_type" => Map.get(item, :media_type, "application/octet-stream"),
            "occurred_at" => Map.get(item, :occurred_at, Clock.utc_now())
          },
          bytes,
          content_hash,
          blob_ref
        )

      Map.update!(counts, result.status, &(&1 + 1))
    end
  end

  # Tombstoning preserves history. Retract only document-exclusive knowledge; independent support
  # survives, and a returning source clears the tombstone.
  defp tombstone_document_record!(account_id, actor, document) do
    tombstoned =
      document
      |> Ash.Changeset.for_update(:tombstone, %{
        status: "tombstoned",
        tombstoned_at: Clock.utc_now()
      })
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)

    DocumentChunk
    |> Ash.Query.filter(document_id == ^document.id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn chunk ->
      chunk
      |> Ash.Changeset.for_update(:supersede, %{status: "tombstoned"})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor)
    end)

    version_ids = document_version_ids(document, actor)

    document
    |> all_document_knowledge(version_ids, actor)
    |> Enum.filter(fn knowledge ->
      solely_supported_by_versions?(knowledge, version_ids, actor) and
        knowledge.state not in ~w(retracted redacted rejected superseded expired)
    end)
    |> Enum.each(fn knowledge ->
      Engine.transition!(
        knowledge,
        actor,
        %{state: "retracted", verification: "source_tombstoned"},
        reason: "f6_connector_tombstone",
        channel: "document_sync"
      )
    end)

    Audit.append!(actor, account_id, %{
      scope_id: document.scope_id,
      category: "lifecycle",
      action: "document.tombstoned",
      resource_type: "document",
      resource_id: document.id,
      metadata: %{"connector_config_id" => document.connector_config_id}
    })

    tombstoned
  end

  # All knowledge ever supported by this document.
  defp all_document_knowledge(document, version_ids, actor) do
    ids =
      Provenance
      |> Ash.Query.filter(document_version_id in ^version_ids)
      |> Ash.Query.set_tenant(document.account_id)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.knowledge_item_id)
      |> Enum.uniq()

    KnowledgeItem
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
  end

  defp document_version_ids(document, actor) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document.id)
    |> Ash.Query.set_tenant(document.account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  # Require non-empty, exclusively matching provenance before retirement or erasure.
  defp solely_supported_by_versions?(knowledge, version_ids, actor) do
    version_ids = MapSet.new(version_ids)

    provenances =
      Provenance
      |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
      |> Ash.Query.set_tenant(knowledge.account_id)
      |> Ash.read!(actor: actor)

    provenances != [] and
      Enum.all?(provenances, fn provenance ->
        provenance.document_version_id &&
          MapSet.member?(version_ids, provenance.document_version_id)
      end)
  end

  # Preserve the cursor on failure so the page retries; back off one polling interval.
  defp mark_connector_failed!(connector, actor, error) do
    connector
    |> Ash.Changeset.for_update(:advance_cursor, %{
      last_error_class: error_class(error),
      consecutive_failures: connector.consecutive_failures + 1,
      next_sync_at: DateTime.add(Clock.utc_now(), connector.schedule_seconds, :second)
    })
    |> Ash.Changeset.set_tenant(connector.account_id)
    |> Ash.update!(actor: actor)
  end

  # Keep raw version, blob, audit, and job retryable after derivation failure.
  defp mark_version_failed!(version, actor, error) do
    version
    |> Ash.Changeset.for_update(:mark_failed, %{
      processing_status: "failed",
      last_error_class: error_class(error)
    })
    |> Ash.Changeset.set_tenant(version.account_id)
    |> Ash.update!(actor: actor)
  end

  # Connector is part of source identity; uploads match only uploads.
  defp find_document(account_id, actor, connector_config_id, external_id) do
    query =
      if connector_config_id do
        Ash.Query.filter(
          Document,
          connector_config_id == ^connector_config_id and external_id == ^external_id
        )
      else
        Ash.Query.filter(Document, is_nil(connector_config_id) and external_id == ^external_id)
      end

    query
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  defp current_version(%{current_version_id: nil}, _account_id, _actor), do: nil

  defp current_version(document, account_id, actor),
    do: read_one!(DocumentVersion, document.current_version_id, account_id, actor)

  # Dense versions derive from the maximum; uniqueness catches concurrent duplicate numbers.
  defp next_version(document_id, account_id, actor) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document_id)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> 1
      version -> version.version + 1
    end
  end

  # Tenant and actor filters make unauthorized rows indistinguishable from missing rows.
  defp read_one!(resource, id, account_id, actor) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> raise Ash.Error.Query.NotFound, resource: resource
      record -> record
    end
  end

  # Hooks read the actor from changeset context when Ash does not pass it through.
  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{memhouse_actor: actor})
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  # Add pipeline write privileges without changing Account or peer identity.
  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}

  defp normalize_attrs(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  # Persist only error classes; provider messages may contain document content.
  defp error_class(%module{}), do: inspect(module)
  defp error_class(error) when is_atom(error), do: Atom.to_string(error)
  defp error_class(_error), do: "document_error"
end
