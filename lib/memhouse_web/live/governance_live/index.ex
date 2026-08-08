# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.GovernanceLive.Index do
  @moduledoc """
  The curator's review surface at `/governance`: the open gate queue, the human
    decisions taken on it, and skill-requirement-card authoring.

    Nothing on this page may ever be driven by a machine credential.
  """

  use MemHouseWeb, :live_view

  import MemHouseWeb.ConsoleComponents

  alias MemHouse.DataLayer
  alias MemHouse.Governance.Engine
  alias MemHouse.Governance.ValidationItem
  alias MemHouse.Knowledge.KnowledgeItem
  alias MemHouse.Skills
  alias MemHouse.Skills.SkillRequirementCard
  alias MemHouse.Topology.Scope

  require Ash.Query

  @doc """
  Loads the queue for the curator who just signed in.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:selected_ids, MapSet.new()) |> load_queue()}
  end

  @doc """
  Handles the curator gestures available on this page.

    Failure handling differs between the two families. Decisions raise rather than
    return on a forbidden actor, an unknown id, a blank edited statement, or a missing
    merge target; nothing is rescued here, so the LiveView process crashes and the
    client remounts onto freshly read state.
  """
  @impl true
  def handle_event("decide", %{"id" => id, "action" => action} = params, socket) do
    # Only the optional decision inputs are forwarded, and blank ones are
    # dropped rather than passed through as empty strings. The operation layer
    # reads an absent key as "keep what is stored" (sensitivity, defer window)
    # and requires a present one for edit and merge, so a blank field must
    # arrive as absent: passing "" would either overwrite a real value with
    # nothing or record an empty statement.
    opts =
      params
      |> Map.take(["statement", "merge_into_id", "defer_hours", "sensitivity"])
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    result = Engine.decide(socket.assigns.current_actor, id, action, opts)

    socket =
      socket
      |> put_flash(:info, decide_flash(action, result))
      |> load_queue()

    {:noreply, socket}
  end

  # Two shapes reach the same decision. The per-item buttons send the queue row
  # under `id`; the edit and merge forms send it under `validation_id`, which
  # names what the hidden field is so it is not mistaken for the knowledge id
  # sitting next to it in the same form. Renaming the key here keeps one
  # decision path rather than two that can drift apart. This clause must stay
  # adjacent to the one it delegates to: Elixir requires all clauses of a
  # function to be contiguous.
  def handle_event(
        "decide",
        %{"validation_id" => id, "action" => _action} = params,
        socket
      ) do
    handle_event("decide", Map.put(params, "id", id), socket)
  end

  # Each row's checkbox lives in the row markup but is bound to the toolbar
  # form by id, so the browser submits the selection as a map keyed by queue
  # row id. Only checked boxes are sent, and a run with nothing checked omits
  # the key entirely — hence the empty-map default and the no-op that follows.
  #
  # The operation layer applies these one at a time, each in its own
  # transaction under its own advisory lock. There is no all-or-nothing bulk
  # semantic: a failure part-way through leaves the earlier decisions
  # committed, which is exactly why the queue is re-read afterwards instead of
  # optimistically clearing the selected rows. The flash summarizes what that
  # re-read will show, so a batch that includes a consent-held item does not
  # look like it silently dropped rows.
  def handle_event("bulk", %{"action" => action} = params, socket) do
    ids = params |> Map.get("ids", %{}) |> Map.keys()
    results = Engine.bulk_decide(socket.assigns.current_actor, ids, action)

    socket =
      socket
      |> put_flash(:info, bulk_flash(action, results))
      |> assign(:selected_ids, MapSet.new())
      |> load_queue()

    {:noreply, socket}
  end

  # Selects every row currently rendered. `@items` is already filtered to this
  # Account and the open lifecycle states, so this can never reach into
  # another Account or a settled decision — it only ever widens `"bulk"`'s
  # target to rows the curator could already check one at a time.
  def handle_event("select_all", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new(Enum.map(socket.assigns.items, & &1.id)))}
  end

  # Clears the current selection without deciding anything.
  def handle_event("deselect_all", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  # Flips one row's membership in the selection. Fired by each row's own
  # checkbox instead of leaving the browser to own its checked state, which is
  # what lets "select all"/"deselect all" force every box to a known value.
  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected_ids =
      if MapSet.member?(socket.assigns.selected_ids, id) do
        MapSet.delete(socket.assigns.selected_ids, id)
      else
        MapSet.put(socket.assigns.selected_ids, id)
      end

    {:noreply, assign(socket, :selected_ids, selected_ids)}
  end

  # Skill requirement cards are authored configuration, not knowledge. A card
  # states which governed knowledge must already exist before an agent may run
  # a named skill. Cards are plain-versioned: they never pass the gate, they
  # are never extracted from a conversation, and a card can never satisfy
  # another card's requirement.
  #
  # Publishing is not an edit. It creates a new immutable version and
  # deactivates the previous active version for the same scope and skill key,
  # both in one Account-scoped transaction serialized by an advisory lock, so
  # two curators publishing the same card concurrently cannot produce two
  # active versions or a duplicated version number.
  #
  # Both error branches are user error in a hand-edited textarea, so they
  # surface as a flash and leave the queue untouched: malformed JSON, an
  # unknown or unauthorized scope path, a skill key that is not a lowercase
  # slug, or a requirement list the selector validator rejects (unknown keys,
  # duplicate requirement keys, out-of-range confidence, non-positive freshness
  # or corroboration limits).
  def handle_event("publish_skill_card", params, socket) do
    with {:ok, requirements} <- Jason.decode(params["requirements"]),
         {:ok, card} <-
           Skills.publish(socket.assigns.current_actor, %{
             scope_path: params["scope_path"],
             skill_key: params["skill_key"],
             description: params["description"],
             requirements: requirements
           }) do
      socket =
        socket
        |> put_flash(:info, "Published #{card.skill_key} version #{card.version}.")
        |> load_queue()

      {:noreply, socket}
    else
      {:error, %Jason.DecodeError{}} ->
        {:noreply, put_flash(socket, :error, "Requirements must be valid JSON.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, to_string(message))}
    end
  end

  @doc """
  Renders the open queue, the per-item decision controls, and the skill-card
  authoring form.

  The page uses the shared console frame, so a curator moving between the queue
  and the exploration pages keeps the same navigation and the same visual
  language. Everything here is a server round-trip: the browser policy on these
  pages forbids inline script, so any control added must work without one.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <%!--
    The heading is "Governance queue" rather than anything shorter because that
    exact wording is asserted by the curator-surface regression test: it is how
    that test tells a rendered queue apart from a redirect to sign-in. Renaming
    it is a deliberate change to that evidence, not a copy edit.
    --%>
    <.shell actor={@current_actor} active={:queue} title="Governance queue" flash={@flash}>
      <:subtitle>
        Gate A/B proposals, conflicts, consent holds, and lifecycle reviews. Every decision
        here is human-only and leaves an immutable record.
      </:subtitle>

      <%!--
      The bulk toolbar holds no checkboxes of its own. Each queue row's
      checkbox is attached to this form by id, which is what lets the selection
      live inside the row markup while still submitting here. Each button
      carries the same name with a different value, so the pressed button is
      what tells the handler which decision to apply to the selection.

      Note the omissions: there is no bulk edit and no bulk merge. Both need a
      per-item value a curator must actually look at, and neither is safe to
      apply blindly across a selection.

      Select all / deselect all are plain buttons, not part of the form: they
      only change `@selected_ids`, which is what drives each row checkbox's
      `checked` attribute. That server round-trip is what lets them force
      every box to a known state without any client-side script.
      --%>
      <.panel
        title={"#{length(@items)} item(s) awaiting a decision"}
        description="Oldest due date first. Decisions apply one at a time, each in its own transaction, so a bulk run that fails part-way leaves the earlier decisions committed."
      >
        <div class="button-row">
          <button type="button" phx-click="select_all">Select all</button>
          <button type="button" phx-click="deselect_all">Deselect all</button>
        </div>

        <form id="bulk-form" phx-submit="bulk">
          <div class="button-row">
            <button class="primary" name="action" value="approve">Approve selected</button>
            <button name="action" value="reject">Reject selected</button>
            <button name="action" value="defer">Defer selected</button>
          </div>
        </form>

        <.empty :if={@items == []} message="The queue is clear." />
      </.panel>

      <%!--
      One card per open queue row. The statement is shown in full because a
      curator cannot judge a claim they cannot read; this is the one channel
      where that text is allowed to appear. The metadata beside it is what the
      decision actually turns on — how confident the extraction was, how
      sensitive the claim is, how far the item wants to travel, which raw
      observations produced it, and which existing knowledge it contradicts.
      Provenance stays an opaque id list: it lets a curator go look without
      pulling more content onto the page. Conflicts are resolved to the
      statements they name instead, because a curator judging a proposal needs
      to see what it disagrees with immediately, not after a detour to another
      page — that is the whole reason `load_queue/1` batch-fetches them.
      --%>
      <section :for={item <- @items} class="statement-card">
        <div class="record-head">
          <%!--
          Bound to the bulk toolbar above by form id. The name makes the
          browser submit the selection as a map keyed by queue row id, so the
          handler gets exactly the checked ids and nothing else. `checked` is
          driven by `@selected_ids` rather than left to the browser, and
          `phx-click` keeps that assign in sync with a manual click — together
          this is what makes "select all" able to force every box to tick.
          --%>
          <label class="muted">
            <input
              type="checkbox"
              form="bulk-form"
              name={"ids[#{item.id}]"}
              value="true"
              checked={MapSet.member?(@selected_ids, item.id)}
              phx-click="toggle_select"
              phx-value-id={item.id}
            />
            select
          </label>
          <.link navigate={~p"/console/knowledge/#{item.knowledge.id}"} class="ghost-link">
            Full record and history
          </.link>
        </div>

        <p class="statement">{item.knowledge.statement}</p>

        <div class="badge-row">
          <.badge family="kind" value={item.kind} />
          <.badge family="level" value={item.target_level} />
          <.badge family="state" value={item.state} />
          <.badge family="sensitivity" value={item.sensitivity} />
          <span class="badge">confidence {item.confidence}</span>
        </div>

        <dl class="pairs">
          <dt>Due</dt>
          <dd>{item.due_at}</dd>
          <dt>Provenance</dt>
          <dd>{Enum.join(item.provenance_ids, ", ")}</dd>
        </dl>

        <%!--
        Ids that didn't resolve — wrong scope for this actor, since retracted,
        whatever — are silently absent from `item.conflicts` rather than
        listed as dead ids; see `load_queue/1`. Nothing renders when there are
        no conflicts, rather than an empty "Conflicts" row a curator has to
        parse as "none".
        --%>
        <div :if={item.conflicts != []} class="chain">
          <h3>Conflicts with</h3>
          <p :for={conflict <- item.conflicts}>
            <.link navigate={~p"/console/knowledge/#{conflict.id}"}>
              {truncate(conflict.statement, 140)}
            </.link>
          </p>
        </div>

        <%!--
        Approve, reject, and defer need no extra input, so they are direct
        clicks rather than forms. type="button" keeps them from ever being
        treated as a submit control if this markup is later moved inside a
        form; the decision must travel as this explicit event, never as an
        incidental form submission.
        --%>
        <div class="button-row">
          <button type="button" class="primary" phx-click="decide" phx-value-id={item.id} phx-value-action="approve">
            Approve
          </button>
          <button type="button" phx-click="decide" phx-value-id={item.id} phx-value-action="reject">
            Reject
          </button>
          <button type="button" phx-click="decide" phx-value-id={item.id} phx-value-action="defer">
            Defer
          </button>
        </div>

        <%!--
        "Edit as replacement" is the literal behaviour, not a euphemism.
        Submitting does not overwrite the statement: it mints a new
        pipeline-owned knowledge row with the corrected text, supersedes
        this one, and runs the replacement through the gate from scratch.
        The curator supplies wording; the pipeline stays the only writer,
        and the original text remains recoverable through its history.
        The field is pre-filled with the current statement so a curator
        corrects rather than retypes, and a cleared field is dropped as
        blank rather than saved as an empty claim.
        --%>
        <form phx-submit="decide" class="inline-form">
          <input type="hidden" name="validation_id" value={item.id} />
          <input type="hidden" name="action" value="edit" />
          <label class="grow">
            Corrected wording
            <input name="statement" value={item.knowledge.statement} />
          </label>
          <button>Edit as replacement</button>
        </form>

        <%!--
        Merge folds this item into an existing knowledge row: the target
        keeps the higher confidence, the summed corroboration count, and
        the union of source message ids, and this item is superseded. The
        target is typed as a raw knowledge id because the curator arrives
        here from the conflict ids listed above, which are the ids worth
        merging into.
        --%>
        <form phx-submit="decide" class="inline-form">
          <input type="hidden" name="validation_id" value={item.id} />
          <input type="hidden" name="action" value="merge" />
          <label class="grow">
            Merge into knowledge id
            <input name="merge_into_id" placeholder="Paste one of the conflict ids above" />
          </label>
          <button>Merge</button>
        </form>
      </section>

      <%!--
      Skill requirement cards share this page because both are curator work,
      but they are a different kind of thing from the queue above. A card is
      authored configuration that says which governed knowledge must already
      exist before an agent may run a named skill. Cards are not knowledge:
      they never pass the gate, and one card can never satisfy another card's
      requirement. Card authoring exists here and nowhere else — agents get a
      readiness check, never a way to write the contract they are checked
      against.
      --%>
      <.panel
        title="Skill requirement cards"
        description="Versioned procedural-memory contracts. Child scopes override inherited requirements by requirement key."
      >
        <%!--
        One form, deliberately. Every field below is part of the same published
        version, so splitting them across two form elements would submit half a
        card. The row of short fields and the JSON payload are separated
        visually and not structurally.
        --%>
        <form phx-submit="publish_skill_card">
          <div class="filters">
            <%!--
            Scope path rather than scope id: the path is what a curator can read
            and verify. It is resolved against the scopes this curator is
            authorized to see, so an unknown or unauthorized path is rejected
            with a message instead of silently creating a card somewhere else.
            --%>
            <label class="grow">
              Scope path
              <input name="scope_path" placeholder="/marketing/social" required />
            </label>
            <label class="grow">
              Skill key
              <input name="skill_key" placeholder="write-copy" required />
            </label>
            <label class="grow">
              Description
              <input name="description" placeholder="Knowledge needed before writing copy" />
            </label>
          </div>

          <%!--
          "f9-1" is the pinned identity of the requirement-selector schema
          that is stored on every published card, so a reader of an old card
          knows which selector language it was written in. It is data, not a
          label: changing that string is a deliberate contract transition —
          every stored card and every consumer of a readiness report is written
          against it — and owes a changelog entry plus refreshed contract
          evidence. It is not a cosmetic version bump.

          The textarea is raw JSON on purpose. Requirements are a small
          declarative language (which knowledge kind, whose, how fresh, how
          confident, required versus preferred, and whether the peer may be
          asked), and a curator reviewing a contract should see the whole
          contract rather than a form that hides half of it.
          --%>
          <label class="muted">
            Requirements (`f9-1` JSON)
            <textarea name="requirements" rows="12" required>{skill_card_example()}</textarea>
          </label>
          <div class="button-row">
            <button class="primary">Publish new version</button>
          </div>
        </form>

        <.empty :if={@skill_cards == []} message="No skill cards have been authored." />

        <%!--
        Every version is listed, newest first within each skill key, not just
        the active one: superseded versions are the record of what the contract
        used to demand, which is what makes an old readiness result readable
        after the fact. Exactly one version per scope and skill key is "active";
        the rest are marked retired and are never consulted by a readiness
        check. Requirements are printed verbatim so a reviewer compares the
        stored contract, not a re-rendering of it.
        --%>
        <article :for={card <- @skill_cards} class="record">
          <div class="record-head">
            <h3>{card.skill_key}</h3>
            <div class="badge-row">
              <span class="badge">{card.scope_path}</span>
              <span class="badge">version {card.version}</span>
              <span class="badge">{card.requirement_schema_version}</span>
              <.badge family="state" value={if(card.active, do: "active", else: "retired")} />
            </div>
          </div>
          <p :if={card.description}>{card.description}</p>
          <pre class="code">{Jason.encode!(card.requirements, pretty: true)}</pre>
        </article>
      </.panel>
    </.shell>
    """
  end

  # Re-reads everything the page shows. Called on mount and again after every
  # mutation, because nothing here is patched in memory: the rendered page is
  # always committed state.
  #
  # Every query runs inside one Account-scoped transaction. That wrapper is
  # what sets the Account the database's row-level security checks, so a
  # curator physically cannot read another Account's rows even if a filter were
  # dropped. Never move a query out of it, and never rely on a template filter
  # to keep tenants apart.
  defp load_queue(socket) do
    {items, skill_cards} =
      DataLayer.with_actor(socket.assigns.current_actor, fn account, actor ->
        # Only states that still need something from a human are listed:
        # "pending" and "escalated" want a decision now, "deferred" is waiting
        # on a timer a curator set, and "awaiting_consent" is a curator
        # approval parked until the subject of personal knowledge grants
        # target-specific consent. Decided rows (approved, rejected, merged)
        # are history and belong in the audit trail, not the work queue.
        # Oldest due date first, so the most overdue review is on top.
        validations =
          ValidationItem
          |> Ash.Query.filter(state in ["pending", "deferred", "awaiting_consent", "escalated"])
          |> Ash.Query.sort(due_at: :asc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)

        # The statement is fetched per row under the same actor rather than
        # joined onto the queue read. Authorization is then applied to the
        # knowledge itself, so a queue row can never carry content the curator
        # is not allowed to read. The extra round-trips are the price of that,
        # and the queue is short by design.
        #
        # `:knowledge` is a render-only key attached to the loaded struct. It
        # is not an attribute and is never written back.
        items =
          Enum.map(validations, fn item ->
            knowledge =
              KnowledgeItem
              |> Ash.Query.filter(id == ^item.knowledge_id)
              |> Ash.Query.set_tenant(account.id)
              |> Ash.read_one!(actor: actor)

            Map.put(item, :knowledge, knowledge)
          end)

        # One batch fetch for every conflict id across the whole queue, rather
        # than one query per row per conflict: the same shape as the scope
        # lookup below. An id that doesn't come back — wrong scope for this
        # actor, since retracted, whatever — is simply absent from the map, and
        # `:conflicts` below drops it rather than rendering a dead id.
        conflict_ids = items |> Enum.flat_map(& &1.conflict_knowledge_ids) |> Enum.uniq()

        conflicts_by_id =
          if conflict_ids == [] do
            %{}
          else
            KnowledgeItem
            |> Ash.Query.filter(id in ^conflict_ids)
            |> Ash.Query.set_tenant(account.id)
            |> Ash.read!(actor: actor)
            |> Map.new(&{&1.id, &1})
          end

        items =
          Enum.map(items, fn item ->
            conflicts =
              item.conflict_knowledge_ids
              |> Enum.map(&Map.get(conflicts_by_id, &1))
              |> Enum.reject(&is_nil/1)

            Map.put(item, :conflicts, conflicts)
          end)

        # Cards store a scope id, but a human recognises the path. Build the
        # lookup from the scopes this actor may read, so the same authorization
        # that hid a scope also keeps its path off the page.
        scope_paths =
          Scope
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
          |> Map.new(&{&1.id, &1.path})

        # Grouped by skill key with the newest version first, so the active
        # version of each skill heads its group and older ones read as history.
        #
        # The path lookup is deliberately strict. A card whose scope is absent
        # from the authorized map means this read returned a card from a scope
        # the curator cannot see, which is a tenancy or policy defect: failing
        # loudly is correct, and softening it to a default would render a
        # contract under the wrong scope.
        skill_cards =
          SkillRequirementCard
          |> Ash.Query.sort(skill_key: :asc, version: :desc)
          |> Ash.Query.set_tenant(account.id)
          |> Ash.read!(actor: actor)
          |> Enum.map(&Map.put(&1, :scope_path, Map.fetch!(scope_paths, &1.scope_id)))

        {items, skill_cards}
      end)

    socket
    |> assign(:items, items)
    |> assign(:skill_cards, skill_cards)
  end

  # Names what a single "decide" actually did. `Engine.decide/4`'s return shape
  # is per-action (see its own @doc), and the one case worth calling out by
  # itself is `consent_required: true`: the decision was recorded, but the
  # item is exactly where it was because only the subject can grant the
  # consent a curator approval cannot substitute for. Without this, that case
  # is indistinguishable on screen from the button doing nothing at all.
  defp decide_flash("approve", %{consent_required: true}) do
    "Approval recorded, but this personal statement still needs the subject's verified " <>
      "consent before it can move — it stays in the queue."
  end

  defp decide_flash("approve", %{consent_required: false}), do: "Approved."
  defp decide_flash("reject", _result), do: "Rejected."
  defp decide_flash("defer", _result), do: "Deferred to a later due date."

  defp decide_flash("edit", _result),
    do: "Replacement submitted. It re-enters the gate from proposed."

  defp decide_flash("merge", _result), do: "Merged into the target statement."

  # Summarizes a `bulk_decide/4` run rather than repeating `decide_flash/2` per
  # row: a curator who just applied one action to twenty items wants a count,
  # not twenty lines. Approve is the one action where that count is not the
  # whole story, because some of those decisions may have landed on
  # `consent_required: true` rows that never moved.
  defp bulk_flash("approve", results) do
    total = length(results)
    held = Enum.count(results, fn {_id, result} -> result.consent_required end)

    case held do
      0 ->
        "Applied 'approve' to #{total} item(s)."

      ^total ->
        "Applied 'approve' to #{total} item(s): all still need the subject's consent."

      _ ->
        "Applied 'approve' to #{total} item(s): #{total - held} approved, " <>
          "#{held} still need the subject's consent."
    end
  end

  defp bulk_flash(action, results), do: "Applied '#{action}' to #{length(results)} item(s)."

  # Seeds the authoring textarea with one valid requirement so a curator can
  # see the shape of the selector language instead of guessing it. This is a
  # form default only: nothing here is stored, versioned, or enforced until
  # Publish is pressed.
  #
  # The example reads: before this skill runs, there must be governed
  # preference knowledge whose subject is the scope itself, revalidated within
  # 2_592_000 seconds (30 days, the freshness window brand guidance is assumed
  # to drift over). `"level" => "required"` means a missing or stale match
  # blocks the skill outright; "preferred" would only warn. `"either"` lets any
  # otherwise-matching governed statement satisfy it, rather than forcing a
  # fresh question to the peer.
  #
  # The prompt is the wording an agent uses if it does have to ask. An answer
  # to it is not knowledge: it must return through ordinary raw ingest, be
  # extracted, and pass the gate before readiness is rechecked. Neither this
  # page nor any client helper may turn an elicited answer into knowledge.
  defp skill_card_example do
    Jason.encode!(
      [
        %{
          "key" => "brand-voice",
          "description" => "Current brand voice",
          "selector" => %{"kind" => "preference", "subject" => "scope"},
          "level" => "required",
          "source_policy" => "either",
          "freshness" => %{"revalidated_within_seconds" => 2_592_000},
          "prompt" => "How should this scope's brand voice sound?"
        }
      ],
      pretty: true
    )
  end
end
