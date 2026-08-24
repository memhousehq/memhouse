# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleLive.KnowledgeDetail do
  @moduledoc """
  `/console/knowledge/:id` transparency and governance controls for one visible
  statement, including provenance, identities, lifecycle, relations, and
  supersession.

  The page is ordered by the questions a reader arrives with: what the statement
  says, what they may do about it, how current and trusted it is, where it sits,
  and what evidence produced it. Pipeline and gate metadata stay reachable
  behind one disclosure rather than competing with the claim itself.

  Curators decide queued items and request ancestor promotion; subjects confirm,
  contest, or redact only their own statements. Editing creates a governed
  replacement and preserves the original. Controls only aid presentation: every
  event delegates to governance operations, which reauthorize and own locks,
  transactions, decisions, lifecycle events, and audit records.

  Rendered statement and source text is browser-only. Never copy it into logs,
  telemetry, audit metadata, or job args.
  """

  use MemHouseWeb, :live_view

  import MemHouseWeb.ConsoleComponents

  alias MemHouse.Governance.Engine
  alias MemHouseWeb.Console.Access
  alias MemHouseWeb.Console.Loader

  # The explorer's filter keys. A return link is rebuilt from these alone, so a
  # hand-edited `back` value cannot name a destination outside the explorer.
  @filter_keys ~w(mode scope state kind sensitivity target_level subject page per_page sort q)

  @doc """
  Loads one statement, or renders the not-found state.

  Missing and unauthorized ids are indistinguishable to prevent existence
  probing.
  """
  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    {:ok,
     socket
     |> assign(:now, DateTime.utc_now())
     |> assign(:back, back_params(params["back"]))
     |> load(id)}
  end

  @doc """
  Delegates curator decisions, promotion requests, and subject verdicts.

  Refusals become generic flashes, and every attempt reloads committed state.
  """
  @impl true
  # Reject forged events on the not-found state before accessing the statement.
  def handle_event(_event, _params, %{assigns: %{detail: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "That action was refused. Nothing was changed.")}
  end

  def handle_event("decide", %{"action" => action} = params, socket) do
    # Blank optional fields mean absent, not an empty replacement value.
    opts =
      params
      |> Map.take(["statement", "merge_into_id", "defer_hours", "sensitivity"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    # Decisions require an open queue row; forged events fail closed.
    case socket.assigns.detail.validation do
      nil ->
        {:noreply, put_flash(socket, :error, "There is no open decision on this statement.")}

      validation ->
        guard(socket, "Decision recorded.", fn actor ->
          Engine.decide(actor, validation.id, action, opts)
        end)
    end
  end

  def handle_event("promote", %{"target_scope_id" => target_scope_id}, socket) do
    id = socket.assigns.detail.item.id

    guard(
      socket,
      "Promotion requested. It is held until the required review and consent finish.",
      fn actor ->
        Engine.request_promotion(actor, id, target_scope_id)
      end
    )
  end

  def handle_event("subject", %{"verdict" => verdict}, socket) do
    id = socket.assigns.detail.item.id

    guard(socket, "Recorded your verdict as the subject of this statement.", fn actor ->
      Engine.contest(actor, id, verdict)
    end)
  end

  @doc """
  Renders the statement, its evidence, its history, and the controls this
  reader is entitled to.
  """
  @impl true
  def render(%{detail: nil} = assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:knowledge} title="Statement not found" flash={@flash}>
      <.panel title="Nothing here" description="This id names no statement you can read.">
        <p>
          An id that does not exist and an id you are not entitled to see are reported
          identically, so that neither can be used to probe for the other.
        </p>
        <p><.link navigate={~p"/console/knowledge?#{@back}"}>Back to the explorer</.link></p>
      </.panel>
    </.shell>
    """
  end

  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:knowledge} title="Statement" flash={@flash}>
      <:actions>
        <.link navigate={~p"/console/knowledge?#{@back}"} class="ghost-link">← Back to the list</.link>
      </:actions>

      <section class="statement-card">
        <p class="statement">{@detail.item.statement}</p>

        <div class="badge-row">
          <.badge family="state" value={@detail.item.state} />
          <.badge family="kind" value={@detail.item.kind} />
          <.badge family="sensitivity" value={@detail.item.sensitivity} />
          <.badge family="level" value={@detail.item.target_level} />
        </div>

        <dl class="summary-facts">
          <div class="summary-fact">
            <dt>Scope</dt>
            <dd><.scope_crumb path={@detail.item.scope_path} id="summary-scope" /></dd>
          </div>
          <div class="summary-fact">
            <dt>Confidence</dt>
            <dd><.confidence_meter value={@detail.item.confidence} /></dd>
          </div>
          <div class="summary-fact">
            <dt>Corroborated</dt>
            <dd>×{@detail.item.corroboration_count}</dd>
          </div>
          <div class="summary-fact">
            <dt>Recorded</dt>
            <dd><.time at={@detail.item.inserted_at} now={@now} /></dd>
          </div>
          <div class="summary-fact">
            <dt>Statement id</dt>
            <dd><.id_chip value={@detail.item.id} id="summary-id" /></dd>
          </div>
        </dl>

        <.legend states={Access.visible_states(@current_actor)} />
      </section>

      <.panel
        :if={@actions.any?}
        title="What you can do"
        description="Each of these is carried out by the governance layer, which records an immutable decision and a hash-chained audit entry alongside the change."
      >
        <div :if={@actions.curate} class="action-group">
          <h3>Curator decision</h3>
          <p class="hint">
            This statement has an open queue entry
            (<.badge family="state" value={@detail.validation.state} />, due <.time
              at={@detail.validation.due_at}
              now={@now}
            />).
          </p>

          <div class="button-row">
            <%!--
              type="button" keeps these from being treated as submit controls
              if the markup is later moved inside a form. A decision must travel
              as this explicit event, never as an incidental form submission.
            --%>
            <button type="button" class="primary" phx-click="decide" phx-value-action="approve">
              Approve
            </button>
            <button type="button" phx-click="decide" phx-value-action="reject">Reject</button>
            <button type="button" phx-click="decide" phx-value-action="defer">Defer 24h</button>
          </div>
          <p class="hint">
            Approving makes this statement active in {@detail.item.scope_path || "its scope"}.
            Rejecting moves it to rejected and keeps it as evidence. Deferring moves the due
            date and leaves the statement untouched.
          </p>

          <form phx-submit="decide" class="inline-form">
            <input type="hidden" name="action" value="edit" />
            <label class="grow">
              Corrected wording
              <input name="statement" value={@detail.item.statement} />
            </label>
            <button>Edit as replacement</button>
          </form>
          <p class="hint">
            Editing does not rewrite this statement. It mints a replacement carrying your
            wording, supersedes this one, and sends the replacement back through the gate.
            The original stays readable.
          </p>

          <form phx-submit="decide" class="inline-form">
            <input type="hidden" name="action" value="merge" />
            <label class="grow">
              Merge into statement id
              <input name="merge_into_id" placeholder="Paste a knowledge id from the cross-references below" />
            </label>
            <button>Merge</button>
          </form>
          <p class="hint">
            Merging folds this statement's confidence, corroboration, and sources into the
            target, then supersedes this one.
          </p>
        </div>

        <div :if={@actions.promote} class="action-group">
          <h3>Promote to a wider scope</h3>
          <form phx-submit="promote" class="inline-form">
            <label class="grow">
              Target scope
              <select name="target_scope_id">
                <option :for={scope <- @actions.promotion_targets} value={scope.id}>
                  {scope.path}
                </option>
              </select>
            </label>
            <button>Request promotion</button>
          </form>
          <p class="hint">
            This does not move the statement. It holds a copy at the scope you pick for a
            second human decision, and personal knowledge additionally waits for its
            subject's own consent, which a curator cannot give on their behalf.
          </p>
        </div>

        <div :if={@actions.subject} class="action-group">
          <h3>This statement is about you</h3>
          <p class="hint">
            Confirming makes it active at full confidence. Contesting marks it disputed and
            queues it for a curator. Redacting withdraws it.
          </p>
          <div class="button-row">
            <button type="button" class="primary" phx-click="subject" phx-value-verdict="confirm">
              Confirm
            </button>
            <button type="button" phx-click="subject" phx-value-verdict="contest">Contest</button>
            <button type="button" class="danger" phx-click="subject" phx-value-verdict="redact">
              Redact
            </button>
          </div>
        </div>
      </.panel>

      <.panel
        :if={not @actions.any?}
        title="What you can do"
        description="Nothing on this statement, for the reason below."
      >
        <p class="hint">{@actions.reason}</p>
      </.panel>

      <div class="split">
        <.panel
          title="How current and how trusted"
          description="Belief time against valid time: when the system holds the claim, against when the claim is true in the world. A fact can be freshly learned and long expired."
        >
          <dl class="pairs">
            <dt>Verification</dt>
            <dd>{enum_label("verification", @detail.item.verification)}</dd>
            <%!--
              Distinct from the corroboration count in the summary: this is how
              many observations were recorded as sources, not how many times the
              claim was independently corroborated.
            --%>
            <dt>Source observations</dt>
            <dd>{length(@detail.item.source_message_ids)}</dd>
            <dt>Recorded</dt>
            <dd><.time at={@detail.item.inserted_at} now={@now} /></dd>
            <dt>Revalidate after</dt>
            <dd><.time at={@detail.item.revalidate_after} now={@now} /></dd>
            <dt>Expires</dt>
            <dd><.time at={@detail.item.expires_at} now={@now} /></dd>
            <dt>Relevant from</dt>
            <dd><.time at={@detail.item.relevant_from} now={@now} /></dd>
            <dt>Relevant until</dt>
            <dd><.time at={@detail.item.relevant_until} now={@now} /></dd>
          </dl>
        </.panel>

        <.panel
          title="Scope, subject, and sensitivity"
          description="Who the claim is about, where it sits, and how far it may travel. These are independent: a colleague can be the subject of something you said."
        >
          <dl class="pairs">
            <dt>Scope</dt>
            <dd><.scope_crumb path={@detail.item.scope_path} id="detail-scope" /></dd>
            <dt>Sensitivity</dt>
            <dd><.badge family="sensitivity" value={@detail.item.sensitivity} /></dd>
            <dt>May travel to</dt>
            <dd><.badge family="level" value={@detail.item.target_level} /></dd>
            <dt>Subject peer</dt>
            <dd><.id_chip value={@detail.item.subject_peer_id} id="subject-peer" /></dd>
            <dt>Subject scope</dt>
            <dd><.id_chip value={@detail.item.subject_scope_id} id="subject-scope" /></dd>
            <dt>Held for scope</dt>
            <dd><.id_chip value={@detail.item.held_scope_id} id="held-scope" /></dd>
          </dl>
        </.panel>
      </div>

      <.panel
        title="Provenance"
        description="Every recorded route by which this statement entered the system."
      >
        <.empty :if={@detail.provenance == []} message="No provenance rows are attached." />
        <div :if={@detail.provenance != []} class="table-scroll" role="region" aria-label="Provenance">
          <table class="grid cards">
            <thead>
              <tr>
                <th>When</th>
                <th>Source</th>
                <th>Reference</th>
                <th>Extracted by</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @detail.provenance}>
                <td class="nowrap" data-label="When"><.time at={row.occurred_at} now={@now} /></td>
                <td data-label="Source"><.badge family="kind" value={row.source_type} /></td>
                <td data-label="Reference">
                  <.id_chip
                    :if={row.message_id}
                    value={row.message_id}
                    id={"provenance-message-#{row.id}"}
                  />
                  <.id_chip
                    :if={row.document_version_id}
                    value={row.document_version_id}
                    id={"provenance-document-#{row.id}"}
                  />
                </td>
                <td class="muted" data-label="Extracted by">{row.extracting_model || "—"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>

      <.panel
        title="Raw observations behind it"
        description="What was actually said. Extraction produced the statement above from these, and the two are deliberately kept apart."
      >
        <.empty
          :if={@detail.messages == []}
          message="No raw observation is readable for this statement — it may have come from a document, or from a scope you cannot read."
        />
        <article :for={message <- @detail.messages} class="quote">
          <p class="quote-meta">
            {message.role} · <.time at={message.occurred_at} now={@now} /> · session
            <.id_chip value={message.session_id} id={"session-#{message.id}"} />
          </p>
          <p :if={not truncated?(message.content, 600)}>{message.content}</p>
          <details :if={truncated?(message.content, 600)} class="expandable">
            <summary>{truncate(message.content, 600)}</summary>
            <p class="expandable-full">{message.content}</p>
          </details>
        </article>
      </.panel>

      <.panel
        :if={@detail.document_versions != []}
        title="Document versions behind it"
        description="Documents are versioned immutably; a changed document appends a version rather than overwriting one."
      >
        <div class="table-scroll" role="region" aria-label="Document versions">
          <table class="grid cards">
            <thead>
              <tr>
                <th>Version</th>
                <th>Media type</th>
                <th>Bytes</th>
                <th>Status</th>
                <th>Recorded</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={version <- @detail.document_versions}>
                <td data-label="Version">v{version.version}</td>
                <td data-label="Media type">{version.media_type}</td>
                <td data-label="Bytes">{version.byte_size}</td>
                <td data-label="Status">
                  <.badge family="state" value={version.processing_status} />
                </td>
                <td class="nowrap muted" data-label="Recorded">
                  <.time at={version.occurred_at} now={@now} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>

      <.panel
        title="Lifecycle"
        description="Append-only. Every state change writes an event here in the same transaction that made the change."
      >
        <.empty :if={@detail.lifecycle == []} message="No transition has been recorded." />
        <ol :if={@detail.lifecycle != []} class="timeline">
          <li :for={event <- @detail.lifecycle}>
            <span class="timeline-when"><.time at={event.occurred_at} now={@now} /></span>
            <span :if={event.from_state} class="muted">
              {enum_label("state", event.from_state)} →
            </span>
            <.badge family="state" value={event.to_state} />
            <span class="muted">{event.reason}</span>
          </li>
        </ol>
      </.panel>

      <.panel
        title="Shared-entity neighbors"
        description="Statements that share at least one resolved entity with this one. The count and links include only scopes and lifecycle states you may read."
      >
        <div class="tiles">
          <.tile
            label="Other statements"
            value={@detail.co_mentions_count}
            note="sharing a resolved entity"
          />
        </div>

        <.empty
          :if={@detail.co_mentions == []}
          message="No other readable statement shares a resolved entity with this one."
        />

        <.statement_links :if={@detail.co_mentions != []} items={@detail.co_mentions} back={@back} />

        <p :if={@detail.co_mentions_truncated?} class="hint">
          Showing the first {length(@detail.co_mentions)} readable statements. The count includes
          every readable match.
        </p>
      </.panel>

      <.panel
        title="Cross-references"
        description="Relations, conflicts, and the supersession chain. A link to a statement you cannot read is omitted entirely rather than shown as a dead id."
      >
        <div :if={@detail.superseded} class="chain">
          <h3>Supersedes</h3>
          <p>
            <.link navigate={~p"/console/knowledge/#{@detail.superseded.id}?#{back_link(@back)}"}>
              {truncate(@detail.superseded.statement, 140)}
            </.link>
          </p>
        </div>

        <div :if={@detail.successors != []} class="chain">
          <h3>Superseded by</h3>
          <p :for={item <- @detail.successors}>
            <.link navigate={~p"/console/knowledge/#{item.id}?#{back_link(@back)}"}>
              {truncate(item.statement, 140)}
            </.link>
          </p>
        </div>

        <.empty
          :if={@detail.related == [] and is_nil(@detail.superseded) and @detail.successors == []}
          message="This statement stands on its own — nothing links to it and it supersedes nothing."
        />

        <.statement_links :if={@detail.related != []} items={@detail.related} back={@back} />
      </.panel>

      <details class="technical">
        <summary>Technical details</summary>

        <.panel
          title="How this was produced"
          description="The extraction and embedding identities travel with the statement, so a reader can tell which model produced it and whether its vector is still comparable."
        >
          <dl class="pairs wide">
            <dt>Extracted by</dt>
            <dd>
              {@detail.item.extracting_provider || "—"} / {@detail.item.extracting_model || "—"} / {@detail.item.extracting_model_version ||
                "—"}
            </dd>
            <dt>Prompt version</dt>
            <dd>{@detail.item.prompt_version || "—"}</dd>
            <dt>Pipeline version</dt>
            <dd>{@detail.item.pipeline_version}</dd>
            <dt>Embedding</dt>
            <dd>
              {@detail.item.embedding_provider || "not embedded"}
              <span :if={@detail.item.embedding_model}>
                / {@detail.item.embedding_model} / {@detail.item.embedding_version} / {@detail.item.embedding_dimensions}d
              </span>
            </dd>
          </dl>
        </.panel>

        <.panel
          :if={@detail.gate_decisions != []}
          title="Gate decisions"
          description="Immutable record of each automatic and human gate result. Visible to curators, because the decision rows are curator-scoped."
        >
          <div class="table-scroll" role="region" aria-label="Gate decisions">
            <table class="grid cards">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Gate</th>
                  <th>Decision</th>
                  <th>Channel</th>
                  <th>Transition</th>
                  <th>Decided by</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={decision <- @detail.gate_decisions}>
                  <td class="nowrap" data-label="When">{timestamp(decision.decided_at)}</td>
                  <td data-label="Gate">{decision.gate}</td>
                  <td data-label="Decision">
                    <.badge family="decision" value={decision.decision} />
                  </td>
                  <td class="muted" data-label="Channel">{decision.channel}</td>
                  <td class="muted" data-label="Transition">
                    {enum_label("state", decision.from_state)} → {enum_label(
                      "state",
                      decision.to_state
                    )}
                  </td>
                  <td data-label="Decided by">
                    <.id_chip value={decision.actor_peer_id} id={"decision-actor-#{decision.id}"} />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <.panel
          :if={@detail.attributions != []}
          title="Attribution"
          description="Who or what this statement has been attributed to, and at what level."
        >
          <div class="table-scroll" role="region" aria-label="Attribution">
            <table class="grid cards">
              <thead>
                <tr>
                  <th>Target</th>
                  <th>Reference</th>
                  <th>Level</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @detail.attributions}>
                  <td data-label="Target">{row.target_type}</td>
                  <td data-label="Reference">
                    <.id_chip
                      :if={row.target_peer_id}
                      value={row.target_peer_id}
                      id={"attribution-peer-#{row.id}"}
                    />
                    <.id_chip
                      :if={row.target_scope_id}
                      value={row.target_scope_id}
                      id={"attribution-scope-#{row.id}"}
                    />
                  </td>
                  <td data-label="Level"><.badge family="level" value={row.level} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>
      </details>
    </.shell>
    """
  end

  attr :items, :list, required: true
  attr :back, :map, required: true

  defp statement_links(assigns) do
    ~H"""
    <div class="table-scroll" role="region" aria-label="Linked statements">
      <table class="grid cards">
        <thead>
          <tr>
            <th>Statement</th>
            <th>Scope</th>
            <th>State</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={item <- @items}>
            <td data-label="Statement">
              <.link navigate={~p"/console/knowledge/#{item.id}?#{back_link(@back)}"}>
                {truncate(item.statement, 160)}
              </.link>
            </td>
            <td class="nowrap" data-label="Scope">
              <.scope_crumb path={item.scope_path} id={"linked-scope-#{item.id}"} />
            </td>
            <td data-label="State"><.badge family="state" value={item.state} /></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # Reload committed state and recompute visible controls after each attempt.
  defp load(socket, id) do
    actor = socket.assigns.current_actor
    detail = Loader.knowledge_detail(actor, id)

    socket
    |> assign(:detail, detail)
    |> assign(:actions, actions(actor, detail))
  end

  # Decisions need a queue row; promotion needs a strict ancestor.
  defp actions(_actor, nil), do: %{any?: false, reason: nil}

  defp actions(actor, detail) do
    curate? = Access.can?(actor, :curate) and not is_nil(detail.validation)
    targets = promotion_targets(detail)
    promote? = Access.can?(actor, :promote) and targets != []
    subject? = Access.subject_of?(actor, detail.item)

    %{
      any?: curate? or promote? or subject?,
      curate: curate?,
      promote: promote?,
      subject: subject?,
      promotion_targets: targets,
      reason: no_action_reason(actor, detail, targets)
    }
  end

  # An empty panel reads as a bug. Naming the missing condition is also the
  # honest answer to "why can't I", and none of these disclose anything the
  # reader could not already see on this page.
  defp no_action_reason(actor, detail, targets) do
    cond do
      not Access.can?(actor, :curate) and not Access.can?(actor, :self_govern) ->
        "Console actions need a password sign-in. Machine credentials never carry them."

      Access.can?(actor, :curate) and is_nil(detail.validation) and targets == [] ->
        "This statement has no open queue entry to decide, and it already sits at the " <>
          "widest scope you can promote it to."

      Access.can?(actor, :curate) and is_nil(detail.validation) ->
        "This statement has no open queue entry, so there is nothing to approve, reject, " <>
          "defer, edit, or merge."

      true ->
        "Curator decisions need the curator or account-admin role, and confirm, contest, " <>
          "and redact belong to the subject of a statement, which is not you."
    end
  end

  # Offer only authorized strict ancestors; operations reject other moves.
  defp promotion_targets(detail) do
    case detail.item.scope_path do
      nil ->
        []

      path ->
        detail.scopes
        |> Enum.filter(&(&1.path != path and ancestor?(&1.path, path)))
        |> Enum.sort_by(&String.length(&1.path), :desc)
    end
  end

  defp ancestor?("/", _path), do: true
  defp ancestor?(candidate, path), do: String.starts_with?(path, candidate <> "/")

  # Rebuild the explorer's filters from the opaque `back` value, keeping only
  # keys the explorer itself defines. Anything else — including an absolute URL
  # — is discarded, so this can only ever return to the explorer.
  defp back_params(nil), do: %{}

  defp back_params(encoded) when is_binary(encoded) do
    encoded
    |> URI.decode_query()
    |> Map.take(@filter_keys)
  rescue
    ArgumentError -> %{}
  end

  defp back_params(_other), do: %{}

  # Carry the same return target onward, so following a cross-reference does not
  # strand the reader.
  defp back_link(back) when map_size(back) == 0, do: %{}
  defp back_link(back), do: %{"back" => URI.encode_query(back)}

  # Keep refusal messages generic so operation errors cannot reveal ids.
  defp guard(socket, success_message, fun) do
    actor = socket.assigns.current_actor
    id = socket.assigns.detail.item.id

    socket =
      try do
        fun.(actor)
        put_flash(socket, :info, success_message)
      rescue
        error in [Ash.Error.Forbidden, Ash.Error.Query.NotFound, Ash.Error.Invalid] ->
          _ = error
          put_flash(socket, :error, "That action was refused. Nothing was changed.")

        error in [ArgumentError, KeyError] ->
          _ = error
          put_flash(socket, :error, "That action needs a valid value. Nothing was changed.")
      end

    {:noreply, load(socket, id)}
  end
end
