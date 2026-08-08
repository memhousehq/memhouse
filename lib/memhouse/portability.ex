# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Portability do
  @moduledoc """
  Exports and imports one logical Account archive.

  Export includes durable rows and checksum-verified original blobs but excludes credentials,
  secrets, vectors, chunks, projections, and entity caches. Import requires a fresh target,
  verifies the complete archive and audit chain before writing, restores through private Ash
  actions in one Account transaction, then schedules ordinary rebuild work.
  """

  @doc """
  Writes a complete logical archive for the actor's Account to `output_path`.

  Reads in one Account-scoped transaction, so the archive is a coherent
  snapshot. Returns `{:ok, summary}` describing the written path, the archive
  schema, resource counts, blob count, verified audit head, and duration.
  Raises on an unreadable blob, a blob whose bytes no longer match their
  recorded checksum, or a filesystem failure.
  """
  defdelegate export(actor, output_path), to: MemHouse.Portability.Archive

  @doc """
  Restores an archive into a fresh Account.

  Verifies the whole archive first, stores its blobs, then — in one
  Account-scoped transaction — performs every durable write and queues the
  derived-cache rebuilds the archive deliberately omits. Returns `{:ok, summary}`
  with per-resource counts, blob count, the manifest hash, and the audit head.

  Raises if the target Account already exists, if any verification step fails,
  or if the restore transaction cannot commit — in which case nothing durable
  from the archive remains.
  """
  defdelegate import(input_path), to: MemHouse.Portability.Archive

  @doc """
  Verifies an archive without writing anything.

  Runs exactly the checks an import runs before its transaction — schema,
  checksums, counts, blob hashes, and the audit chain — and reports the schema,
  Account id, manifest hash, and audit head. Raises with the specific failure if
  the archive is not sound.
  """
  defdelegate validate(input_path), to: MemHouse.Portability.Archive
end
