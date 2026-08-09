# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouse.Memory do
  @moduledoc """
  Account-scoped facade for ingest, extraction, retrieval, context, and skill
  readiness. HTTP, MCP, evaluation, and jobs use it instead of resources.

  Authenticated calls derive Account from the actor. `account_key` and
  `account_id` are internal-only job/evaluation inputs. Callers submit raw
  observations; only the pipeline creates `proposed` knowledge through Ash.

  Message and knowledge responses expose only public resource attributes, so
  making an attribute public also changes the API. Traces contain identifiers,
  counts, lengths, and profile names—never messages, questions, answers, or
  statements.

  After creating a scope, re-resolve the actor's grants before scoped writes;
  its authorized-scope set is a snapshot. Keep raw strategy overrides internal.
  """

  alias MemHouse.Accounts.Peer
  alias MemHouse.Actor
  alias MemHouse.Clock
  alias MemHouse.DataLayer
  alias MemHouse.Governance.Audit
  alias MemHouse.Governance.Engine
  alias MemHouse.Identity.RoleResolver
  alias MemHouse.Knowledge.Attribution
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Knowledge.LifecycleEvent
  alias MemHouse.Knowledge.Provenance
  alias MemHouse.Knowledge.Statement
  alias MemHouse.Observability
  alias MemHouse.Observations.Message
  alias MemHouse.Observations.Session
  alias MemHouse.Observations.SessionParticipant
  alias MemHouse.Observations.SessionScope
  alias MemHouse.Operations.PipelineRun
  alias MemHouse.Pipeline.Extractor
  alias MemHouse.Pipeline.Idempotency
  alias MemHouse.Pipeline.Lock
  alias MemHouse.Retrieval.DiagnosticGrant
  alias MemHouse.Retrieval.Profile
  alias MemHouse.Retrieval.Query, as: RetrievalQuery
  alias MemHouse.Skills
  alias MemHouse.Topology.Scope

  require Ash.Query

  # Default page size, in rows, for knowledge listing and retrieval when the
  # caller names no limit. In retrieval it also caps how many candidates each
  # strategy may contribute, so raising it widens the fused candidate pool too.
  @default_limit 12
  @extraction_window_size 6

  @doc """
  Persists one raw observation and enqueues extraction before returning.

  `attrs` may use atom or string keys; they are normalized to strings.
  `"scope_path"`, `"session_id"`, and `"content"` are required and a missing
  one raises `KeyError`. `"peer_key"` is required as well, unless
  `identity_actor` already identifies the Peer. Optional keys:

  - `"peer_name"` — display name used when the Peer row is first created.
  - `"role"` — speaker role, defaults to `"user"`.
  - `"occurred_at"` — `DateTime` or ISO 8601 string. Anything unparseable
    becomes the current time rather than failing the request.
  - `"account_key"` or `"account_id"` — internal Account selection, consulted
    only when `identity_actor` is `nil`.

  Missing scopes, sessions, session-scope links, and session participants are
  created on the way in, so a caller never has to provision them first. An
  authenticated caller always speaks as its own existing Peer; only the internal
  `"peer_key"` path creates a Peer that does not exist yet.

  Returns `{:ok, message}`, where `message` holds the message's public
  attributes with string keys. Extraction never runs in the caller. The
  observation, content-safe audit entry, pipeline run, and Oban job commit
  together before this function returns.

  Failure modes: the durable writes use raising Ash calls, so an authorization
  or validation failure raises instead of returning an error tuple. Model
  provider failures happen later in the durable job and cannot turn an accepted
  observation into a caller-visible ingest error.
  """
  def ingest_message(attrs, identity_actor \\ nil) do
    Observability.with_span(:memory, "memhouse.memory.ingest_message", fn ->
      attrs = attrs |> normalize_attrs() |> put_identity_actor(identity_actor)

      # Content-safe tracing: the message's role and length, never its text.
      Observability.set_attributes(:memory, %{
        "memhouse.ingest.enqueue_extract" => true,
        "memhouse.message.role" => Map.get(attrs, "role", "user"),
        "memhouse.message.content_length" =>
          String.length(to_string(Map.get(attrs, "content", "")))
      })

      message =
        with_account(attrs, fn account, actor ->
          # Order matters. The scope chain is created first, then the actor is
          # re-resolved from its Peer's role grants, because an authenticated
          # actor's authorized scope list was computed when the credential was
          # verified and would not contain a scope this request just created —
          # every write below would then be refused by the scope policy.
          scope = ensure_scope!(account.id, actor, Map.fetch!(attrs, "scope_path"))

          {peer, actor} = request_peer_and_actor!(account, actor, attrs)

          session =
            ensure_session!(
              account.id,
              actor,
              scope.id,
              peer.id,
              Map.fetch!(attrs, "session_id")
            )

          ensure_session_scope!(account.id, actor, session.id, scope.id)
          ensure_session_participant!(account.id, actor, session.id, peer.id)

          message =
            create!(
              Message,
              :create,
              %{
                session_id: session.id,
                scope_id: scope.id,
                peer_id: peer.id,
                role: Map.get(attrs, "role", "user"),
                content: Map.fetch!(attrs, "content"),
                occurred_at: coerce_datetime!(Map.get(attrs, "occurred_at"))
              },
              account.id,
              actor
            )

          record_to_map(message)
        end)

      Observability.set_attribute(:memory, "memhouse.message.id", message["id"])
      {:ok, message}
    end)
  end

  @doc """
  Reports durable extraction state for one raw message visible to the caller.

  The Account comes from `identity_actor`. Message and pipeline-run reads use
  the same scope policy as ordinary message reads. Completed results include
  only governed knowledge the caller may currently read: active knowledge and
  the calling peer's own provisional knowledge.

  Returns `{:ok, status}` with `"status"`, `"extraction_completed_at"`,
  `"knowledge"`, `"last_error_class"`, and `"attempt_count"`, or
  `{:error, :not_found}` when the message does not exist or is outside the
  caller's Account or authorized scopes.
  """
  def ingest_status(message_id, %Actor{} = identity_actor) when is_binary(message_id) do
    case Ecto.UUID.cast(message_id) do
      {:ok, message_id} -> do_ingest_status(message_id, identity_actor)
      :error -> {:error, :not_found}
    end
  end

  defp do_ingest_status(message_id, identity_actor) do
    Observability.with_span(:memory, "memhouse.memory.ingest_status", fn ->
      Observability.set_attribute(:memory, "memhouse.message.id", message_id)

      %{}
      |> put_identity_actor(identity_actor)
      |> with_account(fn account, actor ->
        read_ingest_status(account.id, actor, message_id)
      end)
    end)
  end

  @doc """
  Runs the extraction pipeline over one already-persisted raw message.

  `account_key` may be omitted, in which case the owning Account is looked up
  from the message id; that lookup raises when no such message exists. The work
  runs under an internal system actor carrying the pipeline flag, which is what
  permits it to write knowledge and to stamp the message as extracted. No
  external caller can obtain such an actor.

  Returns `{:ok, knowledge}` with one map per created or merged knowledge item,
  or `{:error, error}` when the model provider fails. That failure is returned
  rather than raised so the durable job retries instead of dropping the
  observation.

  Safe to run repeatedly: an identical statement about the same subject in the
  same scope merges into the existing knowledge item, and the merge appends
  neither a second creation lifecycle event nor a second gate decision.
  """
  def extract_message(message_id, account_key \\ nil) do
    Observability.with_span(:memory, "memhouse.memory.extract_message", fn ->
      Observability.set_attribute(:memory, "memhouse.message.id", message_id)
      account_key = account_key || DataLayer.message_account_key!(message_id)

      # The Account is resolved by key only in this first, short transaction; everything
      # after it addresses the Account by id, so the upsert that key resolution performs runs
      # exactly once per extraction.
      {account_id, message, context} =
        DataLayer.with_account_key(
          account_key,
          [role: :system, pipeline?: true],
          fn account, actor ->
            message = fetch_message!(account, actor, message_id)
            {account.id, message, message_context(account, actor, message)}
          end
        )

      record_extraction_result(extract_then_write(account_id, message_id, message, context))
    end)
  end

  @doc """
  Same as `extract_message/2`, for a caller that already knows the Account id.

  This is the path the queued extraction job takes: the durable job row already
  carries the Account id, so resolving it from the message would be wasted
  work. Return values, tracing, and failure behaviour are identical to
  `extract_message/2`.
  """
  def extract_message_for_account(message_id, account_id) do
    Observability.with_span(:memory, "memhouse.memory.extract_message", fn ->
      Observability.set_attribute(:memory, "memhouse.message.id", message_id)

      {message, context} =
        DataLayer.with_account_id(
          account_id,
          [role: :system, pipeline?: true],
          fn account, actor ->
            message = fetch_message!(account, actor, message_id)
            {message, message_context(account, actor, message)}
          end
        )

      record_extraction_result(extract_then_write(account_id, message_id, message, context))
    end)
  end

  # Builds the extractor input for the parsed text of one document version.
  #
  # This is the read half of document extraction, and it must run inside an Account-scoped
  # transaction: listing the Account's peer keys is a database read. It writes nothing.
  #
  # Deliberately kept out of the public surface: only the document service calls it, and only
  # it can supply the facts this function cannot derive. `attrs` must carry "id" (the document
  # version id, which becomes the provenance target), "scope_id", "peer_id", "peer_key",
  # "scope_path", "content", and "occurred_at" (the version's observation time, which dates an
  # event the model leaves undated — a document has no conversational turn to date it).
  #
  # Marking the observation document-sourced keeps message provenance out of the result: the
  # knowledge item's source message list stays empty and its provenance row points at the
  # document version instead.
  #
  # Returns {observation, context} to be handed, in that order, to `Extractor.extract/2` and
  # then to `persist_document_knowledge!/4`.
  @doc false
  def document_observation(account_id, actor, attrs)
      when is_binary(account_id) and is_map(actor) and is_map(attrs) do
    observation =
      attrs
      |> normalize_attrs()
      |> Map.put("source_type", "document")
      |> Map.put("known_peer_keys", known_peer_keys(account_id, actor))

    context = %{
      account_id: account_id,
      scope_id: Map.fetch!(observation, "scope_id"),
      peer_id: Map.fetch!(observation, "peer_id"),
      source_peer_id: Map.fetch!(observation, "peer_id"),
      document_version_id: Map.fetch!(observation, "id"),
      actor: actor
    }

    {observation, context}
  end

  # Writes the candidates a document extraction produced, one knowledge item each.
  #
  # The write half, and the counterpart to `document_observation/3`. It must run inside an
  # Account-scoped transaction holding an actor allowed to write knowledge — a different,
  # later transaction than the read half, because the model call between them must not hold a
  # database connection.
  #
  # Extracted document knowledge still enters as a proposal and still passes the governance
  # gate; nothing here can activate a statement.
  @doc false
  def persist_document_knowledge!(account_id, actor, observation, items)
      when is_binary(account_id) and is_map(actor) and is_map(observation) and is_list(items) do
    Enum.map(items, &insert_knowledge!(account_id, actor, observation, &1))
  end

  @doc """
  Lists governed knowledge for a scope path and its ancestors.

  This is a plain listing, not retrieval: no strategies, no fusion, no query
  text. `filters` accepts:

  - `"scope_path"` — defaults to `"/poc"`. The named scope and every ancestor
    on its path are read; scopes the caller may not see simply do not appear.
  - `"state"` — lifecycle state, defaults to `"active"`.
  - `"limit"` — row cap, defaults to 12.

  With the default state and an authenticated Peer, the result is everything
  `active` plus that Peer's own `provisional` items — provisional knowledge is
  usable only by the peer it is about and must not leak to anyone else. An
  internal actor that carries no Peer sees all provisional items. Any other
  requested state matches exactly, with no provisional widening.

  Rows come back highest confidence first, ties broken by most recently
  inserted. Each row is the knowledge item's public attributes with string
  keys, plus `"scope_path"`. Raises when no Account can be derived from the
  caller.
  """
  def query_knowledge(filters, identity_actor \\ nil) do
    Observability.with_span(:memory, "memhouse.memory.query_knowledge", fn ->
      filters = filters |> normalize_attrs() |> put_identity_actor(identity_actor)
      state = Map.get(filters, "state", "active")
      limit = parse_int(Map.get(filters, "limit"), @default_limit)

      rows =
        with_account(filters, fn account, actor ->
          scopes = visible_scopes(account.id, actor, Map.get(filters, "scope_path", "/poc"))
          scope_ids = Enum.map(scopes, & &1.id)
          scope_paths = Map.new(scopes, &{&1.id, &1.path})

          Observability.set_attributes(:memory, %{
            "memhouse.knowledge.state" => state,
            "memhouse.query.limit" => limit,
            "memhouse.query.scope_count" => length(scope_ids)
          })

          scope_ids
          |> knowledge_read_query(state, actor)
          |> Ash.Query.sort(confidence: :desc, inserted_at: :desc)
          |> Ash.Query.limit(limit)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
          |> Enum.map(fn item ->
            item
            |> record_to_map()
            |> Map.put("scope_path", Map.fetch!(scope_paths, item.scope_id))
          end)
        end)

      Observability.set_attribute(:memory, "memhouse.query.result_count", length(rows))
      rows
    end)
  end

  @doc """
  Runs multi-strategy retrieval and returns the fused, ranked candidates.

  Recognized keys in `filters`:

  - `"query"` — the search text, defaults to an empty string.
  - `"scope_path"` — defaults to `"/poc"`; the scope and its ancestors are
    searched, so knowledge written higher in the tree is reachable from below.
  - `"profile"` — named retrieval profile, defaults to `"balanced"`.
  - `"limit"` — candidate cap, defaults to 12. It bounds each strategy's
    contribution as well as the fused list.
  - `"deadline"` — the string `"disabled"` removes the profile's latency bound.
    Intended for evaluation runs; a request path should leave it on.
  - `"include_cross_links"` — `true`, `"true"`, or `"1"` also searches scopes
    joined to the requested ones by a scope relation. Both endpoints still have
    to pass the caller's authorization, so a relation never grants access.
  - `"as_of"`, `"min_score"`, `"source_filters"` — optional belief-time,
    score-floor, and source restrictions.
  - `"strategies"` — a raw strategy override. Only an internal system identity
    may pass it; retrieval raises `ArgumentError` for anyone else, because
    strategy names are an internal seam rather than a public contract.
  - `"_diagnostic"` — a `MemHouse.Retrieval.DiagnosticGrant`, which supplies
    the limit, strategy list, deadline, and rerank setting in place of the keys
    above, and may ask for the `"diagnostic_trace"` rank explanation. Only
    `diagnostic_search/2` builds one, and decoded JSON cannot produce a struct,
    so a request body cannot reach this path.

  Returns a string-keyed map holding `"query"`, `"profile"`,
  `"profile_version"`, `"deadline"`, `"latency_ms"`,
  `"contributed_strategies"`, `"empty_strategies"`, `"dropped_strategies"`,
  `"retrieval_outcomes"`, `"pre_rerank_remaining_ms"`, `"disagreement"`, and
  `"candidates"`. A strategy that ran out of deadline lands in
  `"dropped_strategies"` instead of failing the call, so a partial result is
  normal: read that list before treating a thin result as an absence of
  knowledge. The structured outcomes add content-free reason classes and
  timings while preserving the compatible dropped-name list.

  A strategy that ran and matched nothing lands in `"empty_strategies"`. When
  the text-reading strategies are all in there,
  `"disagreement"["query_dependent_empty"]` is true. Ordinary text searches do
  not add temporal or salience-recency candidates to disguise that absence;
  blank context fallback and explicit `as_of` reads retain their intentional
  query-independent paths.

  Raises when no Account can be derived from the caller.
  """
  def search(filters, identity_actor \\ nil) do
    Observability.with_span(:memory, "memhouse.memory.search", fn ->
      filters = filters |> normalize_attrs() |> put_identity_actor(identity_actor)
      query = Map.get(filters, "query", "")
      scope_path = Map.get(filters, "scope_path", "/poc")
      profile = Map.get(filters, "profile", "balanced")
      grant = diagnostic_grant(filters)

      limit =
        if grant, do: grant.limit, else: parse_int(Map.get(filters, "limit"), @default_limit)

      deadline? =
        if grant,
          do: grant.deadline?,
          else: Map.get(filters, "deadline", "enabled") != "disabled"

      {retrieval, scope_count} =
        with_account(filters, fn account, actor ->
          scopes =
            account.id
            |> visible_scopes(
              actor,
              scope_path,
              Map.get(filters, "include_cross_links", false) in [true, "true", "1"]
            )

          retrieval_query = %RetrievalQuery{
            account_id: account.id,
            actor: actor,
            scope_ids: Enum.map(scopes, & &1.id),
            text: query,
            # Internal knob: `ask/2` narrows retrieval to knowledge so an answer
            # cannot cite a document chunk as if it were a governed statement.
            target: retrieval_target(Map.get(filters, "_retrieval_target", "all")),
            as_of: parse_datetime(Map.get(filters, "as_of")),
            min_score: parse_float(Map.get(filters, "min_score")),
            source_filters: Map.get(filters, "source_filters", %{}),
            max_candidates: limit
          }

          # Only a server-side identity, or an authorized diagnostic grant, counts
          # as internal. This is what stops a request from hand-picking retrieval
          # strategies: for anyone else, passing "strategies" makes profile
          # resolution raise.
          internal? = actor.identity_kind == :system or not is_nil(grant)

          opts =
            [
              deadline?: deadline?,
              internal?: internal?,
              strategies: if(grant, do: grant.strategies, else: Map.get(filters, "strategies")),
              rerank: grant && grant.rerank,
              diagnostic_trace?: grant && grant.trace?
            ]
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)

          {MemHouse.Retrieval.retrieve(retrieval_query, profile, opts), length(scopes)}
        end)

      Observability.set_attributes(:memory, %{
        "memhouse.retrieval.profile" => retrieval.profile,
        "memhouse.retrieval.profile_version" => retrieval.profile_version,
        "memhouse.retrieval.strategy_count" => length(retrieval.contributed_strategies),
        # Counts only; a degraded run is otherwise indistinguishable from a good one in traces.
        "memhouse.retrieval.empty_strategy_count" => length(retrieval.empty_strategies),
        "memhouse.retrieval.query_dependent_empty" =>
          retrieval.disagreement["query_dependent_empty"],
        "memhouse.query.limit" => limit,
        "memhouse.query.text_length" => String.length(query),
        "memhouse.query.scope_count" => scope_count
      })

      Observability.set_attributes(:memory, %{
        "memhouse.retrieval.candidate_count" => length(retrieval.candidates),
        "memhouse.retrieval.latency_ms" => retrieval.latency_ms
      })

      stringify_top_level(retrieval)
    end)
  end

  @doc """
  Runs one retrieval diagnostic: the same search, with retrieval's internal
  controls unlocked for a password-authenticated account administrator.

  This exists to reproduce retrieval behavior, not to serve it. A run may look
  past the ordinary result window, isolate strategies, drop the deadline, and
  turn reranking off, so its ranking is deliberately not what a production
  request would produce; the returned `"diagnostic"` block says as much and the
  caller must present it that way.

  It grants no extra data access. Account, authorized scopes, lifecycle states,
  and provisional subject rules are applied exactly as in `search/2`, because
  the same retrieval query runs under the same actor.

  `attrs` uses the `search/2` keys `"query"`, `"scope_path"`, `"profile"`,
  `"limit"`, `"include_cross_links"`, `"as_of"`, `"min_score"`, and
  `"source_filters"`, plus four diagnostic-only keys: `"strategies"` (names to
  run in place of the profile's own), `"deadline"` (`"disabled"` removes the
  latency bound), `"rerank"` (a boolean forcing the rerank stage on or off), and
  `"trace"` (asks for the rank explanation). Everything else is dropped rather
  than forwarded, so the exported request is exactly what ran. The limit is
  clamped to `MemHouse.Retrieval.DiagnosticGrant.max_limit/0`.

  Returns the `search/2` map with a string-keyed `"diagnostic"` block holding
  the requested options, the strategies that read the query text, the ordinary
  default limit, and how many returned candidates sit beyond it. With `"trace"`
  it also carries `"diagnostic_trace"`, which explains how each returned
  candidate reached its rank.

  Raises `Ash.Error.Forbidden` for any other caller, and `ArgumentError` for an
  unregistered strategy name.
  """
  def diagnostic_search(attrs, %Actor{} = actor) do
    unless diagnostic_actor?(actor), do: raise(Ash.Error.Forbidden, errors: [])

    attrs = normalize_attrs(attrs)

    grant =
      DiagnosticGrant.new(@default_limit,
        limit: Map.get(attrs, "limit"),
        strategies: Map.get(attrs, "strategies"),
        rerank: Map.get(attrs, "rerank"),
        deadline?: Map.get(attrs, "deadline", "enabled") != "disabled",
        trace?: Map.get(attrs, "trace")
      )

    result =
      attrs
      |> Map.take(~w(query scope_path profile include_cross_links as_of min_score source_filters))
      |> Map.put("_diagnostic", grant)
      |> search(actor)

    Map.put(result, "diagnostic", diagnostic_report(grant, result))
  end

  def diagnostic_search(_attrs, _actor), do: raise(Ash.Error.Forbidden, errors: [])

  @doc """
  Answers a question from governed memory and cites the knowledge it used.

  `attrs` takes the same keys as `search/2`, plus `"question"`, which is
  required and raises `KeyError` when absent. The retrieval profile defaults to
  `"thorough"` rather than the search default, because an answer is worth more
  latency than a results list, and retrieval is narrowed to knowledge so that
  only governed statements can be cited.

  The answer is grounded twice over: the model sees nothing but the retrieved
  statements, and every citation it returns is dropped unless it matches an id
  that was actually retrieved for this question. An answer whose citations all
  fail that check is replaced by an empty abstention, so a caller may rely on
  every id in `"citations"` being real and retrieved.

  The model never refuses. It answers with whatever the retrieved statements
  make most probable and states its own certainty as `"answer_confidence"`, a
  0-100 percentage. A model answer below the abstention threshold carries
  `"abstained" => true` whatever the model claimed, so a cited, abstained answer
  is the normal shape for a weakly supported inference: read it as a lead, not a
  conclusion. The model-free replies below report fixed confidences instead,
  since no model stated a probability for them.

  The one reply that is not an attempt at the question is the empty abstention
  used when no retrieved statement survived to ground an answer on. That is a
  statement about the index, not about the subject.

  When the deployment has no real model configured, and when a configured
  provider errors, the reply falls back to concatenating the top retrieved
  statements and citing exactly those, rather than inventing prose or silently
  switching providers.

  Returns the `search/2` map with `"answer"`, `"citations"`, `"abstained"`, and
  `"answer_confidence"` merged in. Raises under the same conditions as
  `search/2`.
  """
  def ask(attrs, identity_actor \\ nil) do
    Observability.with_span(:memory, "memhouse.memory.ask", fn ->
      attrs = attrs |> normalize_attrs() |> put_identity_actor(identity_actor)
      question = Map.fetch!(attrs, "question")
      profile = Map.get(attrs, "profile", "thorough")

      Observability.set_attributes(:memory, %{
        "memhouse.ask.question_length" => String.length(question),
        "memhouse.retrieval.profile" => profile
      })

      # The actor already travels inside `attrs`, so the single-argument call
      # still runs under the caller's identity rather than falling back to an
      # internal Account adapter.
      retrieval =
        attrs
        |> Map.put("query", question)
        |> Map.put("profile", profile)
        |> Map.put("_retrieval_target", "knowledge")
        |> search()

      candidates = Map.fetch!(retrieval, "candidates")

      {answer, used_model?} = answer_question(attrs, question, candidates)

      Observability.set_attributes(:memory, %{
        "memhouse.ask.candidate_count" => length(candidates),
        "memhouse.ask.used_model" => used_model?,
        "memhouse.ask.abstained" => Map.get(answer, "abstained", false),
        "memhouse.ask.answer_confidence" => Map.get(answer, "answer_confidence", 0)
      })

      Map.merge(retrieval, answer)
    end)
  end

  @doc """
  Assembles the cached context projections for a scope, without calling a model.

  This is the read an agent performs at the start of a turn: session summary,
  scope cards, entity cards, peer profiles, and a bounded slice of knowledge,
  trimmed to a character budget. It performs no reasoning. A normal assembly must never
  invoke a model, because it sits on the latency-sensitive path of every turn;
  a projection miss may fall back to a live retrieval run, and that fallback is
  reported in the result rather than hidden.

  `attrs` accepts `"scope_path"` (defaults to `"/poc"`), `"session_id"`, and
  `"budget_chars"`. Returns a string-keyed map including `"session_summary"`,
  `"scope_cards"`, `"entity_cards"`, `"peer_profile"`, `"knowledge"`,
  `"projection_cache_hit"`, and `"fast_fallback"` — the last two describing how the answer was produced:
  whether any stored projection was reused, and whether a miss fell back to
  live retrieval.

  Raises when no Account can be derived from the caller.
  """
  def get_context(attrs, identity_actor \\ nil) do
    Observability.with_span(:memory, "memhouse.memory.get_context", fn ->
      attrs = attrs |> normalize_attrs() |> put_identity_actor(identity_actor)

      context =
        with_account(attrs, fn account, actor ->
          scopes = visible_scopes(account.id, actor, Map.get(attrs, "scope_path", "/poc"))
          MemHouse.Context.get(account, actor, scopes, attrs)
        end)

      Observability.set_attributes(:memory, %{
        "memhouse.context.knowledge_count" => length(context["knowledge"]),
        "memhouse.context.projection_cache_hit" => context["projection_cache_hit"],
        "memhouse.context.fast_fallback" => context["fast_fallback"]
      })

      context
    end)
  end

  @doc """
  Reports whether the calling Peer's memory satisfies a skill's requirements.

  Unlike the other entry points this one accepts no internal Account adapter:
  it needs a real authenticated identity, because readiness is computed for one
  specific Peer and may be satisfied by that Peer's own provisional knowledge.
  Raises `ArgumentError` when `identity_actor` is `nil` and `attrs` carries no
  actor either.

  Returns the gap report: the effective requirements, the gaps that must block
  a helper from running, and the gaps that are only warnings. A gap answered by
  the user has to come back in through ordinary ingestion and governance; there
  is no path here that turns an answer directly into knowledge.
  """
  def check_readiness(attrs, identity_actor \\ nil) do
    attrs = attrs |> normalize_attrs() |> put_identity_actor(identity_actor)

    case identity_actor(attrs) do
      %Actor{} = actor -> Skills.check_readiness(actor, attrs)
      nil -> raise ArgumentError, "an authenticated identity actor is required"
    end
  end

  # Auto-provisioning for the internal ingest path only: a caller that gives no
  # display name gets its key as the name. Peers born here are recorded as human,
  # because an agent Peer is created deliberately when its machine credential is
  # issued, not as a side effect of someone ingesting a message.
  defp ensure_peer!(account_id, actor, key, nil),
    do: ensure_peer!(account_id, actor, key, key)

  defp ensure_peer!(account_id, actor, key, name) do
    create!(
      Peer,
      :ensure,
      %{key: key, name: name, kind: "human"},
      account_id,
      actor
    )
  end

  # An authenticated caller always speaks as its own Peer; a `"peer_key"` in the
  # request body is ignored on this path, so nobody can post observations under
  # someone else's name. The role grants are re-resolved instead of reused from
  # authentication because the scope being written to may have been created a few
  # lines earlier in this very request. The Peer row is loaded with an
  # Account-level system actor, since the caller's own scope grants are precisely
  # what is being recomputed and cannot be relied on yet.
  defp request_peer_and_actor!(account, %Actor{peer_id: peer_id} = actor, _attrs)
       when is_binary(peer_id) do
    system = Actor.for_account(account, role: :system)
    peer = read_one_by_id!(Peer, peer_id, account.id, system)

    refreshed_actor =
      RoleResolver.resolve(account, peer,
        identity_id: actor.identity_id,
        kind: actor.identity_kind,
        assurance: actor.assurance,
        api_key: %{scope_id: actor.credential_scope_id}
      )

    {peer, refreshed_actor}
  end

  # Internal callers (background work, the evaluation harness) carry no Peer, so
  # they name one by key and it is created on first use. They keep the
  # Account-level actor they already hold.
  defp request_peer_and_actor!(account, actor, attrs) do
    peer =
      ensure_peer!(
        account.id,
        actor,
        Map.fetch!(attrs, "peer_key"),
        Map.get(attrs, "peer_name")
      )

    {peer, actor}
  end

  # Creates every missing scope along the path and returns the deepest one.
  # The reduce carries the parent forward because a scope row needs its parent's
  # id, so the segments must be created outermost-first. `:ensure` is idempotent,
  # so a repeated ingest re-uses the existing rows rather than failing.
  defp ensure_scope!(account_id, actor, path) do
    path
    |> normalize_path()
    |> scope_segments()
    |> Enum.reduce(nil, fn {key, scope_path}, parent ->
      create!(
        Scope,
        :ensure,
        %{
          parent_id: parent && parent.id,
          key: key,
          name: key,
          path: scope_path,
          state: "active"
        },
        account_id,
        actor
      )
    end)
  end

  defp ensure_session!(account_id, actor, scope_id, peer_id, external_id) do
    create!(
      Session,
      :ensure,
      %{
        scope_id: scope_id,
        peer_id: peer_id,
        external_id: external_id,
        status: "open",
        opened_at: Clock.utc_now()
      },
      account_id,
      actor
    )
  end

  defp ensure_session_scope!(account_id, actor, session_id, scope_id) do
    create!(
      SessionScope,
      :ensure,
      %{
        session_id: session_id,
        scope_id: scope_id,
        classification: "confirmed",
        confirmed_at: Clock.utc_now()
      },
      account_id,
      actor
    )
  end

  defp ensure_session_participant!(account_id, actor, session_id, peer_id) do
    create!(
      SessionParticipant,
      :ensure,
      %{
        session_id: session_id,
        peer_id: peer_id,
        role: "participant",
        joined_at: Clock.utc_now()
      },
      account_id,
      actor
    )
  end

  # Builds the extractor's input: the raw message plus the surrounding facts it
  # needs to attribute a statement — who spoke (peer key), where it was said
  # (scope path), and every Peer key in the Account, so the model can only name a
  # peer that actually exists.
  defp fetch_message!(account, actor, message_id) do
    message =
      Message
      |> Ash.Query.filter(id == ^message_id)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read_one!(actor: actor)

    scope = read_one_by_id!(Scope, message.scope_id, account.id, actor)

    window_messages =
      Message
      |> Ash.Query.filter(
        session_id == ^message.session_id and scope_id == ^message.scope_id and
          occurred_at <= ^message.occurred_at
      )
      |> Ash.Query.sort(occurred_at: :desc, inserted_at: :desc)
      |> Ash.Query.limit(@extraction_window_size)
      |> Ash.Query.set_tenant(account.id)
      |> Ash.read!(actor: actor)
      |> Enum.sort_by(&{&1.occurred_at, &1.inserted_at, &1.id})
      |> Enum.map(&message_with_peer_key(&1, account.id, actor))

    message
    |> message_with_peer_key(account.id, actor)
    |> Map.merge(%{
      "scope_path" => scope.path,
      "account_key" => account.key,
      "known_peer_keys" => known_peer_keys(account.id, actor),
      "window_messages" => window_messages
    })
  end

  defp message_with_peer_key(message, account_id, actor) do
    peer = read_one_by_id!(Peer, message.peer_id, account_id, actor)
    record_to_map(message) |> Map.put("peer_key", peer.key)
  end

  # The surrounding identifiers the extractor needs for validation and provenance. Built in
  # the read phase and carried across the model call, so nothing downstream has to go back to
  # the database to learn who spoke or where.
  #
  # `source_peer_id` is who spoke. Who each extracted statement is *about* is resolved
  # separately per item in the write phase, because a peer may speak about someone else.
  defp message_context(account, actor, message) do
    %{
      account_id: account.id,
      scope_id: message["scope_id"],
      peer_id: message["peer_id"],
      source_peer_id: message["peer_id"],
      message_id: message["id"],
      window_messages: message["window_messages"],
      window_message_ids: Enum.map(message["window_messages"], & &1["id"]),
      actor: actor
    }
  end

  # The model call and the write that follows it, with no transaction spanning both.
  #
  # This split is not stylistic. A transaction owns a pooled database connection for its whole
  # duration, and an extraction can spend minutes in the provider across repair attempts.
  # Holding a connection that long exceeds DBConnection's checkout-ownership timeout, which
  # closes the connection mid-transaction and discards the write that would have recorded a
  # call that already happened and was already billed. So the caller reads in one short
  # transaction, this function calls the model holding nothing, and the write opens a second
  # short transaction. Do not reunite them.
  #
  # A provider failure short-circuits without stamping the message, so the reconciler finds it
  # again. Stamping happens only after every knowledge row is written, so a crash part-way
  # re-runs the work rather than losing it. The duplicate check and the advisory lock live in
  # the write phase and still serialize concurrent writers, exactly as they did when all of
  # this shared one transaction.
  defp extract_then_write(account_id, message_id, message, context) do
    with {:ok, items} <- Extractor.extract(message, context) do
      Observability.set_attribute(:memory, "memhouse.extract.item_count", length(items))

      DataLayer.with_account_id(
        account_id,
        [role: :system, pipeline?: true],
        fn account, actor ->
          knowledge = Enum.map(items, &insert_knowledge!(account.id, actor, message, &1))
          mark_message_extracted!(account.id, actor, message_id)
          {:ok, knowledge}
        end
      )
    end
  end

  # The single place where extracted knowledge becomes durable. Two outcomes are
  # possible: a brand-new proposal, or corroboration of an item that already says
  # the same thing about the same subject in the same scope.
  defp insert_knowledge!(account_id, actor, message, item) do
    subject = resolve_subject!(account_id, actor, message, item)
    statement_hash = Idempotency.content_hash(item.statement)

    # Transaction-scoped advisory lock over Account, scope, subject, and statement
    # hash. Without it, two concurrent extractions of the same sentence would both
    # miss the duplicate check below and write two competing knowledge rows.
    Lock.acquire!(
      account_id,
      "knowledge:#{message["scope_id"]}:#{subject.lock_key}:#{statement_hash}"
    )

    # Only live states count as a duplicate. A rejected or expired item must not
    # silently absorb a fresh observation — that sentence deserves a new proposal
    # and a new gate decision.
    existing =
      KnowledgeItem
      |> Ash.Query.filter(
        scope_id == ^message["scope_id"] and statement_hash == ^statement_hash and
          state in ["active", "proposed", "provisional", "held", "needs_revalidation"]
      )
      |> knowledge_subject_filter(subject)
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    {knowledge, created?} =
      if existing do
        # Corroboration path. The statement itself is immutable and the merge
        # action refuses to touch it, so only provenance breadth, the best
        # confidence seen so far, and the corroboration count move. A
        # document-sourced observation records its origin through a provenance
        # row instead, so it never enters the message id list.
        source_message_ids =
          if source_type(message) == "message" do
            Enum.uniq(existing.source_message_ids ++ item.source_message_ids)
          else
            existing.source_message_ids
          end

        knowledge =
          existing
          |> Ash.Changeset.for_update(:merge_from_pipeline, %{
            source_message_ids: source_message_ids,
            confidence: max(existing.confidence, item.confidence),
            corroboration_count: existing.corroboration_count + 1
          })
          |> Ash.Changeset.set_tenant(account_id)
          |> Ash.update!(actor: actor)

        {knowledge, false}
      else
        # New knowledge always starts unverified and merely proposed. Nothing here
        # may create an active statement; only the gate evaluation below can move
        # it, and it may equally leave it held for a human curator. The extracting
        # provider, model, version, prompt, and pipeline identities are stored on
        # the row so any statement can be traced back to what produced it.
        knowledge =
          create!(
            KnowledgeItem,
            :create_from_pipeline,
            %{
              scope_id: message["scope_id"],
              subject_peer_id: subject.peer_id,
              subject_scope_id: subject.scope_id,
              statement: item.statement,
              kind: item.kind,
              confidence: item.confidence,
              evidence_level: item.evidence_level,
              sensitivity: item.sensitivity,
              state: "proposed",
              target_level: item.target_level,
              verification: "pending",
              source_message_ids:
                if(source_type(message) == "message", do: item.source_message_ids, else: []),
              expires_at: item.expires_at,
              revalidate_after: item.revalidate_after,
              relevant_from: item.relevant_from,
              relevant_until: item.relevant_until,
              # Dates an event the model left undated. Nothing else reads it.
              observed_at: message["occurred_at"],
              extracting_provider: item.provider,
              extracting_model: item.model,
              extracting_model_version: item.model_version,
              prompt_version: item.prompt_version,
              pipeline_version: item.pipeline_version
            },
            account_id,
            actor
          )

        {knowledge, true}
      end

    attribution = ensure_attribution!(account_id, actor, knowledge, message, item, subject)

    ensure_provenance!(account_id, actor, knowledge, message, item)

    # Creation-only. A replayed extraction that merged into an existing item must
    # not append a second creation event or second audit entries, or the history
    # would claim the same item was created twice.
    if created? do
      # `reason` is a stored marker meaning "the pipeline proposed this". It is
      # read back by audits and regression tests, so changing the string rewrites
      # how already-recorded history reads.
      create!(
        LifecycleEvent,
        :record,
        %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          to_state: knowledge.state,
          reason: "f4_pipeline_proposed",
          occurred_at: Clock.utc_now()
        },
        account_id,
        actor
      )

      # Audit carries the statement's hash, never the statement. Metadata is
      # limited to ids and enumerated values for the same reason: the audit chain
      # must stay readable by an operator who may not read the content itself.
      Audit.append!(actor, account_id, %{
        scope_id: knowledge.scope_id,
        category: "lifecycle",
        action: "knowledge.created",
        resource_type: "knowledge_item",
        resource_id: knowledge.id,
        content_hash: statement_hash,
        metadata: %{"to_state" => knowledge.state}
      })

      Audit.append!(actor, account_id, %{
        scope_id: knowledge.scope_id,
        actor_peer_id: message["peer_id"],
        category: "attribution",
        action: "attribution.created",
        resource_type: "attribution",
        resource_id: attribution.id,
        content_hash: statement_hash,
        metadata: %{"knowledge_item_id" => knowledge.id, "level" => subject.level}
      })
    end

    # The gate runs once, at creation. Corroborating an existing item must never
    # re-open a decision a curator has already made about it.
    knowledge = if created?, do: Engine.evaluate_proposal(knowledge, actor), else: knowledge
    record_to_map(knowledge)
  end

  # Stamping the completion time closes the message for the reconciler, which
  # re-enqueues extraction for any raw message that never finished.
  defp mark_message_extracted!(account_id, actor, message_id) do
    message = read_one_by_id!(Message, message_id, account_id, actor)

    message
    |> Ash.Changeset.for_update(:mark_extracted, %{
      extraction_completed_at: Clock.utc_now()
    })
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.update!(actor: actor)
  end

  # Provenance is append-only, one row per knowledge item and source. Replaying an
  # extraction finds the existing row instead of appending a duplicate, which
  # matters because erasure and supersession count independent sources to decide
  # whether a statement still has any surviving reason to exist.
  defp ensure_provenance!(account_id, actor, knowledge, message, item) do
    if source_type(message) == "message" do
      Enum.each(item.source_message_ids, fn message_id ->
        ensure_provenance_source!(account_id, actor, knowledge, "message", message_id, item)
      end)
    else
      ensure_provenance_source!(account_id, actor, knowledge, "document", message["id"], item)
    end
  end

  defp ensure_provenance_source!(account_id, actor, knowledge, source_type, source_id, item) do
    query =
      Provenance
      |> Ash.Query.filter(knowledge_item_id == ^knowledge.id and source_type == ^source_type)
      |> provenance_source_filter(source_type, source_id)

    existing =
      query
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    existing ||
      create!(
        Provenance,
        :create_from_pipeline,
        %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          source_type: source_type,
          message_id: if(source_type == "message", do: source_id),
          document_version_id: if(source_type == "document", do: source_id),
          extracting_provider: item.provider,
          extracting_model: item.model,
          extracting_model_version: item.model_version,
          prompt_version: item.prompt_version,
          pipeline_version: item.pipeline_version,
          occurred_at: Clock.utc_now()
        },
        account_id,
        actor
      )
  end

  # A provenance row points at exactly one kind of origin, so the duplicate check
  # has to compare the column matching that kind.
  defp provenance_source_filter(query, "message", id),
    do: Ash.Query.filter(query, message_id == ^id)

  defp provenance_source_filter(query, "document", id),
    do: Ash.Query.filter(query, document_version_id == ^id)

  # Observations default to messages; only the document path tags itself.
  defp source_type(message), do: Map.get(message, "source_type", "message")

  # One attribution per knowledge item, subject, and level. Idempotent for the
  # same reason as provenance: a replay must not multiply the rows that say who a
  # statement is about.
  defp ensure_attribution!(account_id, actor, knowledge, _message, _item, subject) do
    existing =
      Attribution
      |> Ash.Query.filter(
        knowledge_item_id == ^knowledge.id and target_type == ^subject.type and
          level == ^subject.level
      )
      |> attribution_subject_filter(subject)
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    existing ||
      create!(
        Attribution,
        :create_from_pipeline,
        %{
          knowledge_item_id: knowledge.id,
          scope_id: knowledge.scope_id,
          target_type: subject.type,
          target_peer_id: subject.peer_id,
          target_scope_id: subject.scope_id,
          level: subject.level
        },
        account_id,
        actor
      )
  end

  # Records how many items an extraction produced and passes the result through
  # untouched, so a provider failure still reaches the caller as an error tuple
  # that the durable job can retry on.
  defp record_extraction_result({:ok, knowledge}) do
    Observability.set_attribute(:memory, "memhouse.knowledge.created_count", length(knowledge))
    {:ok, knowledge}
  end

  defp record_extraction_result({:error, error}), do: {:error, error}

  # The extractor may only name a peer that already exists, so it is handed the
  # Account's full key list. Sorted so the prompt is byte-stable between runs,
  # which keeps recorded evaluation runs reproducible.
  defp known_peer_keys(account_id, actor) do
    Peer
    |> Ash.Query.sort(key: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.key)
  end

  # Who a statement is about, resolved independently of who said it. The returned
  # map also carries the `lock_key` fragment used to serialize concurrent writes
  # about the same subject.
  #
  # `level` records how direct the claim is. It is "self" only when the subject
  # is the speaker. Everything else is "hearsay". Derive this relationship from
  # durable identities so a model label cannot change governance behavior.
  defp resolve_subject!(account_id, actor, message, %{subject_type: "peer"} = item) do
    peer =
      Peer
      |> Ash.Query.filter(key == ^item.subject_ref)
      |> Ash.Query.limit(1)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    # A subject the model invented fails the whole extraction rather than being
    # quietly re-attributed to the speaker: knowledge filed under the wrong person
    # is worse than no knowledge at all.
    if is_nil(peer), do: raise(ArgumentError, "structured extraction referenced an unknown peer")

    level = if peer.id == message["peer_id"], do: "self", else: "hearsay"

    %{type: "peer", peer_id: peer.id, scope_id: nil, level: level, lock_key: "peer:#{peer.id}"}
  end

  # A scope subject may only be the scope the observation happened in, so an
  # extraction cannot write knowledge into a scope the speaker was not part of.
  defp resolve_subject!(_account_id, _actor, message, %{subject_type: "scope"} = item) do
    if item.subject_ref != message["scope_path"] do
      raise ArgumentError, "structured extraction referenced an unknown scope"
    end

    %{
      type: "scope",
      peer_id: nil,
      scope_id: message["scope_id"],
      level: "scope",
      lock_key: "scope:#{message["scope_id"]}"
    }
  end

  # Exactly one subject column is ever set. Both halves of each filter matter: a
  # statement about a peer and a statement about a scope can share a text and a
  # hash, and matching on only one column would merge two different claims.
  defp knowledge_subject_filter(query, %{type: "peer", peer_id: peer_id}) do
    Ash.Query.filter(query, subject_peer_id == ^peer_id and is_nil(subject_scope_id))
  end

  defp knowledge_subject_filter(query, %{type: "scope", scope_id: scope_id}) do
    Ash.Query.filter(query, is_nil(subject_peer_id) and subject_scope_id == ^scope_id)
  end

  # Same one-column-set rule as the knowledge filter, applied to attribution rows.
  defp attribution_subject_filter(query, %{type: "peer", peer_id: peer_id}) do
    Ash.Query.filter(query, target_peer_id == ^peer_id and is_nil(target_scope_id))
  end

  defp attribution_subject_filter(query, %{type: "scope", scope_id: scope_id}) do
    Ash.Query.filter(query, is_nil(target_peer_id) and target_scope_id == ^scope_id)
  end

  # Context flows downward: a request for one scope path reads that scope and
  # every ancestor along the path, so knowledge written high in the tree is
  # visible in everything beneath it, while a sibling scope stays invisible.
  #
  # The read runs under the caller's own actor, so ancestors the caller has no
  # role in are dropped by policy rather than filtered here. Results come back
  # longest path first, which is the order a nearest-scope-wins reader expects.
  defp visible_scopes(account_id, actor, path, include_cross_links? \\ false) do
    ancestor_paths = path |> normalize_path() |> ancestor_paths()

    scopes =
      Scope
      |> Ash.Query.filter(path in ^ancestor_paths)
      |> Ash.Query.sort(path: :desc)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read!(actor: actor)

    # Cross-links are opt-in and never widen authorization: the relation rows and
    # the linked scopes are both read under the caller's actor, so an endpoint the
    # caller cannot reach simply does not come back. A link is a hint about where
    # else to look, not a grant.
    if include_cross_links? do
      scope_ids = Enum.map(scopes, & &1.id)

      linked_ids =
        MemHouse.Topology.ScopeRelation
        |> Ash.Query.filter(source_scope_id in ^scope_ids or target_scope_id in ^scope_ids)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)
        |> Enum.flat_map(&[&1.source_scope_id, &1.target_scope_id])
        |> Enum.uniq()

      linked =
        Scope
        |> Ash.Query.filter(id in ^linked_ids)
        |> Ash.Query.set_tenant(account_id)
        |> Ash.read!(actor: actor)

      (scopes ++ linked)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&String.length(&1.path), :desc)
    else
      Enum.sort_by(scopes, &String.length(&1.path), :desc)
    end
  end

  defp read_one_by_id!(resource, id, account_id, actor) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read_one!(actor: actor)
  end

  # Every durable write in this module goes through here so two things are always
  # set before the action runs: the tenant, which pins the Account for Ash
  # multitenancy, and the MemHouse actor in the changeset context, which the
  # after-action changes (audit chaining and job enqueue) fall back to when the
  # action's own context does not carry an actor.
  defp create!(resource, action, attrs, account_id, actor) do
    resource
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_tenant(account_id)
    |> Ash.Changeset.set_context(%{memhouse_actor: actor})
    |> Ash.Changeset.for_create(action, attrs)
    |> Ash.create!(actor: actor)
  end

  # Account selection, most trusted source first. Only a real `MemHouse.Actor`
  # struct matches the first clause, and decoded JSON can never produce a struct,
  # so a request body cannot smuggle an identity in under this key. The key and id
  # clauses are internal adapters for background work and evaluation runs. The
  # final clause refuses instead of defaulting to some Account, because guessing
  # here would breach the isolation wall between Accounts.
  defp with_account(%{"_memhouse_actor" => %Actor{} = actor}, fun),
    do: DataLayer.with_actor(actor, fun)

  defp with_account(%{"account_key" => key}, fun) when is_binary(key),
    do: DataLayer.with_account_key(key, fun)

  defp with_account(%{"account_id" => id}, fun) when is_binary(id),
    do: DataLayer.with_account_id(id, fun)

  defp with_account(_filters, _fun) do
    raise ArgumentError,
          "an authenticated identity actor or internal account adapter is required"
  end

  # Overwrites any inbound value under this key, so an authenticated call always
  # runs as the actor the request edge resolved and never as anything the payload
  # happened to contain.
  defp put_identity_actor(attrs, %Actor{} = actor),
    do: Map.put(attrs, "_memhouse_actor", actor)

  defp put_identity_actor(attrs, _actor), do: attrs

  # Visibility rule for the default listing. Provisional knowledge is usable only
  # by the peer it is about, so an authenticated caller sees active items plus its
  # own provisional ones. An internal actor with no peer (jobs, evaluation runs)
  # sees every provisional item. Any explicitly requested state matches exactly,
  # with no provisional widening.
  defp knowledge_read_query(scope_ids, "active", %{peer_id: peer_id})
       when is_binary(peer_id) do
    KnowledgeItem
    |> Ash.Query.filter(
      scope_id in ^scope_ids and
        (state == "active" or (state == "provisional" and subject_peer_id == ^peer_id))
    )
  end

  defp knowledge_read_query(scope_ids, "active", _actor) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state in ["active", "provisional"])
  end

  defp knowledge_read_query(scope_ids, state, _actor) do
    KnowledgeItem
    |> Ash.Query.filter(scope_id in ^scope_ids and state == ^state)
  end

  defp ingest_run_status(%{extraction_completed_at: completed_at}, _run)
       when not is_nil(completed_at),
       do: "completed"

  defp ingest_run_status(_message, %{status: "failed"}), do: "failed"
  defp ingest_run_status(_message, _run), do: "pending"

  defp read_ingest_status(account_id, actor, message_id) do
    message =
      Message
      |> Ash.Query.filter(id == ^message_id)
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    if message do
      {:ok, ingest_status_map(account_id, actor, message)}
    else
      {:error, :not_found}
    end
  end

  defp ingest_status_map(account_id, actor, message) do
    run =
      PipelineRun
      |> Ash.Query.for_read(:ingest_status, %{message_id: message.id})
      |> Ash.Query.set_tenant(account_id)
      |> Ash.read_one!(actor: actor)

    %{
      "status" => ingest_run_status(message, run),
      "extraction_completed_at" => message.extraction_completed_at,
      "knowledge" => ingest_status_knowledge(account_id, actor, message),
      "last_error_class" => run && run.last_error_class,
      "attempt_count" => (run && run.attempt_count) || 0
    }
  end

  defp ingest_status_knowledge(_account_id, _actor, %{extraction_completed_at: nil}), do: []

  defp ingest_status_knowledge(account_id, actor, message) do
    [message.scope_id]
    |> knowledge_read_query("active", actor)
    |> Ash.Query.filter(^message.id in source_message_ids)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.set_tenant(account_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(&record_to_map/1)
  end

  defp identity_actor(%{"_memhouse_actor" => %Actor{} = actor}), do: actor
  defp identity_actor(_attrs), do: nil

  # The serialization boundary of this module: only attributes the resource marks
  # public ever leave. Internal columns such as the Account id and content hashes
  # are absent by construction, which also means that marking a new resource
  # attribute public publishes it on the API in the same commit.
  defp record_to_map(record) do
    record.__struct__
    |> Ash.Resource.Info.public_attributes()
    |> Enum.map(& &1.name)
    |> then(&Map.take(record, &1))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  # Percent. Below this the model's own stated probability is too low to present
  # its inference as a conclusion, so the answer abstains while keeping its text
  # and citations. Applies only to model answers: the model-free paths assert
  # nothing of their own to be unsure about.
  @inference_abstain_below 50

  # The one reply that is not an attempt at the question. The model is told
  # never to refuse, so this text is reachable only when no retrieved statement
  # survived to ground an answer on, which is a state of the index rather than
  # an answer about the subject.
  @no_evidence_answer "No memory statements were retrieved for this question."

  # Percent. What a concatenation of the top retrieved statements is worth: real
  # evidence, but not an inference anyone made, so it sits below the threshold
  # without being zero.
  @fallback_confidence 40

  # Nothing retrieved means nothing to ground an answer in, so abstain without
  # spending a model call.
  defp answer_question(_attrs, question, []), do: {fallback_answer(question, []), false}

  defp answer_question(attrs, question, candidates) do
    # Only the identity resolution and the role lookup need a transaction. The answering call
    # itself is made outside it: generating a grounded answer is the slowest model call in a
    # request, and a transaction spanning it would hold a pooled database connection past what
    # the pool allows, on a request that has already finished reading.
    {context, config} =
      with_account(attrs, fn account, actor ->
        # The answering model role is resolved against a scope, so the top-ranked
        # candidate's scope stands in for "where this question is being asked".
        context = %{
          account_id: account.id,
          scope_id: candidates |> List.first() |> Map.get("scope_id"),
          peer_id: actor.peer_id,
          actor: actor
        }

        {context, MemHouse.Model.role_config(:dialectic_agent, context)}
      end)

    provider = MemHouse.Model.Gateway.provider_module(config, context)

    # A deployment whose answering role is still the built-in deterministic
    # provider, with no real provider injected, answers from the retrieved
    # statements instead of pretending to reason.
    if MemHouse.Model.Config.local_fallback?(config) and
         is_nil(provider_override(provider)) do
      {fallback_answer(question, candidates), false}
    else
      {model_answer(question, candidates, context), true}
    end
  end

  # Builds the grounded question prompt and validates what comes back.
  #
  # Every statement is prefixed with its knowledge id so the model can cite by id,
  # and nothing beyond the retrieved statements and their validity windows enters
  # the prompt — the model is never given free rein over the Account's memory. The
  # call goes through the model gateway rather than a provider directly, which is
  # what keeps usage accounting, provenance, and provider choice in one place.
  defp model_answer(question, candidates, model_context) do
    memory_context =
      candidates
      |> Enum.map_join("\n", fn row ->
        "[#{row["id"]}] #{Statement.with_validity(row["statement"], row["relevant_from"], row["relevant_until"])}"
      end)

    prompt = """
    Answer the question using only the cited MemHouse memory statements.
    Return JSON: {"answer":"...", "citations":["knowledge-id"], "abstained":false, "answer_confidence":0}.
    answer_confidence is your own probability, an integer from 0 to 100, that the answer you gave is correct.

    Always give your best answer. Never reply "not known", "unknown", "no information available", or "cannot answer": state what the statements make most probable and let answer_confidence carry your uncertainty.

    1. If a statement states the answer, give it and set answer_confidence high.
    2. If no statement states the answer, infer the most probable one from the statements, use an explicit likelihood word, and set answer_confidence to how probable it is.
    3. If the statements barely bear on the question, still give the most probable answer they allow and set answer_confidence low, near 0.

    Cite every statement your answer rests on, including a low-confidence one. An answer with no surviving citation is discarded.

    A statement may be followed by "(true from ...)" or "(true from ... until ...)": when the claim held. Use it to date an answer whose statement says only "last weekend" or "yesterday". Do not date such a phrase from today's date.

    A statement may be followed by "(true from ...)" or "(true from ... until ...)": when the claim held. Use it to date an answer whose statement says only "last weekend" or "yesterday". Do not date such a phrase from today's date.

    Question: #{question}

    Memory:
    #{memory_context}
    """

    result =
      MemHouse.Model.generate_structured(
        :dialectic_agent,
        [
          %{role: "system", content: "You are a grounded memory QA engine."},
          %{role: "user", content: prompt}
        ],
        MemHouse.Model.Schema.DialecticAnswer,
        model_context,
        task: :dialectic
      )

    case result do
      {:ok, decoded, _provenance} ->
        # Second grounding check. The model was shown only these statements, but
        # nothing stops it from returning an id it invented, so every citation is
        # intersected with what was actually retrieved.
        cited_ids = candidates |> MapSet.new(& &1["id"])
        citations = Enum.filter(decoded.citations, &MapSet.member?(cited_ids, &1))

        # An answer with no surviving citation is unsupported prose, whatever
        # the model claimed about certainty, so it is replaced rather than
        # returned uncited. With grounding intact, abstention remains an
        # independent admission that the evidence supports the qualified text
        # without establishing a conclusion.
        if citations == [] do
          fallback_answer(question, [])
        else
          # The model may always abstain; below the threshold it no longer gets
          # to claim the opposite. An inference it is itself unsure of is
          # returned with its statements and its number, not as a conclusion.
          %{
            "answer" => decoded.answer,
            "citations" => citations,
            "abstained" =>
              decoded.abstained or decoded.answer_confidence < @inference_abstain_below,
            "answer_confidence" => decoded.answer_confidence
          }
        end

      # A provider error degrades to the retrieved statements. It does not retry
      # with a different provider, and it does not raise: the caller still gets a
      # cited, if blunt, answer.
      {:error, _error} ->
        fallback_answer(question, candidates)
    end
  end

  # The deterministic provider is the built-in default, not a deliberate choice,
  # so it does not count as an override. Only a real provider module injected
  # through configuration or call context does.
  defp provider_override(MemHouse.Model.Providers.Deterministic), do: nil
  defp provider_override(provider), do: provider

  # Model-free answers. With no grounded statement to stand on the reply reports
  # that state rather than guessing, because the answering contract is that
  # every answer rests on retrieved knowledge and there is none here; with
  # candidates, the highest-ranked statements are concatenated and each one is
  # cited, so even the fallback answer stays traceable to the knowledge it came
  # from.
  defp fallback_answer(_question, []),
    do: %{
      "answer" => @no_evidence_answer,
      "citations" => [],
      "abstained" => true,
      "answer_confidence" => 0
    }

  defp fallback_answer(_question, candidates) do
    # Four statements: enough to cover a typical question while keeping the reply
    # short enough to read.
    top = Enum.take(candidates, 4)

    %{
      "answer" => Enum.map_join(top, " ", & &1["statement"]),
      "citations" => Enum.map(top, & &1["id"]),
      "abstained" => false,
      "answer_confidence" => @fallback_confidence
    }
  end

  # Anything unrecognized widens to every target rather than failing, because the
  # value may arrive from request params on the general search path.
  # The same rule the console applies before rendering the controls, restated
  # here because the console is a caller rather than the authority: retrieval
  # internals are for a person who signed in with a password and administers the
  # Account, never for a machine credential holding the same role.
  defp diagnostic_actor?(%Actor{identity_kind: :password, role: :account_admin}), do: true
  defp diagnostic_actor?(%Actor{}), do: false

  defp diagnostic_report(%DiagnosticGrant{} = grant, result) do
    contributed = Map.get(result, "contributed_strategies", [])
    candidates = Map.get(result, "candidates", [])

    grant
    |> DiagnosticGrant.to_map()
    |> Map.merge(%{
      "query_dependent_strategies" =>
        Enum.filter(contributed, &Profile.module(&1).query_dependent?()),
      "default_limit" => @default_limit,
      "beyond_default_limit" => max(length(candidates) - @default_limit, 0)
    })
  end

  # Only a struct counts. A string-keyed map decoded from a request body reaches
  # the same facade, and treating one as a grant would hand any caller the
  # internal retrieval seam.
  defp diagnostic_grant(%{"_diagnostic" => %DiagnosticGrant{} = grant}), do: grant
  defp diagnostic_grant(_filters), do: nil

  defp retrieval_target("knowledge"), do: :knowledge
  defp retrieval_target("documents"), do: :documents
  defp retrieval_target(:knowledge), do: :knowledge
  defp retrieval_target(:documents), do: :documents
  defp retrieval_target(_target), do: :all

  # Only the top level. The candidate maps underneath already carry string keys
  # from retrieval, and walking them again would rebuild every row for nothing.
  defp stringify_top_level(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # Callers arrive in both shapes: request params are string-keyed, internal
  # callers and tests use atoms. Everything downstream reads string keys only.
  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  # "/poc" is the scope path used when a request names none, when it names the
  # bare root, or when it sends something that is not a string. It is a historical
  # default that existing deployments, recorded evaluation fixtures, and the
  # frozen request contract all depend on: changing it moves where unlabelled
  # observations land, so it is a deliberate behaviour change, not tidying.
  #
  # A path missing its leading slash gets one, so "team/x" and "/team/x" name the
  # same scope instead of creating two.
  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> case do
      "" -> "/poc"
      "/" -> "/poc"
      "/" <> _ = normalized -> normalized
      normalized -> "/" <> normalized
    end
  end

  defp normalize_path(_path), do: "/poc"

  # Pairs each path segment with its full path, outermost first: "/a/b" becomes
  # [{"a", "/a"}, {"b", "/a/b"}]. Scope creation needs the pairs to build parents
  # before children; ancestor lookup needs the paths.
  defp scope_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce({[], []}, fn segment, {parts, acc} ->
      parts = parts ++ [segment]
      {parts, acc ++ [{segment, "/" <> Enum.join(parts, "/")}]}
    end)
    |> elem(1)
  end

  # Every path from the outermost scope down to the requested one — exactly the
  # set a downward-inheriting read has to include.
  defp ancestor_paths(path) do
    path
    |> scope_segments()
    |> Enum.map(fn {_segment, segment_path} -> segment_path end)
  end

  # A missing or unusable event time becomes "now" instead of rejecting the
  # observation: clients often have no reliable clock, and the row's own insertion
  # timestamp still records when the system learned of it.
  #
  # An offsetless timestamp is read as UTC rather than discarded. `DateTime.from_iso8601/1`
  # alone rejects one, and the fallback below would then stamp a backfilled turn with the
  # ingest instant — silently, and with a plausible-looking value. Offsetless is the default
  # output of common clients, so the strict-only path lost the true time of most backfills.
  defp coerce_datetime!(nil), do: Clock.utc_now()
  defp coerce_datetime!(%DateTime{} = datetime), do: datetime

  defp coerce_datetime!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> naive_utc(value) || Clock.utc_now()
    end
  end

  defp coerce_datetime!(_value), do: Clock.utc_now()

  defp naive_utc(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:error, _reason} -> nil
    end
  end

  # Query-string values arrive as strings. A value that is not cleanly numeric
  # falls back to the default (or to no filter) rather than failing the request;
  # these are all tuning knobs, not statements about what the caller may see.
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  # An absent or unparseable score floor means "no floor", not zero: zero would be
  # a real threshold and would silently change which candidates survive.
  defp parse_float(nil), do: nil
  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp parse_float(_value), do: nil

  # An absent or unparseable belief-time cutoff means "no cutoff", so a malformed
  # value widens the result rather than quietly pinning it to some arbitrary date.
  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
