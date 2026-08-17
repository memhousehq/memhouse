# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.MemoryController do
  @moduledoc """
  Serves probes, observation ingest, retrieval, context, readiness, and cost data as JSON.

  Health and readiness are public and content-safe. Every other route receives an actor
  whose Account was derived by the bearer-authentication pipeline, never request params.
  """

  use MemHouseWeb, :controller

  alias MemHouse.Memory
  alias MemHouse.Operations.Health
  alias MemHouse.Pipeline

  @doc """
  Liveness probe. Unauthenticated, and touches no database or queue.
  """
  def health(conn, _params) do
    json(conn, %{status: "ok", app: "memhouse", version: "f5-1"})
  end

  @doc """
  Readiness probe. Unauthenticated.
  """
  def ready(conn, _params) do
    result = Health.readiness()
    status = if Health.ready?(result), do: 200, else: 503
    conn |> put_status(status) |> json(result)
  end

  @doc """
  Account-wide usage, storage, and estimated-cost summary for the operator.

    Returns `%{"data" => summary}` holding the exact recorded usage-event count, API
    request and ingest counts, input/output/embedding token totals overall and per model
    role, durable and operational storage bytes, an estimated model cost in USD, and aggregate
    extractor calls, tokens, and cost per ingested message.
  """
  def costs(conn, _params) do
    actor = conn.assigns.current_actor

    if actor.role in [:account_admin, :system] do
      json(conn, %{data: MemHouse.Operations.Metering.summary(actor)})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    end
  end

  @doc """
  Enqueues a reconciliation sweep for the authenticated operator's Account.

  Returns 202 with the durable run id. Only account administrators and internal
  system actors may request the sweep; the Account never comes from parameters.
  """
  def reconcile(conn, _params) do
    actor = conn.assigns.current_actor

    if actor.role in [:account_admin, :system] do
      {:ok, run} = Pipeline.request_reconciliation(actor)

      conn
      |> put_status(:accepted)
      |> json(%{data: %{run_id: run.id, status: "accepted"}})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    end
  end

  @doc """
  Enqueues one immediate dream-time pass for the authenticated operator's Account.

  Returns 202 with the durable run id. Only account administrators and internal
  system actors may request model-backed maintenance work.
  """
  def dream(conn, _params) do
    actor = conn.assigns.current_actor

    if actor.role in [:account_admin, :system] do
      {:ok, run} = Pipeline.request_dream_time(actor)

      conn
      |> put_status(:accepted)
      |> json(%{data: %{run_id: run.id, status: "accepted"}})
    else
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    end
  end

  @doc """
  Records one raw observation. This is the only write path an agent has.

    Body fields: `session_id`, `scope_path`, and `content` are required; `role`
    defaults to `"user"`, and `occurred_at` is optional. Missing scopes, the
    session, and its scope/participant links are created on demand, so a client
    does not have to provision topology before speaking.

    Returns 202 with `%{"data" => %{"message_id" => id, "status" =>
    "accepted"}}` after the observation and extraction job commit. No model call
    runs in the request.

    Raises when a required field is absent, which surfaces as a server-error status
    rather than a partially written session.
  """
  def ingest(conn, params) do
    {:ok, message} =
      params
      |> Memory.ingest_message(conn.assigns.current_actor)

    conn
    |> put_status(:accepted)
    |> json(%{data: %{message_id: message["id"], status: "accepted"}})
  end

  @doc """
  Reports extraction status for one accepted observation.

  Returns pending, failed, or completed state with the completion timestamp,
  visible governed knowledge, the last content-safe error class, and the durable
  attempt count. A missing or unauthorized message returns 404.
  """
  def ingest_status(conn, %{"message_id" => message_id}) do
    case Memory.ingest_status(message_id, conn.assigns.current_actor) do
      {:ok, status} ->
        json(conn, %{data: Map.put(status, "message_id", message_id)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Not found"})
    end
  end

  @doc """
  Ranked retrieval over governed memory, with no answer generation.

    Body fields, all optional: `query` (defaults to the empty string), `scope_path`
    (defaults to `"/poc"`), `profile` (defaults to `"balanced"`), `limit` (defaults to
    12 candidates), `include_cross_links`, `as_of`, `min_score`, `source_filters`, and
    `deadline` — send `"disabled"` to drop the retrieval time budget, which only makes
    sense offline.

    Returns `%{"data" => result}` carrying the profile name, the retrieval contract
    identity in `profile_version` (`"f7-1"` here, naming the retrieval and context
    behaviour a client is written against — bumping it is a versioned contract
    transition owing a changelog entry, not a cosmetic edit), the fused `candidates`,
    and which strategies contributed or were dropped. Account, authorized-scope,
    lifecycle, and source filtering all happen inside retrieval before candidates
    surface here, so this action never has to post-filter.
  """
  def search(conn, params) do
    result =
      params
      |> Memory.search(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  @doc """
  Searches immutable source messages for grounded recovery and citation.

  Body fields: `query`, `scope_path`, `mode` (`exact` or `semantic`), `limit`,
  `excerpt_chars`, `peer_key`, and `include_cross_links`. Account and scope
  authority come only from the authenticated actor. The response exposes
  bounded excerpts and stable source metadata, never an unbounded transcript
  or a hidden corpus count.
  """
  def source_search(conn, params) do
    result = Memory.search_sources(params, conn.assigns.current_actor)
    json(conn, %{data: result})
  end

  @doc """
  Retrieves supporting memory and answers a natural-language question over it.

    Body: `question` is required; every `search/2` parameter is also accepted. `profile`
    defaults to `"thorough"` rather than `"balanced"`, because an answer justifies more
    latency than a bare search.

    Returns `%{"data" => result}`: the search payload merged with `answer`, `citations`,
    `abstained`, `answer_confidence`, `answer_degraded`, `answer_context_count`, and
    `answerer_prompt_tokens`. The answer is grounded in a bounded final-ranked head of the
    returned candidates — when nothing supports the question the action abstains instead of
    inventing one, so treat `abstained == true` as an ordinary outcome and not an error.
    `answer_confidence` is a 0-100 percentage; a model answer below the abstention
    threshold abstains regardless of what the model claimed. `answer_degraded` is `nil`
    unless the model call itself failed, in which case it names the failure class and
    `supporting_statements` carries the retrieved statements the (absent) answer would have
    been grounded on.
  """
  def ask(conn, params) do
    result =
      params
      |> Memory.ask(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  @doc """
  Assembles the context projection for a scope, without reasoning.

    Body: `scope_path` (defaults to `"/poc"`), an optional `session_id` to pick the
    session summary, and an optional `budget_chars` that caps the assembled size.

    Returns `%{"data" => context}` with `knowledge`, `session_summary`, `scope_cards`,
    `entity_cards`, `peer_profile`, the context contract identity in `profile_version`, and two
    diagnostic flags: `projection_cache_hit` says a stored projection was reused,
    `fast_fallback` says the projection was missing and the fastest retrieval profile
    filled in live.
  """
  def context(conn, params) do
    result =
      params
      |> Memory.get_context(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  @doc """
  Reports whether a peer knows enough to run a named skill in a scope.

    Body: `skill` and `scope_path` are required. The peer defaults to the authenticated
    caller; `peer_id` or `peer_key` may name another peer the caller is allowed to read.

    Returns `%{"data" => report}` with the report contract identity in `report_version`
    (`"f9-1"`, naming the selector language and gap-report shape; changing it is a
    versioned contract transition), the resolved skill/peer/scope, a per-requirement
    `requirements` list, and the unsatisfied ones split into `blockers` and `warnings`.
    `ready` is true exactly when there are no blockers: required gaps block execution,
    preferred gaps warn.
  """
  def readiness(conn, params) do
    result =
      params
      |> Memory.check_readiness(conn.assigns.current_actor)

    json(conn, %{data: result})
  end

  @doc """
  Lists governed knowledge the caller is allowed to read.

    Returns `%{"data" => rows}`. This is a read-only view: there is deliberately no POST
    counterpart, so an agent that wants to record something has to go through
    observation ingest and let the pipeline and governance decide what becomes
    knowledge.
  """
  def knowledge(conn, params) do
    result =
      params
      |> Memory.query_knowledge(conn.assigns.current_actor)

    json(conn, %{data: result})
  end
end
