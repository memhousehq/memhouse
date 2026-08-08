# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Documents.Portability do
  @moduledoc """
  Exports, imports, and erases one document.

  Bundles carry durable identity, version metadata, and checksum-verified original bytes. They
  omit chunks, embeddings, extracted text, and derived knowledge; import replays ordinary ingest
  under destination parsing, embedding, and governance.

  The `f6-document-1` manifest string versions the bundle format. Shape changes require a new
  identity and documented compatibility decision.

  Erasure removes document-exclusive blobs and knowledge, but preserves shared blobs, independently
  supported knowledge, and content-safe audit evidence.
  """

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Documents.BlobStore
  alias MemHouse.Documents.DocumentChunk
  alias MemHouse.Documents.Service
  alias MemHouse.Governance.Audit
  alias MemHouse.Governance.Erasure
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.Provenance
  alias MemHouse.Observations.Document
  alias MemHouse.Observations.DocumentVersion
  alias MemHouse.Pipeline.Idempotency

  require Ash.Query

  # Bundle contract identity; changing it requires a documented format transition.
  @schema "f6-document-1"

  @doc """
  Builds a self-contained bundle for one document: metadata, version history, and its bytes.

  The document is read under the caller's own authorization, so a document the actor may not
  see raises not-found rather than exporting.

  Returns `{:ok, bundle}`. The bundle is a plain string-keyed map with a `"manifest"` (schema
  string and counts), the `"document"` metadata, `"versions"` in ascending version order, and
  `"blobs"` — a list in the same order, each entry carrying its content hash, media type, and
  bytes. The manifest states outright that derived chunks are excluded and will be rebuilt on
  import.

  Raises if a stored blob no longer hashes to the digest its version recorded — a bundle is
  either provably intact or it is not produced.
  """
  def export_document(%Actor{} = actor, document_id) when is_binary(document_id) do
    bundle =
      DataLayer.with_actor(actor, fn account, current_actor ->
        document = read_one!(Document, document_id, account.id, current_actor)

        versions =
          DocumentVersion
          |> Ash.Query.filter(document_id == ^document.id)
          |> Ash.Query.sort(version: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: current_actor)

        blobs =
          Enum.map(versions, fn version ->
            {:ok, bytes} = Service.load_version_bytes(version)

            # Refuse to archive blob-store corruption.
            if Idempotency.content_hash(bytes) != version.content_hash do
              raise "document blob checksum mismatch for version #{version.id}"
            end

            %{
              "content_hash" => version.content_hash,
              "media_type" => version.media_type,
              "bytes" => bytes
            }
          end)

        %{
          "manifest" => %{
            "schema" => @schema,
            "document_count" => 1,
            "version_count" => length(versions),
            "blob_count" => length(blobs),
            "derived_chunks" => "excluded_rebuild_on_import"
          },
          "document" => serialize_document(document),
          "versions" => Enum.map(versions, &serialize_version/1),
          "blobs" => blobs
        }
      end)

    {:ok, bundle}
  end

  @doc """
  Restores an exported document by replaying every version through ordinary ingest.

  Versions are replayed in ascending version order, and that ordering is required: each ingest
  compares against the document's current content hash, so replaying out of order would produce
  a different history and leave the wrong version current. Because it is ordinary ingest, the
  target rebuilds chunks and embeddings itself and every extracted statement passes the target's
  own governance gates — an import cannot smuggle in pre-approved knowledge.

  Returns `{:ok, results}`, one ingest result per version, or
  `{:error, :unsupported_document_bundle}` when the manifest schema is not one this build reads.

  Raises `ArgumentError` on a blob whose bytes do not match the checksum recorded for them, and
  `KeyError` when the bundle is missing a version's blob.
  """
  def import_document(%Actor{} = actor, %{"manifest" => %{"schema" => @schema}} = bundle) do
    document = Map.fetch!(bundle, "document")
    # Match each version to bytes by content hash.
    blobs = Map.new(Map.fetch!(bundle, "blobs"), &{Map.fetch!(&1, "content_hash"), &1})

    results =
      bundle
      |> Map.fetch!("versions")
      |> Enum.sort_by(&Map.fetch!(&1, "version"))
      |> Enum.map(fn version ->
        blob = Map.fetch!(blobs, Map.fetch!(version, "content_hash"))
        bytes = Map.fetch!(blob, "bytes")

        # Verify untrusted archive bytes before writing durable state.
        if Idempotency.content_hash(bytes) != Map.fetch!(version, "content_hash") do
          raise ArgumentError, "document import blob checksum mismatch"
        end

        {:ok, result} =
          Service.ingest_bytes(actor, %{
            scope_id: Map.fetch!(document, "scope_id"),
            owner_peer_id: Map.fetch!(document, "owner_peer_id"),
            external_id: Map.fetch!(document, "external_id"),
            title: Map.fetch!(document, "title"),
            source_kind: Map.get(document, "source_kind", "import"),
            source_uri: Map.get(document, "source_uri"),
            source_metadata: Map.get(document, "source_metadata", %{}),
            media_type: Map.fetch!(version, "media_type"),
            occurred_at: Map.fetch!(version, "occurred_at"),
            bytes: bytes
          })

        result
      end)

    {:ok, results}
  end

  # Refuse unknown formats instead of guessing.
  def import_document(_actor, _bundle), do: {:error, :unsupported_document_bundle}

  @doc """
  Permanently removes a document, its chunks, its exclusive bytes, and the knowledge only it
  supported.

  In order: the document's versions are collected, knowledge supported solely by those versions
  is erased (and provenance rows are dropped from knowledge that survives), chunks are
  destroyed, a content-safe audit entry is written, the blob references belonging only to this
  document are worked out, and the document row is destroyed. Blob objects are deleted after the
  transaction commits.

  Returns `:ok`. Raises `Ash.Error.Forbidden` unless the caller owns the document, is a curator
  or account admin, or is the pipeline; raises `Ash.Error.Query.NotFound` if the document is not
  visible to the actor.
  """
  def erase_document(%Actor{} = actor, document_id) when is_binary(document_id) do
    # Delete blobs after commit: crashes may orphan objects but cannot leave dangling rows.
    blob_refs =
      DataLayer.with_actor(actor, fn account, current_actor ->
        document = read_one!(Document, document_id, account.id, current_actor)
        authorize_erasure!(document, current_actor)
        pipeline = pipeline_actor(current_actor)

        versions =
          DocumentVersion
          |> Ash.Query.filter(document_id == ^document.id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: pipeline)

        version_ids = MapSet.new(versions, & &1.id)
        erase_document_knowledge!(account.id, pipeline, version_ids)

        chunks =
          DocumentChunk
          |> Ash.Query.filter(document_id == ^document.id)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: pipeline)

        Enum.each(chunks, &destroy!(&1, pipeline))

        # Durable erasure audit records counts only, never erased content metadata.
        Audit.append!(pipeline, account.id, %{
          scope_id: document.scope_id,
          actor_peer_id: current_actor.peer_id,
          category: "deletion",
          action: "document.erased",
          resource_type: "document",
          resource_id: document.id,
          metadata: %{
            "version_count" => length(versions),
            "chunk_count" => length(chunks)
          }
        })

        # Delete only blobs unreferenced by other documents.
        exclusive_refs =
          versions
          |> Enum.map(& &1.blob_ref)
          |> Enum.uniq()
          |> Enum.filter(&exclusive_blob_ref?(&1, document.id, account.id, pipeline))

        destroy!(document, pipeline)
        exclusive_refs
      end)

    Enum.each(blob_refs, fn blob_ref ->
      :ok = BlobStore.delete(blob_ref)
    end)

    :ok
  end

  # Erase document-exclusive knowledge through governance; otherwise remove only this provenance.
  defp erase_document_knowledge!(account_id, actor, version_ids) do
    provenances =
      Provenance
      |> Ash.Query.filter(document_version_id in ^MapSet.to_list(version_ids))
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    knowledge_ids = provenances |> Enum.map(& &1.knowledge_item_id) |> Enum.uniq()

    knowledge =
      KnowledgeItem
      |> Ash.Query.filter(id in ^knowledge_ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    {sole_source, retained} =
      Enum.split_with(knowledge, fn item ->
        all =
          Provenance
          |> Ash.Query.filter(knowledge_item_id == ^item.id)
          |> Ash.Query.set_tenant(account_id)
          |> Ash.read!(actor: actor)

        Enum.all?(all, fn provenance ->
          provenance.document_version_id &&
            MapSet.member?(version_ids, provenance.document_version_id)
        end)
      end)

    Erasure.erase_knowledge_rows!(account_id, actor, sole_source)

    retained_ids = MapSet.new(retained, & &1.id)

    provenances
    |> Enum.filter(&MapSet.member?(retained_ids, &1.knowledge_item_id))
    |> Enum.each(&destroy!(&1, actor))
  end

  # Account-namespaced blobs may be deleted only when no other document references the hash.
  defp exclusive_blob_ref?(blob_ref, document_id, account_id, actor) do
    DocumentVersion
    |> Ash.Query.filter(blob_ref == ^blob_ref and document_id != ^document_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
    |> is_nil()
  end

  # Export only fields needed for fresh ingest; destination derives installation-local state.
  defp serialize_document(document) do
    %{
      "scope_id" => document.scope_id,
      "owner_peer_id" => document.owner_peer_id,
      "external_id" => document.external_id,
      "title" => document.title,
      "source_kind" => document.source_kind,
      "source_uri" => document.source_uri,
      "source_metadata" => document.source_metadata
    }
  end

  # Omit derived text, metadata, and chunks so the destination rebuilds them.
  defp serialize_version(version) do
    %{
      "version" => version.version,
      "content_hash" => version.content_hash,
      "byte_size" => version.byte_size,
      "media_type" => version.media_type,
      "source_metadata" => version.source_metadata,
      "occurred_at" => version.occurred_at
    }
  end

  # Reading a document does not grant irreversible erasure authority.
  defp authorize_erasure!(document, actor) do
    allowed =
      actor.pipeline? ||
        actor.role in [:account_admin, :curator] ||
        document.owner_peer_id == actor.peer_id

    unless allowed, do: raise(Ash.Error.Forbidden, errors: [])
  end

  # Unauthorized and missing rows are indistinguishable.
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

  defp destroy!(record, actor) do
    record
    |> Ash.Changeset.for_destroy(:erase)
    |> Ash.Changeset.set_tenant(record.account_id)
    |> Ash.destroy!(actor: actor)
  end

  # Add pipeline write privileges without changing the authorized Account.
  defp pipeline_actor(%Actor{} = actor), do: %{actor | role: :system, pipeline?: true}
end
