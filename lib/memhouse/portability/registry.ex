# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Portability.Registry do
  @moduledoc """
  Defines the durable resources and dependency order in an Account archive.

  Only system-of-record rows belong here. Credentials, secrets, and rebuildable chunks, vectors,
  projections, entities, and mentions remain excluded; original blobs are handled separately
  with checksums.
  """

  # Restoration order. Each entry maps the archive's file name to the resource
  # that owns those rows; the file name is part of the archive format, so
  # renaming one breaks archives already written.
  @resources [
    {"accounts", MemHouse.Accounts.Account},
    {"scopes", MemHouse.Topology.Scope},
    {"peers", MemHouse.Accounts.Peer},
    {"external_identities", MemHouse.Accounts.ExternalIdentity},
    {"sessions", MemHouse.Observations.Session},
    {"session_scopes", MemHouse.Observations.SessionScope},
    {"session_participants", MemHouse.Observations.SessionParticipant},
    {"connector_configs", MemHouse.Documents.ConnectorConfig},
    {"documents", MemHouse.Observations.Document},
    {"document_versions", MemHouse.Observations.DocumentVersion},
    {"messages", MemHouse.Observations.Message},
    {"model_role_configs", MemHouse.Model.ModelRoleConfig},
    {"retrieval_profiles", MemHouse.Retrieval.RetrievalProfile},
    {"skill_requirement_cards", MemHouse.Skills.SkillRequirementCard},
    {"policy_configs", MemHouse.Governance.PolicyConfig},
    {"governance_gate_rules", MemHouse.Governance.GateRule},
    {"knowledge_items", MemHouse.Knowledge.KnowledgeItem},
    {"provenances", MemHouse.Knowledge.Provenance},
    {"attributions", MemHouse.Knowledge.Attribution},
    {"knowledge_relations", MemHouse.Knowledge.KnowledgeRelation},
    {"validation_items", MemHouse.Governance.ValidationItem},
    {"knowledge_consents", MemHouse.Governance.Consent},
    {"peer_queries", MemHouse.Governance.PeerQuery},
    {"peer_query_deliveries", MemHouse.Governance.PeerQueryDelivery},
    {"peer_ask_preferences", MemHouse.Governance.PeerAskPreference},
    {"erasure_requests", MemHouse.Governance.ErasureRequest},
    {"role_grants", MemHouse.Topology.RoleGrant},
    {"scope_relations", MemHouse.Topology.ScopeRelation},
    {"audit_events", MemHouse.Governance.AuditEvent}
  ]

  # Rebuildable caches. Never exported; recomputed on the target after import.
  # Listed explicitly rather than merely omitted so the manifest can state what
  # was left out, and so a reader can tell "excluded on purpose" from "someone
  # forgot to add it".
  @derived_resources [
    MemHouse.Documents.DocumentChunk,
    MemHouse.Knowledge.Entity,
    MemHouse.Knowledge.EntityMention,
    MemHouse.Knowledge.Projection
  ]

  # Retained operational history does not travel. The target reconstructs work from durable
  # sources and starts new usage and governance-retention horizons of its own.
  @operational_resources [
    MemHouse.Knowledge.LifecycleEvent,
    MemHouse.Governance.GateDecision,
    MemHouse.Operations.UsageEvent,
    MemHouse.Operations.PipelineRun
  ]

  # Credential-bearing resources. An archive must never be a way to move
  # authentication material between installations.
  @credential_resources [MemHouse.Accounts.ApiKey]

  # Attributes stripped from rows that are otherwise portable.
  #
  #   * a peer's password hash is a credential and does not travel;
  #   * knowledge embeddings and their provider/model identity are recomputed by
  #     the target's own embedder, so exporting them would risk restoring
  #     vectors that do not match the target's embedding identity;
  #   * a document version's extracted text, extraction metadata, chunk counts,
  #     and completion stamp are extraction bookkeeping — the original blob is
  #     exported instead, and the target re-derives all of it.
  @sensitive_attributes %{
    MemHouse.Accounts.Peer => [:hashed_password],
    MemHouse.Observations.Message => [
      :diskann_labels,
      :embedding,
      :embedding_provider,
      :embedding_model,
      :embedding_version,
      :embedding_dimensions,
      :source_indexed_at
    ],
    MemHouse.Knowledge.KnowledgeItem => [
      :embedding,
      :embedding_provider,
      :embedding_model,
      :embedding_version,
      :embedding_dimensions
    ],
    MemHouse.Observations.DocumentVersion => [
      :extracted_text,
      :extraction_metadata,
      :chunk_count,
      :embedded_chunk_count,
      :extraction_completed_at
    ]
  }

  @doc """
  The portable resources as `{archive_file_name, resource_module}` pairs, in
  dependency order. Export writes them in this order and import restores them in
  this order; callers must not sort or regroup the list.
  """
  def resources, do: @resources

  @doc """
  Resources that are rebuilt on the target instead of being exported. Reported
  in the archive manifest so the exclusion is visible to whoever inspects it.
  """
  def derived_resources, do: @derived_resources

  @doc "Resources with local retention horizons, which are not exported."
  def operational_resources, do: @operational_resources

  @doc """
  Resources holding authentication material, which never appear in an archive.
  """
  def credential_resources, do: @credential_resources

  @doc """
  Attributes to strip from a portable resource's rows.

  Returns a list of attribute names, empty for resources that export in full.
  Export consults this per row, so adding an entry here is all that is needed to
  keep a newly added secret or derived column out of every future archive.
  """
  def excluded_attributes(resource), do: Map.get(@sensitive_attributes, resource, [])

  @doc """
  Resolves an archive file name to the resource that owns those rows.

  Import calls this on every manifest entry, which is what makes an archive
  naming an unknown or non-portable resource fail early instead of being
  partially applied. Raises `ArgumentError` for a name that is not in the
  portable list.
  """
  def resource!(name) do
    case List.keyfind(@resources, name, 0) do
      {^name, resource} -> resource
      nil -> raise ArgumentError, "unknown portability resource #{inspect(name)}"
    end
  end
end
