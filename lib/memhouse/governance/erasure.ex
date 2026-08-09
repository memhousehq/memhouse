# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Governance.Erasure do
  @moduledoc """
  Erases everything one peer contributed to an Account, in one transaction.

  Deletes a peer's subject knowledge, questions, messages, sessions, credentials, grants, and peer
  row, then rebuilds affected projections and entities.

  ## Two modes

  * `"proportionate"` deletes knowledge whose *subject* is the peer, and for
    knowledge that merely *cites* the peer's messages it removes the peer's
    provenance rows and narrows the remaining source list. Something another
    person also said stays, minus this peer's contribution. Knowledge whose
    only sources were the erased messages is retracted rather than kept alive
    with no evidence behind it.
  * `"strict"` additionally deletes every piece of knowledge that was derived
    from the peer's messages at all, even when the subject is somebody else.
    This is the heavier reading of "delete everything of mine".

  ## What deliberately survives

  The content-safe audit chain survives as proof. Never delete its rows; completion metadata keeps
  only counts and mode.

  ## Ordering and safety constraints

  Deletion is a hard delete through Ash `erase` destroy actions; there is no
  soft-delete flag and no undo. Order is load-bearing:

  1. child rows (mentions, attributions, provenances, deliveries, session
     participants and scopes) go before the rows they reference;
  2. the per-scope caches are rebuilt *after* the knowledge rows are destroyed,
     so they rebuild from surviving knowledge rather than from rows about to
     vanish; and
  3. the peer row is destroyed last, because everything else points at it.

  Request, deletion, cache refresh, completion, and audit are one transaction.

  A system-pipeline actor spans every Account scope so erasure cannot be partial.
  """

  alias MemHouse.Accounts.ApiKey
  alias MemHouse.Accounts.ExternalIdentity
  alias MemHouse.Accounts.Peer
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Audit
  alias MemHouse.Governance.ErasureRequest
  alias MemHouse.Governance.PeerQuery
  alias MemHouse.Governance.PeerQueryDelivery
  alias MemHouse.Knowledge.Attribution
  alias MemHouse.Knowledge.Entity
  alias MemHouse.Knowledge.EntityMention
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.KnowledgeRelation
  alias MemHouse.Knowledge.Projection
  alias MemHouse.Knowledge.Provenance
  alias MemHouse.Observations.Message
  alias MemHouse.Observations.Session
  alias MemHouse.Observations.SessionParticipant
  alias MemHouse.Observations.SessionScope
  alias MemHouse.Topology.RoleGrant

  require Ash.Query

  @doc """
  Records an erasure request and carries it out immediately.

  `peer_id` is the peer being erased and `mode` is `"proportionate"` or
  `"strict"`. Only two callers are allowed: the peer erasing themself, or an
  account administrator who authenticated with a password session. A machine
  credential can never erase somebody else, no matter what role it holds —
  that is why the check tests the identity kind and not only the role.

  Returns the completed request record, which carries the mode and the affected
  counts. Raises `Ash.Error.Forbidden` when the caller is not allowed,
  `ArgumentError` for an unknown mode, `Ash.Error.Query.NotFound` when the peer
  does not exist in this Account, and propagates any failure from the deletion
  itself — in which case the transaction rolls back and nothing was erased.

  The request row is created and executed inside the same transaction, so a
  `pending` request cannot be left behind by a crash mid-deletion.
  """
  def request(actor, peer_id, mode) when mode in ["proportionate", "strict"] do
    allowed? =
      actor.peer_id == peer_id ||
        (actor.identity_kind == :password && actor.role == :account_admin)

    unless allowed? do
      raise Ash.Error.Forbidden, errors: []
    end

    DataLayer.with_actor(actor, fn account, current_actor ->
      request =
        ErasureRequest
        |> Ash.Changeset.new()
        |> Ash.Changeset.set_tenant(account.id)
        |> Ash.Changeset.for_create(:request, %{
          peer_id: peer_id,
          mode: mode,
          requested_by_peer_id: current_actor.peer_id,
          state: "pending",
          requested_at: Clock.utc_now()
        })
        |> Ash.create!(actor: current_actor)

      execute!(request, pipeline_actor(current_actor))
    end)
  end

  def request(_actor, _peer_id, _mode), do: raise(ArgumentError, "invalid erasure mode")

  @doc """
  Performs the deletion described by a persisted erasure request.

  `request` must already exist and carry the Account, the target peer, and the
  mode; `actor` must be a system pipeline actor with access to every scope,
  because the sweep has to reach data the requester cannot read. Returns the
  request updated to `completed` with its affected counts.

  Raises on any failure, including `Ash.Error.Query.NotFound` when the peer is
  gone. Callers must run it inside a transaction — `request/3` already does —
  so that a partial erasure can never commit.

  Every deletion goes through a named Ash destroy action as the pipeline actor
  and is permanent; the two derived-cache updates (marking projections dirty and
  narrowing an entity's derivation list) skip authorization outright, because
  they are cache maintenance rather than governed content changes. Do not call
  this to "clean up test data": it removes credentials and identities as well as
  content.
  """
  def execute!(request, actor) do
    account_id = request.account_id

    peer =
      Peer
      |> Ash.Query.filter(id == ^request.peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    if is_nil(peer), do: raise(Ash.Error.Query.NotFound, resource: Peer)

    messages =
      Message
      |> Ash.Query.filter(peer_id == ^request.peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    message_ids = MapSet.new(messages, & &1.id)

    # Source attribution lives in an array column, so membership is tested in
    # Elixir and the Account's knowledge is read in full. That is the cost of
    # being certain nothing sourced from this peer is missed.
    all_knowledge =
      KnowledgeItem
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    # "About the peer" and "derived from the peer" are different sets, and the
    # mode decides whether the second one is deleted or merely scrubbed.
    subject_knowledge = Enum.filter(all_knowledge, &(&1.subject_peer_id == request.peer_id))

    sourced_knowledge =
      Enum.filter(all_knowledge, fn knowledge ->
        Enum.any?(knowledge.source_message_ids, &MapSet.member?(message_ids, &1))
      end)

    strict_extra =
      if request.mode == "strict" do
        sourced_knowledge -- subject_knowledge
      else
        []
      end

    delete_knowledge = Enum.uniq_by(subject_knowledge ++ strict_extra, & &1.id)
    delete_ids = MapSet.new(delete_knowledge, & &1.id)

    # Order matters. Projections and entities are adjusted while the deleted
    # ids are still known, the peer's questions and the knowledge rows are
    # destroyed next, and the per-scope caches are rebuilt only afterwards, so
    # they rebuild from surviving knowledge instead of from rows about to go.
    recompute_projections!(account_id, actor, request.peer_id, delete_ids)
    recompute_entities!(account_id, actor, delete_ids)
    erase_peer_queries!(account_id, actor, request.peer_id)
    erase_knowledge_rows!(account_id, actor, delete_knowledge)

    # Proportionate mode only: knowledge that stays keeps its other sources and
    # loses this peer's. In strict mode every sourced item was already deleted
    # above, so this list comes out empty.
    retained_sourced =
      sourced_knowledge
      |> Enum.reject(&MapSet.member?(delete_ids, &1.id))
      |> Enum.map(&scrub_source!(&1, actor, message_ids))

    affected_scope_ids =
      (Enum.map(delete_knowledge, & &1.scope_id) ++ Enum.map(retained_sourced, & &1.scope_id))
      |> Enum.uniq()

    refresh_derived_scopes!(account_id, actor, affected_scope_ids)

    Enum.each(messages, &destroy!(&1, :erase, actor))
    erase_sessions_and_identity!(account_id, actor, request.peer_id)

    counts = %{
      "messages" => length(messages),
      "knowledge_deleted" => length(delete_knowledge),
      "knowledge_source_scrubbed" => length(retained_sourced),
      "mode" => request.mode
    }

    completed = complete!(request, actor, counts)

    # The only trace left behind: who requested it, which peer id, and how many
    # rows of each kind went. Counts and the mode are safe to keep forever;
    # nothing that was erased may be copied into this metadata.
    Audit.append!(actor, account_id, %{
      actor_peer_id: request.requested_by_peer_id,
      category: "deletion",
      action: "peer.erased",
      resource_type: "peer",
      resource_id: request.peer_id,
      metadata: counts
    })

    # Last, because every row removed above referenced it.
    destroy!(peer, :erase, actor)
    completed
  end

  # Removes this peer's contribution from a knowledge item that other people
  # also support: the provenance rows citing the erased messages go, and the
  # item's source list keeps only the ids that survive. Provenance is removed
  # before the messages themselves, so no row is left citing a deleted message.
  #
  # When nothing survives, the item is retracted rather than left standing with
  # an empty evidence list. It is not deleted, because in this mode the
  # statement may be about somebody else who did not ask to be forgotten.
  defp scrub_source!(knowledge, actor, message_ids) do
    surviving_ids =
      Enum.reject(knowledge.source_message_ids, &MapSet.member?(message_ids, &1))

    provenances =
      Provenance
      |> Ash.Query.filter(knowledge_item_id == ^knowledge.id)
      |> Ash.Query.set_tenant(knowledge.account_id)
      |> Ash.read!(actor: actor)

    provenances
    |> Enum.filter(&MapSet.member?(message_ids, &1.message_id))
    |> Enum.each(&destroy!(&1, :erase, actor))

    if surviving_ids == [] do
      MemHouse.Governance.Engine.transition!(
        knowledge,
        actor,
        %{
          state: "retracted",
          verification: "sole_source_erased",
          source_message_ids: []
        },
        reason: "f4_proportionate_erasure_sole_source",
        channel: "erasure"
      )
    else
      knowledge
      |> Ash.Changeset.for_update(:merge_from_pipeline, %{source_message_ids: surviving_ids})
      |> Ash.Changeset.set_tenant(knowledge.account_id)
      |> Ash.update!(actor: actor)
    end
  end

  # Internal helper, shared with document erasure, kept out of the generated
  # docs on purpose: it takes rows that the caller has already decided must go
  # and deletes them permanently, performing no eligibility check of its own.
  #
  # Entity mentions, attributions, and provenances are destroyed before the
  # knowledge rows they point at, so no child row is ever orphaned. The caller
  # is responsible for running inside a transaction and for refreshing derived
  # caches afterwards.
  @doc false
  def erase_knowledge_rows!(account_id, actor, knowledge_rows) do
    ids = Enum.map(knowledge_rows, & &1.id)

    KnowledgeRelation
    |> Ash.Query.filter(source_knowledge_id in ^ids or target_knowledge_id in ^ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    EntityMention
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Attribution
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Provenance
    |> Ash.Query.filter(knowledge_item_id in ^ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Enum.each(knowledge_rows, &destroy!(&1, :erase, actor))
  end

  # Inline questions and their delivery rows are content-bearing: the question
  # froze the statement text that was quoted back to the peer, and the delivery
  # records what was shown and answered. Both are erasable and go here,
  # deliveries first because they reference the question.
  defp erase_peer_queries!(account_id, actor, peer_id) do
    queries =
      PeerQuery
      |> Ash.Query.filter(peer_id == ^peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    query_ids = Enum.map(queries, & &1.id)

    PeerQueryDelivery
    |> Ash.Query.filter(peer_query_id in ^query_ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Enum.each(queries, &destroy!(&1, :erase, actor))
  end

  # Projections are rebuildable summaries, so they are only flagged dirty here
  # and recomputed later from surviving knowledge. Anything either about this
  # peer or built from a deleted item is flagged. `authorize?: false` is used
  # because this is a cache maintenance write, not a governed content change.
  defp recompute_projections!(account_id, actor, peer_id, deleted_ids) do
    Projection
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.filter(fn projection ->
      projection.peer_id == peer_id ||
        Enum.any?(projection.source_ids, &MapSet.member?(deleted_ids, &1))
    end)
    |> Enum.each(fn projection ->
      projection
      |> Ash.Changeset.for_update(:refresh_from_pipeline, %{dirty: true})
      |> Ash.Changeset.set_tenant(account_id)
      |> Ash.update!(actor: actor, authorize?: false)
    end)
  end

  # Entities are derived caches too. An entity keeps existing while at least one
  # surviving statement still derives it; when its last supporting statement is
  # deleted the entity goes with it, otherwise its derivation list is narrowed.
  # Untouched entities are skipped so the pass writes only what changed.
  defp recompute_entities!(account_id, actor, deleted_ids) do
    Entity
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(fn entity ->
      surviving = Enum.reject(entity.derived_from, &MapSet.member?(deleted_ids, &1))

      cond do
        surviving == entity.derived_from ->
          :ok

        surviving == [] ->
          destroy!(entity, :erase, actor)

        true ->
          entity
          |> Ash.Changeset.for_update(:recompute_from_pipeline, %{derived_from: surviving})
          |> Ash.Changeset.set_tenant(account_id)
          |> Ash.update!(actor: actor, authorize?: false)
      end
    end)
  end

  # Full rebuild of the caches for every scope that lost knowledge. This runs
  # after the deletions so it reads only surviving rows; running it earlier
  # would faithfully rebuild the data being erased. Both rebuilds must succeed
  # or the match fails and aborts the transaction.
  defp refresh_derived_scopes!(account_id, actor, scope_ids) do
    Enum.each(scope_ids, fn scope_id ->
      MemHouse.Pipeline.Consolidator.run_scope!(account_id, scope_id, actor)

      {:ok, _entities} =
        MemHouse.Retrieval.EntityResolver.rebuild_scope(account_id, scope_id)

      {:ok, _projections} = MemHouse.Context.Builder.refresh_scope(account_id, scope_id)
    end)
  end

  # Erasure covers the peer's presence, not just their words: sessions and
  # their membership rows, then the credentials and external identities that
  # could be used to log in again, then the role grants that would otherwise
  # dangle. Participant and scope rows are removed before their sessions.
  defp erase_sessions_and_identity!(account_id, actor, peer_id) do
    sessions =
      Session
      |> Ash.Query.filter(peer_id == ^peer_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    session_ids = Enum.map(sessions, & &1.id)

    SessionParticipant
    |> Ash.Query.filter(peer_id == ^peer_id or session_id in ^session_ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    SessionScope
    |> Ash.Query.filter(session_id in ^session_ids)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    Enum.each(sessions, &destroy!(&1, :erase, actor))

    ApiKey
    |> Ash.Query.filter(peer_id == ^peer_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :destroy, actor))

    ExternalIdentity
    |> Ash.Query.filter(peer_id == ^peer_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))

    RoleGrant
    |> Ash.Query.filter(peer_id == ^peer_id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&destroy!(&1, :erase, actor))
  end

  # The request row is the durable, queryable receipt: mode, timestamps, and
  # per-kind counts. It holds no erased content, so it can outlive the data.
  defp complete!(request, actor, counts) do
    request
    |> Ash.Changeset.for_update(:complete, %{
      state: "completed",
      affected_counts: counts,
      completed_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(request.account_id)
    |> Ash.update!(actor: actor)
  end

  # Every deletion goes through a named Ash destroy action under the row's own
  # Account tenant, never a raw delete, so policies and row-level security
  # still apply and a cross-Account row can never be reached.
  defp destroy!(record, action, actor) do
    record
    |> Ash.Changeset.for_destroy(action)
    |> Ash.Changeset.set_tenant(record.account_id)
    |> Ash.destroy!(actor: actor)
  end

  # Erasure must reach scopes the requester cannot read, so the executing actor
  # is widened to every scope. This elevation exists only for the duration of
  # the erasure; the requester's own actor is unchanged.
  defp pipeline_actor(%MemHouse.Actor{} = actor),
    do: %{actor | role: :system, scope_ids: :all, pipeline?: true}

  defp pipeline_actor(actor),
    do: actor |> Map.put(:role, :system) |> Map.put(:pipeline?, true)
end
