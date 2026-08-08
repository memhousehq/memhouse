# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Portability.Archive do
  @moduledoc """
  Reads and writes the versioned logical Account archive.

  Exports keyset-stream durable resources in dependency order and checksum every included blob.
  Imports validate schema, checksums, references, exclusions, and the full audit graph before any
  durable write. Archive data is untrusted input and the target must be empty.
  """

  alias MemHouse.Actor
  alias MemHouse.DataLayer
  alias MemHouse.Documents.BlobStore
  alias MemHouse.Governance.AuditEvent
  alias MemHouse.Observations.DocumentVersion
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline.Idempotency
  alias MemHouse.Portability.AuditVerifier
  alias MemHouse.Portability.Registry

  require Ash.Query

  # Versions the archive format itself: the manifest keys, the resource file
  # layout, and the blob naming. An import refuses any other value outright,
  # because guessing at an unknown layout is how a partially restored Account
  # happens. Changing this string is a deliberate contract transition — it
  # obliges a maintainer to record the change in the changelog, state the
  # migration path for archives already written, and refresh the contract
  # evidence.
  @schema "memhouse-account-1"

  @doc """
  Writes a complete archive of the actor's Account to `output_path`.

  The Account comes from the actor. One scoped transaction produces a consistent snapshot,
  and an atomic sibling-file rename prevents partial output.

  Returns `{:ok, summary}` with schema, Account, row and blob counts, audit head, path, and
  duration in milliseconds. Blob checksum, supersession graph, or filesystem failures raise.
  """
  # The only caller-controlled path is an operator CLI destination; archive
  # contents are written under a generated temporary root.
  # sobelow_skip ["Traversal.FileModule"]
  def export(%Actor{} = actor, output_path) when is_binary(output_path) do
    started_at = System.monotonic_time()
    root = temp_dir!("memhouse-export")

    try do
      {manifest, manifest_bytes} =
        DataLayer.with_actor(actor, fn account, current_actor ->
          write_export!(root, account, current_actor)
        end)

      # The manifest is written last, after every file it checksums exists, so a
      # manifest can never describe content that was not produced.
      File.write!(Path.join(root, "manifest.json"), manifest_bytes, [:binary])
      create_tar!(root, output_path)

      duration_ms = duration_ms(started_at)

      :telemetry.execute(
        [:memhouse, :portability, :export],
        %{duration: duration_ms, resources: length(manifest["resources"])},
        %{status: :ok}
      )

      {:ok,
       %{
         path: Path.expand(output_path),
         schema: @schema,
         account_id: manifest["account"]["id"],
         resource_counts: Map.new(manifest["resources"], &{&1["name"], &1["count"]}),
         blob_count: length(manifest["blobs"]),
         audit: manifest["audit"],
         duration_ms: duration_ms
       }}
    after
      File.rm_rf!(root)
    end
  end

  @doc """
  Restores an archive into a fresh Account.

  Account identity comes from the archive. Unsafe paths, schema, counts, checksums, blobs,
  references, and audit chain are verified before durable writes. The fresh-target check,
  dependency-ordered restore, and rebuild enqueue share one Account transaction.

  Returns `{:ok, summary}` with counts, schema, Account, replay hash, audit head, and
  duration in milliseconds. Existing targets, verification, blob, or transaction failures
  raise.
  """
  def import(input_path) when is_binary(input_path) do
    started_at = System.monotonic_time()
    root = temp_dir!("memhouse-import")

    try do
      extract_tar!(input_path, root)
      {manifest, rows, blob_bytes, manifest_hash} = validate_archive!(root)
      account = Map.fetch!(manifest, "account")
      account_id = Map.fetch!(account, "id")
      account_key = Map.fetch!(account, "key")
      # Blobs are content-addressed, so storing them before the transaction is
      # idempotent and leaves nothing referenceable if the import later fails.
      target_blob_refs = store_blobs!(account_id, blob_bytes)

      # One transaction for every durable effect: the freshness check, all rows,
      # and the rebuild jobs. A failure anywhere leaves no Account behind and no
      # jobs pointing at rows that do not exist.
      result =
        DataLayer.with_portability_import(account_id, account_key, fn actor ->
          ensure_fresh_target!(actor)
          imported = import_rows!(rows, target_blob_refs, actor)
          enqueue_rebuilds!(rows, manifest_hash, actor)
          imported
        end)

      duration_ms = duration_ms(started_at)

      :telemetry.execute(
        [:memhouse, :portability, :import],
        %{duration: duration_ms, resources: map_size(rows)},
        %{status: :ok}
      )

      {:ok,
       Map.merge(result, %{
         schema: @schema,
         account_id: account_id,
         manifest_hash: manifest_hash,
         audit: manifest["audit"],
         duration_ms: duration_ms
       })}
    after
      File.rm_rf!(root)
    end
  end

  @doc """
  Verifies an archive and reports what it contains, without writing anything.

  Runs exactly the checks an import runs before its transaction, so a successful
  validation means the file itself is sound — it says nothing about whether the
  target is fresh, which is only checked during an import.

  Returns `{:ok, %{schema: ..., account_id: ..., manifest_hash: ..., audit: ...}}`.
  Raises with the specific failure — unsupported schema, unknown resource,
  checksum or count mismatch, blob mismatch, or a broken audit chain — and
  always removes its temporary directory.
  """
  def validate(input_path) when is_binary(input_path) do
    root = temp_dir!("memhouse-validate")

    try do
      extract_tar!(input_path, root)
      {manifest, _rows, _blobs, manifest_hash} = validate_archive!(root)

      {:ok,
       %{
         schema: manifest["schema"],
         account_id: manifest["account"]["id"],
         manifest_hash: manifest_hash,
         audit: manifest["audit"]
       }}
    after
      File.rm_rf!(root)
    end
  end

  # Writes every resource file and blob, then builds the manifest that describes
  # and checksums them. Runs inside the export transaction, so all resource
  # files are read from one consistent snapshot.
  #
  # The exported audit events are verified here, at export time, and the
  # resulting head and count go into the manifest. That is what lets an import
  # detect an archive whose events were edited *and* whose manifest was edited
  # to agree with them: the recomputed chain must match both.
  #
  # `root` is generated by `temp_dir!/1`; resource names come from Registry.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_export!(root, account, actor) do
    resources_dir = Path.join(root, "resources")
    blobs_dir = Path.join(root, "blobs")
    File.mkdir_p!(resources_dir)
    File.mkdir_p!(blobs_dir)

    {resource_entries, exported_rows} =
      Enum.map_reduce(Registry.resources(), %{}, fn {name, resource}, rows_by_name ->
        rows = read_rows(resource, account.id, actor)
        path = Path.join(resources_dir, "#{name}.jsonl")
        bytes = encode_jsonl(rows)
        File.write!(path, bytes, [:binary])

        entry = %{
          "name" => name,
          "file" => "resources/#{name}.jsonl",
          "count" => length(rows),
          "sha256" => sha256(bytes)
        }

        {entry, Map.put(rows_by_name, name, rows)}
      end)

    blobs =
      exported_rows
      |> Map.fetch!("document_versions")
      |> write_blobs!(blobs_dir)

    {:ok, audit} =
      exported_rows
      |> Map.fetch!("audit_events")
      |> AuditVerifier.verify()

    # The source deployment's configured embedder is recorded even though no
    # vectors are exported, so an operator can compare it against the target's
    # and tell whether the recomputed vectors will be comparable. It is resolved
    # with an empty context, so it is the deployment default rather than any
    # Account-level override.
    embedder =
      :embedder |> MemHouse.Model.Config.resolve(%{}) |> MemHouse.Model.Config.provenance()

    manifest = %{
      "schema" => @schema,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "account" => %{"id" => account.id, "key" => account.key, "name" => account.name},
      "embedder" => stringify_map(embedder),
      "resources" => resource_entries,
      "blobs" => blobs,
      "audit" => stringify_map(audit),
      # Exclusions are stated in the file rather than left implicit, so anyone
      # inspecting an archive can tell that credentials, secrets, vectors, and
      # derived caches are missing by design and not through data loss.
      "excluded" => %{
        "derived_resources" => Enum.map(Registry.derived_resources(), &resource_name/1),
        "credential_resources" => Enum.map(Registry.credential_resources(), &resource_name/1),
        "vectors" => "rebuild_on_import",
        "secrets" => "never_exported"
      }
    }

    manifest_bytes = Jason.encode!(manifest, pretty: true)
    {manifest, manifest_bytes}
  end

  # Reads one resource's rows for the Account, strips excluded attributes, and
  # puts them in restorable order.
  #
  # Keyset pagination bounds each round trip instead of issuing one unbounded
  # query; the rows are then collected so they can be ordered and checksummed as
  # a unit. Reads go through the private export action, which admits only an
  # internal actor — the `:system` role or the pipeline flag.
  defp read_rows(resource, account_id, actor) do
    # The Account row identifies the tenant, so it is matched on its own id;
    # every other resource carries the tenant as a column.
    query =
      if resource == MemHouse.Accounts.Account do
        Ash.Query.filter(resource, id == ^account_id)
      else
        Ash.Query.filter(resource, account_id == ^account_id)
      end

    query =
      query
      |> Ash.Query.for_read(:portability_export)
      |> Ash.Query.sort(id: :asc)
      |> maybe_set_tenant(resource, account_id)

    # 500 rows per round trip: large enough that a big Account does not become
    # thousands of queries, small enough to bound peak memory per batch.
    query
    |> Ash.stream!(actor: actor, batch_size: 500, stream_with: :keyset)
    |> Enum.to_list()
    |> Enum.map(&serialize_record(resource, &1))
    |> sort_for_import(resource)
  end

  # The Account resource is the tenant itself and has no tenant column to set.
  defp maybe_set_tenant(query, MemHouse.Accounts.Account, _account_id), do: query
  defp maybe_set_tenant(query, _resource, account_id), do: Ash.Query.set_tenant(query, account_id)

  # Serialises a row attribute by attribute, dropping the ones the registry
  # marks as secret or derived. Working from the resource's declared attributes
  # rather than the struct means calculations, aggregates, and loaded
  # relationships can never leak into an archive by accident.
  defp serialize_record(resource, record) do
    excluded = Registry.excluded_attributes(resource)

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(&(&1.name in excluded))
    |> Map.new(fn attribute ->
      {Atom.to_string(attribute.name), Map.get(record, attribute.name)}
    end)
  end

  # Orders one resource's rows so an import can replay them without ever
  # referencing a row it has not written yet. Only resources with intra-resource
  # references need special handling; everything else keeps its id order, which
  # is already stable.

  # Scopes form a containment tree, and a child cannot be created before its
  # parent. Sorting by path puts ancestors first, because a parent's path is a
  # prefix of its children's.
  defp sort_for_import(rows, MemHouse.Topology.Scope),
    do: Enum.sort_by(rows, &{Map.fetch!(&1, "path"), Map.fetch!(&1, "id")})

  # Knowledge items point at the item they superseded, so a superseding item
  # must be written after its predecessor. Insertion order is not enough,
  # because a supersession chain can be built in any order over time.
  defp sort_for_import(rows, MemHouse.Knowledge.KnowledgeItem),
    do: sort_supersession_rows(rows, MapSet.new(), [])

  # Audit events must be restored in the order they were appended, since each
  # one's hash commits to its predecessor's.
  defp sort_for_import(rows, AuditEvent),
    do: Enum.sort_by(rows, &{Map.fetch!(&1, "inserted_at"), Map.fetch!(&1, "id")})

  defp sort_for_import(rows, _resource), do: rows

  # Topological sort of the supersession graph, in waves: repeatedly take every
  # item whose predecessor is already placed, then repeat with what is left.
  # Each wave is ordered by insertion time so the output is deterministic — the
  # same Account must always produce a byte-identical archive, or checksums stop
  # being comparable between exports.
  #
  # A wave that can place nothing means the remaining items form a cycle or
  # reference a predecessor that is not in the archive. Both indicate corrupted
  # data, so this raises rather than emitting an archive that cannot be
  # imported.
  defp sort_supersession_rows([], _seen, result), do: Enum.reverse(result)

  defp sort_supersession_rows(rows, seen, result) do
    {ready, pending} =
      Enum.split_with(rows, fn row ->
        supersedes_id = row["supersedes_id"]
        is_nil(supersedes_id) or MapSet.member?(seen, supersedes_id)
      end)

    if ready == [] do
      raise "knowledge supersession graph is cyclic or references a missing item"
    end

    ready = Enum.sort_by(ready, &{Map.fetch!(&1, "inserted_at"), Map.fetch!(&1, "id")})
    seen = Enum.reduce(ready, seen, &MapSet.put(&2, Map.fetch!(&1, "id")))
    sort_supersession_rows(pending, seen, Enum.reverse(ready, result))
  end

  # Writes one file per distinct document blob, named by its content hash.
  #
  # Deduplicated by hash: two versions with identical bytes share one file, so
  # an Account that re-uploaded the same document many times does not multiply
  # the archive size.
  #
  # Every blob is re-hashed after reading and the export is aborted on a
  # mismatch. That is a deliberate integrity check against silent corruption in
  # the blob store, not a formality — an archive is often the last copy, and
  # restoring corrupted bytes under a hash that claims otherwise would be worse
  # than failing here.
  #
  # Blob filenames are verified lowercase SHA-256 content hashes.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_blobs!(version_rows, blobs_dir) do
    version_rows
    |> Enum.uniq_by(&Map.fetch!(&1, "content_hash"))
    |> Enum.map(fn row ->
      hash = Map.fetch!(row, "content_hash")

      # Documents ingested before blobs moved out of the database keep their
      # bytes on the version row itself; that case reads them from the row so an
      # archive never exposes which storage era a document came from.
      bytes =
        case BlobStore.get(Map.fetch!(row, "blob_ref")) do
          {:ok, bytes} -> bytes
          {:error, :legacy_blob_requires_version_content} -> Map.fetch!(row, "content")
          {:error, reason} -> raise "cannot export blob #{hash}: #{inspect(reason)}"
        end

      if Idempotency.content_hash(bytes) != hash do
        raise "document blob checksum mismatch for #{hash}"
      end

      File.write!(Path.join(blobs_dir, hash), bytes, [:binary])

      %{
        "content_hash" => hash,
        "file" => "blobs/#{hash}",
        "byte_size" => byte_size(bytes),
        "sha256" => sha256(bytes)
      }
    end)
    # Sorted by hash so the manifest's blob list is deterministic rather than
    # dependent on row order.
    |> Enum.sort_by(& &1["content_hash"])
  end

  # The complete pre-write verification. Every check here runs before an import
  # touches the database, and each exists because of a specific way an archive
  # can be wrong:
  #
  #   * an unknown schema means the layout is not the one this code understands;
  #   * an unknown resource name means the file claims to restore something that
  #     is not portable;
  #   * a file checksum mismatch means the bytes changed after export;
  #   * a row-count mismatch catches truncation that still leaves valid JSON;
  #   * the audit chain must both verify on its own terms *and* agree with the
  #     manifest's head and count, which is what defeats an edit to the events
  #     and the manifest together;
  #   * every blob must match its recorded size and content hash.
  #
  # Returns the manifest, the decoded rows by resource name, the blob bytes by
  # hash, and the hash of the manifest itself, which becomes the replay key for
  # the rebuild work the import queues.
  #
  # `root` is generated locally and archive entries pass `safe_join!/2`.
  # sobelow_skip ["Traversal.FileModule"]
  defp validate_archive!(root) do
    manifest_path = safe_join!(root, "manifest.json")
    manifest_bytes = File.read!(manifest_path)
    manifest = Jason.decode!(manifest_bytes)

    unless manifest["schema"] == @schema do
      raise "unsupported portability schema: #{inspect(manifest["schema"])}"
    end

    rows =
      Map.new(manifest["resources"], fn entry ->
        name = Map.fetch!(entry, "name")
        # Raises on a name that is not portable, so an archive cannot smuggle in
        # rows for a credential or derived-cache resource.
        Registry.resource!(name)
        bytes = read_verified!(root, entry)
        decoded = decode_jsonl(bytes)

        if length(decoded) != Map.fetch!(entry, "count") do
          raise "resource count mismatch for #{name}"
        end

        {name, decoded}
      end)

    audit_rows = Map.fetch!(rows, "audit_events")

    case AuditVerifier.verify(audit_rows) do
      {:ok, actual} ->
        expected = manifest["audit"]

        unless actual.count == expected["count"] and actual.last_hash == expected["last_hash"] do
          raise "audit manifest does not match the verified chain"
        end

      {:error, reason} ->
        raise "audit chain verification failed: #{inspect(reason)}"
    end

    blobs =
      Map.new(manifest["blobs"], fn entry ->
        bytes = read_verified!(root, entry)
        hash = Map.fetch!(entry, "content_hash")

        unless byte_size(bytes) == Map.fetch!(entry, "byte_size") and
                 Idempotency.content_hash(bytes) == hash do
          raise "blob content verification failed for #{hash}"
        end

        {hash, bytes}
      end)

    {manifest, rows, blobs, sha256(manifest_bytes)}
  end

  # Reads one manifest-listed file and checks it against its recorded checksum
  # before returning a single byte of it to a caller. The path is re-validated
  # against the extraction root even though extraction already rejected unsafe
  # entries, because the file name here comes from the manifest, which is a
  # separate piece of untrusted input.
  #
  # `safe_join!/2` proves the manifest path stays inside the extraction root.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_verified!(root, entry) do
    file = Map.fetch!(entry, "file")
    bytes = root |> safe_join!(file) |> File.read!()

    unless sha256(bytes) == Map.fetch!(entry, "sha256") do
      raise "archive checksum mismatch for #{file}"
    end

    bytes
  end

  # Writes the verified blobs into the target's own blob storage and returns the
  # new reference for each hash. References are storage-specific — a local path,
  # an object key — so the source's references are meaningless here and must be
  # replaced rather than carried over.
  defp store_blobs!(account_id, blob_bytes) do
    Map.new(blob_bytes, fn {hash, bytes} ->
      case BlobStore.put(account_id, hash, bytes) do
        {:ok, blob_ref} -> {hash, blob_ref}
        {:error, reason} -> raise "cannot import blob #{hash}: #{inspect(reason)}"
      end
    end)
  end

  # An import restores an Account under its original id, so a target that
  # already holds that Account would be merged into rather than restored. There
  # is no safe way to reconcile two histories of the same Account, so this
  # refuses instead of guessing. Checked inside the import transaction, so the
  # answer cannot change between the check and the writes.
  defp ensure_fresh_target!(actor) do
    existing =
      MemHouse.Accounts.Account
      |> Ash.Query.filter(id == ^actor.account_id)
      |> Ash.read_one!(actor: actor)

    if existing, do: raise("portability import requires a fresh target Account")
  end

  # Restores every resource, walking the registry in its declared dependency
  # order — never the order the manifest happens to list, which an edited
  # archive controls. Self-references that cannot be satisfied on the first pass
  # are filled in afterwards, once their targets exist.
  defp import_rows!(rows, target_blob_refs, actor) do
    counts =
      Enum.map(Registry.resources(), fn {name, resource} ->
        imported =
          rows
          |> Map.fetch!(name)
          |> Enum.map(&rewrite_blob_ref(resource, &1, target_blob_refs))
          |> Enum.map(&import_record!(resource, &1, actor))

        {name, length(imported)}
      end)

    restore_deferred_links!(rows, actor)
    %{resource_counts: Map.new(counts), blob_count: map_size(target_blob_refs)}
  end

  # Points each restored document version at the blob as stored on *this*
  # installation. The lookup is by content hash and uses `fetch!`, so a version
  # whose blob is missing from the archive aborts the import instead of
  # restoring a document that references bytes nobody has.
  defp rewrite_blob_ref(DocumentVersion, row, target_blob_refs) do
    Map.put(row, "blob_ref", Map.fetch!(target_blob_refs, Map.fetch!(row, "content_hash")))
  end

  defp rewrite_blob_ref(_resource, row, _target_blob_refs), do: row

  # Writes one archived row through the private restore action, which forces the
  # archived attribute values on verbatim so ids, timestamps, lifecycle state,
  # and audit hashes survive unchanged. Ordinary create actions would derive new
  # values and destroy exactly the history the archive exists to preserve.
  defp import_record!(resource, attributes, actor) do
    attributes = drop_deferred_attributes(resource, attributes)

    changeset =
      resource
      |> Ash.Changeset.new()
      |> maybe_set_changeset_tenant(resource, actor.account_id)
      |> Ash.Changeset.for_create(:portability_import, %{attributes: attributes})

    Ash.create!(changeset, actor: actor)
  end

  # A document points at its current version, but versions are restored after
  # documents, so that pointer cannot be written yet. It is dropped here and
  # restored in the second pass below.
  defp drop_deferred_attributes(MemHouse.Observations.Document, attributes),
    do: Map.drop(attributes, ["current_version_id"])

  defp drop_deferred_attributes(_resource, attributes), do: attributes

  # Second pass for the pointers the first pass had to omit. Runs inside the
  # same import transaction, so a document is never left permanently without its
  # current version: either both the rows and their links commit, or neither
  # does.
  defp restore_deferred_links!(rows, actor) do
    Enum.each(Map.fetch!(rows, "documents"), fn row ->
      if current_version_id = row["current_version_id"] do
        document =
          MemHouse.Observations.Document
          |> Ash.Query.filter(id == ^Map.fetch!(row, "id"))
          |> Ash.Query.set_tenant(actor.account_id)
          |> Ash.read_one!(actor: actor)

        document
        |> Ash.Changeset.for_update(:portability_restore, %{
          attributes: %{"current_version_id" => current_version_id}
        })
        |> Ash.update!(actor: actor)
      end
    end)
  end

  # The Account row is the tenant and has no tenant column; every other resource
  # gets the tenant set explicitly, so a restored row can never land under a
  # different Account than the one being imported.
  defp maybe_set_changeset_tenant(changeset, MemHouse.Accounts.Account, _account_id),
    do: changeset

  defp maybe_set_changeset_tenant(changeset, _resource, account_id),
    do: Ash.Changeset.set_tenant(changeset, account_id)

  # Queues the work that recreates everything the archive deliberately left out:
  # per scope, the vector index, entity caches, and projections; per document
  # version, the full parse/chunk/embed/extract derivation. Until these run, an
  # imported Account is complete but not yet searchable.
  #
  # Enqueued inside the import transaction, so the jobs and the rows they
  # process commit together — no job can run against an import that rolled back.
  defp enqueue_rebuilds!(rows, manifest_hash, actor) do
    scope_ids = Enum.map(Map.fetch!(rows, "scopes"), &Map.fetch!(&1, "id"))
    version_ids = Enum.map(Map.fetch!(rows, "document_versions"), &Map.fetch!(&1, "id"))

    Enum.each(scope_ids, fn scope_id ->
      enqueue_rebuild!(actor, "scope", scope_id, manifest_hash)
    end)

    Enum.each(version_ids, fn version_id ->
      enqueue_rebuild!(actor, "document_version", version_id, manifest_hash)
    end)
  end

  # The replay key combines what is being rebuilt with the hash of the manifest
  # that asked for it, so retrying the same import reuses its runs while a
  # different archive is distinct work. The payload carries the manifest hash
  # only — no rows, paths, or content.
  defp enqueue_rebuild!(actor, target_type, target_id, manifest_hash) do
    import_id = "#{target_type}:#{target_id}"

    PipelineRun
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(actor.account_id)
    |> Ash.Changeset.for_create(:enqueue_import_rebuild, %{
      target_type: target_type,
      target_id: target_id,
      idempotency_key: Idempotency.import_rebuild(import_id, manifest_hash),
      payload: %{"manifest_hash" => manifest_hash}
    })
    |> Ash.create!(actor: actor)
  end

  # One JSON object per line, so a resource file can be streamed instead of held
  # in memory as a single document, and so a truncated file is detectable rather
  # than merely unparseable. An empty resource is an empty file, not "[]", which
  # keeps its checksum meaningful.
  defp encode_jsonl([]), do: ""

  defp encode_jsonl(rows) do
    Enum.map_join(rows, "", fn row -> Jason.encode!(row) <> "\n" end)
  end

  defp decode_jsonl(""), do: []

  defp decode_jsonl(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  # Packs the staged directory into a compressed tar.
  #
  # Written to a uniquely named temporary file beside the destination and only
  # renamed into place once every entry has been added. A rename within one
  # filesystem is atomic, so an interrupted or failed export never leaves a
  # truncated file at the operator's chosen path that looks like a usable
  # archive.
  #
  # Output is an operator CLI path; inputs remain inside the generated root.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_tar!(root, output_path) do
    output = Path.expand(output_path)
    File.mkdir_p!(Path.dirname(output))
    temp_output = output <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, tar} = :erl_tar.open(String.to_charlist(temp_output), [:write, :compressed])

    result =
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.reduce_while(:ok, fn path, :ok ->
        relative = Path.relative_to(path, root)

        case :erl_tar.add(tar, String.to_charlist(path), String.to_charlist(relative), []) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    :ok = :erl_tar.close(tar)

    case result do
      :ok -> File.rename!(temp_output, output)
      {:error, reason} -> raise "cannot create portability archive: #{inspect(reason)}"
    end
  end

  # Extracts an untrusted archive into the generated temporary root.
  #
  # The entry table is inspected and rejected *before* anything is written: an
  # absolute path or a parent-directory segment in a tar entry is the classic
  # way an archive writes outside the directory it was extracted into. Checking
  # first means a hostile archive never gets a single file onto disk.
  defp extract_tar!(input_path, root) do
    archive = String.to_charlist(Path.expand(input_path))

    entries =
      case :erl_tar.table(archive, [:compressed]) do
        {:ok, names} -> names
        {:error, reason} -> raise "cannot inspect portability archive: #{inspect(reason)}"
      end

    Enum.each(entries, fn name ->
      name = List.to_string(name)

      if Path.type(name) == :absolute or ".." in Path.split(name) do
        raise "unsafe path in portability archive"
      end
    end)

    case :erl_tar.extract(archive, [:compressed, cwd: String.to_charlist(root)]) do
      :ok -> :ok
      {:error, reason} -> raise "cannot extract portability archive: #{inspect(reason)}"
    end
  end

  # Resolves a manifest-supplied relative path and proves the result is still
  # inside the extraction root. The comparison is made after expansion, so
  # traversal segments and symlink-shaped names are already resolved; the
  # trailing separator in the prefix test stops a sibling directory whose name
  # merely starts with the root's name from passing.
  defp safe_join!(root, relative) do
    expanded_root = Path.expand(root)
    expanded = Path.expand(relative, expanded_root)

    unless expanded == expanded_root or String.starts_with?(expanded, expanded_root <> "/") do
      raise "archive path escapes extraction root"
    end

    expanded
  end

  # A fresh working directory per operation, named with a strictly increasing
  # unique integer so two concurrent exports or imports cannot collide. Every
  # caller removes it in an `after` block, including on failure, so extracted
  # Account content never lingers in the system temporary directory.
  #
  # Prefixes are module constants and the parent comes from the system runtime.
  # sobelow_skip ["Traversal.FileModule"]
  defp temp_dir!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  # Renders a module as a readable name for the manifest's exclusion list; the
  # value is informational and is never resolved back to a module on import.
  defp resource_name(resource), do: resource |> Module.split() |> Enum.join(".")

  defp stringify_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp sha256(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp duration_ms(started_at),
    do: System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)
end
