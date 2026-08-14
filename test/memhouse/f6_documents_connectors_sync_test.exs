# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.F6DocumentsConnectorsSyncTest.Provider do
  @moduledoc """
  Deterministic document-ingest provider. It emits one candidate per sentence
  of at least eight characters and a mechanical three-element embedding, making
  revision and supersession expectations exact. Chat and rerank fail because
  this path must not call them.

  A sentence naming a weekday is labelled an event and left undated, which is
  the case a document has to handle without a conversational turn to date it.

  The suite installs it in node-global configuration and runs synchronously.
  """

  @behaviour MemHouse.Model.Provider

  alias MemHouse.Model.Provider.Result

  # Fixed metadata gives each sentence a predictable governance state.
  @impl true
  def structured(_config, _messages, _schema, opts) do
    items =
      opts
      |> Keyword.fetch!(:observation)
      |> String.split(~r/(?<=[.!?])\s+|\n+/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(String.length(&1) < 8 or String.starts_with?(&1, "#")))
      |> Enum.map(fn statement ->
        %{
          "reasoning" => "The source states this directly.",
          "statement" => statement,
          "kind" => kind(statement),
          "subject_type" => "peer",
          "subject_ref" => Keyword.fetch!(opts, :source_peer_key),
          "confidence_level" => "clearly_implied",
          "sensitivity" => "internal",
          "target_level" => "peer",
          "relevant_from" => nil,
          "relevant_until" => nil
        }
      end)

    {:ok,
     %Result{
       value: %{"items" => items},
       usage: %{input_tokens: 12, output_tokens: length(items) * 6}
     }}
  end

  @impl true
  def embed(_config, texts, _opts) do
    vectors = Enum.map(texts, fn text -> [String.length(text) / 1_000, 0.5, 1.0] end)

    {:ok,
     %Result{
       value: vectors,
       usage: %{embedding_tokens: Enum.sum(Enum.map(texts, &String.length/1))}
     }}
  end

  @impl true
  def chat(_config, _messages, _opts), do: {:error, :not_used}

  @impl true
  def rerank(_config, _query, _documents, _opts), do: {:error, :not_used}

  defp kind(statement) do
    if statement =~ ~r/\b(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b/,
      do: "event",
      else: "fact"
  end
end

defmodule MemHouse.F6DocumentsConnectorsSyncTest.Connector do
  @moduledoc """
  Scriptable connector whose named Agent holds the next complete remote page.
  `put/1` replaces rather than accumulates state. It ignores the incoming cursor
  so tests verify cursor advancement from the persisted connector row.
  """

  @behaviour MemHouse.Documents.Connector

  @doc "Starts the page-holding agent, returning `:ok` whether or not it already existed."
  def start! do
    case Agent.start(fn -> %{items: [], cursor: %{"page" => 0}, has_more?: false} end,
           name: __MODULE__
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc "Stops the agent if present. Must run in `on_exit` so no script leaks between tests."
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> stop_if_alive(pid)
    end
  end

  # The agent can die between the lookup above and the stop below. An exit raised out of
  # `on_exit` abandons the rest of teardown, and these providers are installed as the global
  # `:model_provider`, so an abandoned restore leaves every later test calling a dead process.
  defp stop_if_alive(pid) do
    Agent.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Replaces the entire page the next `pull/2` will return.

  Expects a map with `:items`, `:cursor`, and `:has_more?`. Replacement rather than merge
  is deliberate: each call represents the remote's complete current state.
  """
  def put(page), do: Agent.update(__MODULE__, fn _state -> page end)

  @impl true
  def pull(_config, _cursor), do: {:ok, Agent.get(__MODULE__, & &1)}
end

defmodule MemHouse.F6DocumentsConnectorsSyncTest do
  @moduledoc """
  Pins document ingest, connector sync, immutable supersession, tombstones,
  erasure, and portability.

  The suite protects content-addressed external blobs, native parsing, dual
  chunk/knowledge ingest, hash-driven no-ops and versions, provenance-aware
  survival, post-commit cursor advancement, source-byte export with derived
  cache exclusion, exclusive-blob erasure, and secret-reference-only connector
  configuration. Documents remain raw observations; only the pipeline writes
  governed knowledge.

  `f6-document-1` is the export schema identity and requires a deliberate
  archive transition when changed. The suite runs synchronously because it
  changes node-global adapters and uses one fake connector.
  """

  use MemHouse.DataCase, async: false

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Documents
  alias MemHouse.Documents.BlobStore
  alias MemHouse.Documents.ConnectorConfig
  alias MemHouse.Documents.DocumentChunk
  alias MemHouse.Documents.Parser
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.Provenance
  alias MemHouse.Memory
  alias MemHouse.Observations.Document
  alias MemHouse.Observations.DocumentVersion
  alias MemHouse.Pipeline.Idempotency

  require Ash.Query

  setup do
    original_documents = Application.fetch_env!(:memhouse, :documents)
    original_provider = Application.get_env(:memhouse, :model_provider)
    original_roles = Application.fetch_env!(:memhouse, :model_roles)
    blob_root = Path.join(System.tmp_dir!(), "memhouse-f6-#{System.unique_integer([:positive])}")

    documents =
      original_documents
      |> Keyword.put(:blob_adapter, MemHouse.Documents.BlobStore.Local)
      # Blobs go to a unique temp directory per run and are removed in on_exit, so a leftover
      # content-addressed object cannot make a later run's "already stored" path fire.
      |> Keyword.put(:blob_root, blob_root)
      # 48-character chunks with 8 characters of overlap: small enough that a two-sentence
      # fixture produces several chunks, so chunk-count and ordering assertions are real.
      |> Keyword.put(:chunk_size, 48)
      |> Keyword.put(:chunk_overlap, 8)
      # Registers the fake remote under the adapter kind "fixture", which is the `kind` the
      # tests give when they register a connector.
      |> Keyword.put(:connector_adapters, %{
        "fixture" => MemHouse.F6DocumentsConnectorsSyncTest.Connector
      })

    # Point the embedder and extractor roles at the deterministic stand-in provider. The
    # embedding identity (provider/model/version/dimensions) is pinned here because chunks
    # record it, and later assertions check the stored dimensions match the configured 3.
    roles =
      original_roles
      |> Keyword.update!(:embedder, fn config ->
        config
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "fixture-embedding")
        |> Map.put(:model_version, "1")
        |> Map.put(:embedding_dimensions, 3)
      end)
      |> Keyword.update!(:ingest_extractor, fn config ->
        config
        |> Map.put(:provider, "fixture")
        |> Map.put(:model, "fixture-extractor")
        |> Map.put(:model_version, "1")
      end)

    Application.put_env(:memhouse, :documents, documents)

    Application.put_env(
      :memhouse,
      :model_provider,
      MemHouse.F6DocumentsConnectorsSyncTest.Provider
    )

    Application.put_env(:memhouse, :model_roles, roles)
    MemHouse.F6DocumentsConnectorsSyncTest.Connector.start!()

    # All of the above is node-global state plus a temp directory. Restoring every key and
    # removing the blob root is required for the next test to start from a clean world.
    on_exit(fn ->
      MemHouse.F6DocumentsConnectorsSyncTest.Connector.stop()
      Application.put_env(:memhouse, :documents, original_documents)
      Application.put_env(:memhouse, :model_roles, original_roles)

      if original_provider do
        Application.put_env(:memhouse, :model_provider, original_provider)
      else
        Application.delete_env(:memhouse, :model_provider)
      end

      File.rm_rf(blob_root)
    end)

    :ok
  end

  test "native parsing, RAG chunking, pinned embeddings, and governed knowledge form one dual ingest" do
    %{account: account, actor: actor, scope: scope} = context!("f6-dual")

    assert {:ok, %{status: :created, document: document, version: version}} =
             Documents.ingest_bytes(actor, %{
               scope_id: scope.id,
               external_id: "handbook",
               title: "Release handbook",
               media_type: "text/markdown",
               bytes:
                 "# Release handbook\n\nFriday is the normal release day. Escalations use email."
             })

    # Bytes live in the blob store, never inline on the row: the database holds a reference
    # keyed by account and content hash. Two accounts uploading the same file therefore get
    # separate objects, which is what makes per-account erasure able to delete one of them.
    assert version.content == nil
    assert version.blob_ref =~ "local://#{account.id}/"
    assert {:ok, _bytes} = BlobStore.get(version.blob_ref)

    # Ingest only stores and enqueues. Parsing, chunking, and embedding happen in the job
    # step run here explicitly, so an upload stays fast and survives a processing failure.
    assert {:ok, processed} =
             Documents.process_version_for_account(version.id, account.id)

    assert processed.processing_status == "complete"
    assert processed.chunk_count >= 2
    # Every chunk must be embedded. A partially embedded document would be partially
    # invisible to semantic retrieval with nothing to indicate why.
    assert processed.embedded_chunk_count == processed.chunk_count

    %{chunks: chunks, provenances: provenances, knowledge: knowledge} =
      document_derivations(account.id, actor, document.id)

    # Dimensions are recorded both on the chunk row and inside the stored vector value, and
    # must agree with the configured embedder. A disagreement means vectors from two model
    # generations are sharing an index, which corrupts nearest-neighbour results silently.
    assert Enum.all?(
             chunks,
             &(&1.embedding_dimensions == 3 and &1.embedding.dimensions == 3)
           )

    assert Enum.all?(chunks, &(&1.status == "active"))
    # Knowledge derived from a document is attributed to the document *version*, not to a
    # message. That is what lets a later revision supersede exactly the right statements,
    # and what keeps `source_message_ids` empty on this path.
    assert Enum.all?(provenances, &(&1.source_type == "document"))
    assert Enum.all?(provenances, &(&1.document_version_id == version.id))
    # Document-derived items enter the ordinary lifecycle. A connector cannot mint `active`
    # knowledge; anything outside these states means the governance step was bypassed.
    assert Enum.all?(knowledge, &(&1.state in ~w(provisional held active)))
    assert Enum.all?(knowledge, &(&1.source_message_ids == []))

    retrieval =
      MemHouse.Memory.search(
        %{"scope_path" => scope.path, "query" => "release handbook"},
        actor
      )

    # Search returns knowledge and document chunks in one candidate list, distinguished by
    # `candidate_type`, so a caller can cite the passage a statement came from.
    assert Enum.any?(
             retrieval["candidates"],
             &(&1["candidate_type"] == "document_chunk" and &1["document_id"] == document.id)
           )

    # Parser routing is asserted by the recorded parser name. Markdown must keep its
    # structure through the Markdown parser rather than being flattened by the generic
    # extractor, and binary/office/HTML formats must use the native extraction NIF instead
    # of a lossy text guess.
    assert {:ok, %{metadata: %{"parser" => "mdex"}, format: :markdown}} =
             Parser.extract("# Native markdown", "text/markdown")

    assert {:ok, %{text: extracted, metadata: %{"parser" => "extractous_ex"}}} =
             Parser.extract(
               "<html><body>Native office-style extraction</body></html>",
               "text/html"
             )

    assert extracted =~ "Native office-style extraction"
  end

  test "a document observation time does not become event valid time" do
    %{account: account, actor: actor, scope: scope} = context!("f6-event-window")

    assert {:ok, %{version: version}} =
             Documents.ingest_bytes(actor, %{
               scope_id: scope.id,
               external_id: "changelog",
               title: "Release changelog",
               media_type: "text/markdown",
               bytes: "The northbound migration ran on Tuesday before the freeze."
             })

    assert {:ok, _processed} = Documents.process_version_for_account(version.id, account.id)

    %{knowledge: knowledge} = document_derivations(account.id, actor, version.document_id)

    events = Enum.filter(knowledge, &(&1.kind == "event"))
    assert events != []
    assert Enum.all?(events, &is_nil(&1.relevant_from))
  end

  test "incremental connector sync detects hashes, supersedes prior knowledge, and tombstones deletes" do
    %{account: account, actor: actor, peer: peer, scope: scope} = context!("f6-sync")

    connector =
      Documents.register_connector(actor, %{
        scope_id: scope.id,
        name: "fixture-sync",
        kind: "fixture",
        # Polling interval in seconds; irrelevant here because syncs are invoked directly.
        schedule_seconds: 60,
        config: %{"folder" => "handbooks"},
        # A reference to a credential, not the credential. Raw secrets are rejected.
        secret_ref: "env:F6_CONNECTOR_TOKEN"
      })

    # Revision one. Three sentences become three knowledge statements under the stand-in
    # extractor: one that the next revision will drop, one it will keep, and one that will
    # also be asserted independently through a chat message below.
    put_connector_page(
      [
        connector_item(
          "policy",
          "Friday is the release day. The escalation policy is stable. Cross-source guidance remains authoritative."
        )
      ],
      1
    )

    assert {:ok, %{counts: %{created: 1}}} =
             Documents.sync_connector_for_account(connector.id, account.id)

    {document, [version_one]} = connector_document(account.id, actor, connector.id)
    assert {:ok, _processed} = Documents.process_version_for_account(version_one.id, account.id)

    # A second, independent source for the "Cross-source" sentence. This is the control for
    # the whole test: knowledge with provenance outside this document must survive both the
    # document's supersession and its later deletion.
    assert {:ok, message} =
             Memory.ingest_message(%{
               "account_key" => account.key,
               "session_id" => "f6-shared-provenance",
               "scope_path" => scope.path,
               "peer_key" => peer.key,
               "content" => "Cross-source guidance remains authoritative."
             })

    assert {:ok, [_knowledge]} =
             Memory.extract_message_for_account(message["id"], account.id)

    # Revision two of the *same* external id: Friday becomes Monday, the "stable" sentence
    # is repeated verbatim, and the "Cross-source" sentence is gone from the document.
    put_connector_page(
      [
        connector_item("policy", "Monday is the release day. The escalation policy is stable.")
      ],
      2
    )

    assert {:ok, %{counts: %{created: 1}}} =
             Documents.sync_connector_for_account(connector.id, account.id)

    {updated_document, [_processed_version_one, version_two]} =
      connector_document(account.id, actor, connector.id)

    # One logical document, two immutable versions. Revision one is still readable; a sync
    # appends history rather than mutating the row in place.
    assert updated_document.id == document.id
    assert version_two.version == 2
    assert {:ok, _processed} = Documents.process_version_for_account(version_two.id, account.id)

    knowledge = document_derivations(account.id, actor, document.id).knowledge
    friday = Enum.find(knowledge, &String.contains?(&1.statement, "Friday"))
    monday = Enum.find(knowledge, &String.contains?(&1.statement, "Monday"))
    stable = Enum.find(knowledge, &String.contains?(&1.statement, "stable"))
    shared = Enum.find(knowledge, &String.contains?(&1.statement, "Cross-source"))

    # The four outcomes that define supersession:
    # dropped by the new revision -> superseded (statement and history retained, not deleted);
    # newly asserted -> enters the ordinary lifecycle;
    # repeated verbatim -> untouched, with the new version merged into its provenance;
    # sourced elsewhere too -> untouched, because this document never owned it exclusively.
    assert friday.state == "superseded"
    assert monday.state in ~w(provisional held active)
    refute stable.state == "superseded"
    refute shared.state == "superseded"

    # Two document provenances for the repeated sentence (one per version) proves the merge
    # happened instead of a duplicate knowledge item being created. The cross-source item has
    # exactly one document provenance; its other provenance is the chat message.
    assert provenance_count(account.id, actor, stable.id) == 2
    assert provenance_count(account.id, actor, shared.id) == 1

    # Re-syncing the identical page must be a no-op, matched on content hash. Without this,
    # every poll would append a version and re-run extraction, growing history without bound.
    assert {:ok, %{counts: %{unchanged: 1}}} =
             Documents.sync_connector_for_account(connector.id, account.id)

    {_document, versions_after_noop} = connector_document(account.id, actor, connector.id)
    assert length(versions_after_noop) == 2

    # Remote deletion. It tombstones; it does not delete rows or history.
    put_connector_page([%{external_id: "policy", deleted?: true}], 3)

    assert {:ok, %{counts: %{tombstoned: 1}}} =
             Documents.sync_connector_for_account(connector.id, account.id)

    {tombstoned, _versions} = connector_document(account.id, actor, connector.id)
    assert tombstoned.status == "tombstoned"
    assert %DateTime{} = tombstoned.tombstoned_at

    synced =
      ConnectorConfig
      |> Ash.Query.filter(id == ^connector.id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)

    # The persisted cursor reflects the last durably handled page, and only that page. An
    # engine that saved the cursor before committing the page would skip documents after a
    # crash, and they would never be re-offered by the remote.
    assert synced.cursor == %{"page" => 3}
    assert %DateTime{} = synced.last_synced_at

    # Chunks are a derived cache of a document that no longer exists remotely, so they stop
    # being retrievable. They are marked, not dropped, so the state is auditable.
    assert Enum.all?(document_derivations(account.id, actor, document.id).chunks, fn chunk ->
             chunk.status == "tombstoned"
           end)

    # The whole point of the control statement: a deleted document must not retract a fact
    # that a peer independently stated. Only knowledge exclusively sourced from the document
    # is retracted.
    shared_after_tombstone =
      document_derivations(account.id, actor, document.id).knowledge
      |> Enum.find(&String.contains?(&1.statement, "Cross-source"))

    refute shared_after_tombstone.state in ~w(retracted superseded)
  end

  test "document export carries verified blobs, excludes chunks, and import rebuilds after erasure" do
    %{account: account, actor: actor, scope: scope} = context!("f6-portability")

    assert {:ok, %{document: document, version: version}} =
             Documents.ingest_bytes(actor, %{
               scope_id: scope.id,
               external_id: "portable",
               title: "Portable document",
               media_type: "text/plain",
               bytes: "Portable source bytes produce governed document knowledge."
             })

    assert {:ok, _processed} = Documents.process_version_for_account(version.id, account.id)
    assert document_derivations(account.id, actor, document.id).chunks != []

    # `f6-document-1` is the document bundle's schema identity value. A reader checks it
    # before trusting the layout, so changing it is a deliberate archive-format transition.
    assert {:ok, bundle} = Documents.export_document(actor, document.id)
    assert bundle["manifest"]["schema"] == "f6-document-1"
    # Chunks and vectors are excluded by design and the manifest says so out loud. Shipping
    # them would freeze the archive to the exporting account's embedding model.
    assert bundle["manifest"]["derived_chunks"] == "excluded_rebuild_on_import"
    # The original source bytes travel with the bundle, so an import can re-derive anything.
    assert [%{"bytes" => bytes}] = bundle["blobs"]
    assert bytes == "Portable source bytes produce governed document knowledge."

    # Erasure removes the blob this document exclusively owned, along with the document row.
    # A blob shared with another version would be kept; here nothing else references it.
    blob_ref = version.blob_ref
    assert :ok = Documents.erase_document(actor, document.id)
    assert {:error, :enoent} = BlobStore.get(blob_ref)
    assert nil == read_document(account.id, actor, document.id)

    assert {:ok, [_imported]} = Documents.import_document(actor, bundle)

    imported =
      Document
      |> Ash.Query.filter(external_id == "portable")
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)

    imported_versions = versions(account.id, actor, imported.id)
    assert length(imported_versions) == 1
    # Import restores durable state only. Derived chunks arrive empty and are rebuilt by
    # re-running ordinary processing, under the *target* account's embedder identity.
    assert document_derivations(account.id, actor, imported.id).chunks == []

    assert {:ok, _processed} =
             Documents.process_version_for_account(hd(imported_versions).id, account.id)

    assert document_derivations(account.id, actor, imported.id).chunks != []
  end

  test "connector configs reject raw secrets and retain only references" do
    %{account: account, actor: actor, scope: scope} = context!("f6-secrets")

    # A credential-looking key anywhere in the content-safe config map is rejected. Connector
    # config is exported, logged, and shown in operator UIs, so it must never hold a secret.
    assert_raise Ash.Error.Invalid, fn ->
      Documents.register_connector(actor, %{
        scope_id: scope.id,
        name: "unsafe",
        kind: "fixture",
        config: %{"client_secret" => "raw-secret"}
      })
    end

    # The secret-reference field must contain a reference (such as an environment-variable
    # name), not the value itself. A bare string that is not a reference is rejected.
    assert_raise Ash.Error.Invalid, fn ->
      Documents.register_connector(actor, %{
        scope_id: scope.id,
        name: "unsafe-reference",
        kind: "fixture",
        secret_ref: "raw-secret"
      })
    end

    # Neither rejected attempt may leave a partial row behind.
    assert [] =
             ConnectorConfig
             |> Ash.Query.set_tenant(account.id)
             |> Ash.read!(actor: actor)
  end

  # Bootstraps one isolated world per test: account, scope, peer, and a system/pipeline actor
  # with access to every scope. Each test uses its own account key so no assertion can be
  # satisfied by another test's rows, and so account isolation failures show up as empty
  # results rather than as cross-talk.
  defp context!(account_key) do
    assert {:ok, _message} =
             Memory.ingest_message(%{
               "account_key" => account_key,
               "session_id" => "#{account_key}-setup",
               "scope_path" => "/f6/#{account_key}",
               "peer_key" => "#{account_key}-owner",
               "content" => "F6 setup observation is durable."
             })

    DataLayer.with_account_key(account_key, fn account, system_actor ->
      peer_key = "#{account_key}-owner"
      scope_path = "/f6/#{account_key}"

      peer =
        MemHouse.Accounts.Peer
        |> Ash.Query.filter(key == ^peer_key)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: system_actor)

      scope =
        MemHouse.Topology.Scope
        |> Ash.Query.filter(path == ^scope_path)
        |> Ash.Query.set_tenant(account.id)
        |> Ash.read_one!(actor: system_actor)

      actor =
        Actor.for_account(account,
          peer_id: peer.id,
          role: :system,
          pipeline?: true,
          scope_ids: :all
        )

      %{account: account, actor: actor, peer: peer, scope: scope}
    end)
  end

  # Walks a document to everything derived from it: chunks directly, then knowledge reached
  # through the provenance rows of all its versions. Going via provenance (rather than a
  # text match) is what makes the supersession assertions meaningful — it returns exactly
  # the items this document is a source for, including ones with other sources too.
  defp document_derivations(account_id, actor, document_id) do
    chunks =
      DocumentChunk
      |> Ash.Query.filter(document_id == ^document_id)
      |> Ash.Query.sort(position: :asc)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    version_ids = versions(account_id, actor, document_id) |> Enum.map(& &1.id)

    provenances =
      Provenance
      |> Ash.Query.filter(document_version_id in ^version_ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    knowledge_ids = provenances |> Enum.map(& &1.knowledge_item_id) |> Enum.uniq()

    knowledge =
      KnowledgeItem
      |> Ash.Query.filter(id in ^knowledge_ids)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    %{chunks: chunks, provenances: provenances, knowledge: knowledge}
  end

  defp connector_document(account_id, actor, connector_id) do
    document =
      Document
      |> Ash.Query.filter(connector_config_id == ^connector_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    {document, versions(account_id, actor, document.id)}
  end

  defp versions(account_id, actor, document_id) do
    DocumentVersion
    |> Ash.Query.filter(document_id == ^document_id)
    |> Ash.Query.sort(version: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
  end

  # Counts only document-sourced provenance for one item, deliberately excluding message
  # provenance, so a test can distinguish "merged across two document versions" from
  # "corroborated by a chat message".
  defp provenance_count(account_id, actor, knowledge_id) do
    Provenance
    |> Ash.Query.filter(knowledge_item_id == ^knowledge_id and source_type == "document")
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> length()
  end

  # Stages the remote's next page. `has_more?` is false so one sync call drains it, keeping
  # the cursor assertions about durability rather than about pagination.
  defp put_connector_page(items, page) do
    MemHouse.F6DocumentsConnectorsSyncTest.Connector.put(%{
      items: items,
      cursor: %{"page" => page},
      has_more?: false
    })
  end

  # One raw remote item. The stable `external_id` is what makes successive pages revisions of
  # the same logical document. The metadata revision marker mirrors what a real remote system
  # would expose; change detection still relies on the engine's own hash of the bytes, never
  # on a remote-supplied marker.
  defp connector_item(external_id, bytes) do
    %{
      external_id: external_id,
      title: "Policy",
      media_type: "text/plain",
      bytes: bytes,
      source_uri: "fixture://policy",
      metadata: %{"revision" => Idempotency.content_hash(bytes)}
    }
  end

  defp read_document(account_id, actor, document_id) do
    Document
    |> Ash.Query.filter(id == ^document_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end
end
