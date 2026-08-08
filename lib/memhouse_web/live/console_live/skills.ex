# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleLive.Skills do
  @moduledoc """
  Read-only `/console/skills` view of versioned requirement cards and readiness.

  Cards are authored configuration, not knowledge, and cannot satisfy their own
  requirements. Requirements inherit by key with nearest-scope overrides.
  Checks are model-free metadata comparisons against authorized active or the
  subject's usable provisional knowledge; expired or revalidation-due items are
  gaps. Required gaps block and preferred gaps warn. Missing answers must enter
  through ordinary ingest and governance. Card publishing happens elsewhere.
  """

  use MemHouseWeb, :live_view

  import MemHouseWeb.ConsoleComponents

  alias MemHouse.Skills
  alias MemHouseWeb.Console.Access
  alias MemHouseWeb.Console.Loader

  @doc """
  Loads every card version the reader may see, with no readiness report until
  one is asked for.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:skills, Loader.skills(socket.assigns.current_actor))
     |> assign(:report, nil)}
  end

  @doc """
  Checks only the signed-in peer's readiness.

  Unknown or unauthorized skills and scopes produce a generic flash.
  """
  @impl true
  def handle_event("check", %{"skill" => skill, "scope_path" => scope_path}, socket) do
    socket =
      try do
        report =
          Skills.check_readiness(socket.assigns.current_actor, %{
            "skill" => skill,
            "scope_path" => scope_path
          })

        assign(socket, :report, report)
      rescue
        error in [ArgumentError, Ash.Error.Forbidden, Ash.Error.Query.NotFound] ->
          _ = error

          socket
          |> assign(:report, nil)
          |> put_flash(:error, "No such skill or scope, or you cannot read that scope.")
      end

    {:noreply, socket}
  end

  @doc """
  Renders the readiness form, its result, and the card library.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:skills} title="Skills" flash={@flash}>
      <:subtitle>
        What must already be known before a skill runs, and whether you know it yet.
        Requirements inherit down the scope tree, nearest scope winning.
      </:subtitle>

      <.panel
        title="Check your readiness"
        description="A pure metadata evaluation against the knowledge you are authorized to use. No model runs, and nothing is written."
      >
        <form phx-submit="check" class="filters">
          <label class="grow">
            Skill key
            <input name="skill" placeholder="write-copy" required autocomplete="off" />
          </label>
          <label class="grow">
            Scope
            <select name="scope_path" required>
              <option :for={scope <- @skills.scopes} value={scope.path}>{scope.path}</option>
            </select>
          </label>
          <button class="primary">Check</button>
        </form>

        <div :if={@report} class="report">
          <div class="tiles compact">
            <.tile
              label="Ready"
              value={if @report["ready"], do: "yes", else: "no"}
              tone={if @report["ready"], do: "accent", else: "warn"}
            />
            <.tile
              label="Blocked"
              value={if @report["blocked"], do: "yes", else: "no"}
              tone={if @report["blocked"], do: "danger", else: "neutral"}
            />
            <.tile label="Requirements" value={length(@report["requirements"] || [])} />
            <.tile label="Report version" value={@report["report_version"]} />
          </div>

          <.empty
            :if={(@report["requirements"] || []) == []}
            message="No active card applies to that skill at that scope, so there is nothing to satisfy — and nothing that authorizes the skill either."
          />

          <table :if={(@report["requirements"] || []) != []} class="grid">
            <thead>
              <tr>
                <th>Requirement</th>
                <th>Level</th>
                <th>Status</th>
                <th>Satisfied by</th>
                <th>Prompt if missing</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={requirement <- @report["requirements"]}>
                <td>
                  <strong>{requirement["key"]}</strong>
                  <p :if={requirement["description"]} class="muted">{requirement["description"]}</p>
                </td>
                <td><.badge family="level" value={requirement["level"]} /></td>
                <td><.badge family="state" value={requirement["status"]} /></td>
                <td>
                  <.id_chip
                    :for={id <- requirement["satisfied_by"] || []}
                    value={id}
                    navigate={~p"/console/knowledge/#{id}"}
                  />
                  <span :if={(requirement["satisfied_by"] || []) == []} class="muted">—</span>
                </td>
                <td class="muted">{requirement["prompt"] || "—"}</td>
              </tr>
            </tbody>
          </table>

          <p :if={(@report["blockers"] || []) != []} class="hint">
            A blocker stops the skill. Answering it is not a shortcut: the answer must arrive
            as an ordinary observation and pass the gates before this check changes.
          </p>
        </div>
      </.panel>

      <.panel
        title="Card library"
        description="Every published version, newest first within each skill. Exactly one version per scope and skill key is active; the rest are history."
      >
        <p :if={Access.can?(@current_actor, :curate)} class="hint">
          Publishing a new version is a curator act and happens on the
          <a href={~p"/governance"}>curator queue page</a>.
        </p>

        <.empty :if={@skills.cards == []} message="No skill card has been authored." />

        <article :for={card <- @skills.cards} class="record">
          <header class="record-head">
            <h3>{card.skill_key}</h3>
            <div class="badge-row">
              <span class="badge">version {card.version}</span>
              <span class="badge">{card.requirement_schema_version}</span>
              <.badge family="state" value={if card.active, do: "active", else: "retired"} />
            </div>
          </header>
          <p class="muted">{card.scope_path || "(unreadable scope)"}</p>
          <p :if={card.description}>{card.description}</p>
          <pre class="code">{Jason.encode!(card.requirements, pretty: true)}</pre>
        </article>
      </.panel>
    </.shell>
    """
  end
end
