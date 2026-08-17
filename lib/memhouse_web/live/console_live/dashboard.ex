# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleLive.Dashboard do
  @moduledoc """
  Read-only `/console` overview of visible memory and pending work.

  All memory counts use the signed-in actor's scopes and lifecycle visibility.
  Readiness and usage appear only for account administrators. Actions occur on
  linked pages through their operation layers.
  """

  use MemHouseWeb, :live_view

  import MemHouseWeb.ConsoleComponents

  alias MemHouse.Operations.Health
  alias MemHouse.Operations.Metering
  alias MemHouseWeb.Console.Access
  alias MemHouseWeb.Console.Loader

  @doc """
  Loads the actor-scoped overview and administrator-only operational tiles.

  Authentication guarantees `current_actor`; a missing actor must not degrade
  into a partial page.
  """
  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_actor
    overview = Loader.overview(actor)

    socket =
      socket
      |> assign(:overview, overview)
      |> assign(:health, if(Access.can?(actor, :administer), do: Health.readiness()))
      |> assign(:usage, if(Access.can?(actor, :administer), do: Metering.summary(actor)))

    {:ok, socket}
  end

  @doc """
  Renders counts, distributions, operational status, and recent activity.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:dashboard} title="Overview" flash={@flash}>
      <:subtitle>
        Everything below is filtered to the scopes your roles reach. Two people in the same
        Account will see different totals, and that is the scope tree working.
      </:subtitle>

      <div class="tiles">
        <.tile
          label="Statements you can read"
          value={@overview.knowledge_total}
          tone="accent"
          navigate={~p"/console/knowledge"}
        />
        <.tile label="Scopes reachable" value={@overview.scope_count} navigate={~p"/console/scopes"} />
        <.tile
          label="About you"
          value={@overview.about_me_count}
          note="Statements whose subject is you"
          navigate={~p"/console/me"}
        />
        <.tile
          label="Awaiting a decision"
          value={@overview.queue_depth}
          tone={if @overview.queue_depth > 0, do: "warn", else: "neutral"}
          note={queue_note(@current_actor)}
        />
        <.tile
          label="Documents"
          value={@overview.document_count}
          navigate={~p"/console/sources"}
        />
        <.tile
          label="Raw observations"
          value={@overview.message_count}
          note={"across #{@overview.session_count} sessions"}
          navigate={~p"/console/sources"}
        />
      </div>

      <div class="split">
        <.panel
          title="Lifecycle"
          description="Where the statements you can read currently sit. Only states you are entitled to see are counted."
        >
          <.bar_chart rows={sorted_counts(@overview.state_counts)} class_prefix="state" />
        </.panel>

        <.panel
          title="Sensitivity"
          description="How widely each statement may travel. Sensitivity is independent of confidence: a certain fact can still be restricted."
        >
          <.bar_chart rows={sorted_counts(@overview.sensitivity_counts)} class_prefix="sensitivity" />
        </.panel>
      </div>

      <.panel
        :if={@health}
        title="System readiness"
        description="Component status, queue depth, and configured model identities. Never credentials or stored content."
      >
        <div class="tiles">
          <.tile
            label="Overall"
            value={@health.status}
            tone={if @health.status == "ready", do: "accent", else: "danger"}
          />
          <.tile
            :for={{component, check} <- Enum.sort_by(@health.checks, &elem(&1, 0))}
            label={to_string(component)}
            value={check.status}
            tone={if check.status == "ok", do: "neutral", else: "danger"}
            note={check[:error_class]}
          />
        </div>
        <p class="tile-note">
          Full detail, including the usage ledger, is on the
          <.link navigate={~p"/console/operations"}>operations page</.link>.
        </p>
      </.panel>

      <.panel
        :if={@usage}
        title="Recorded usage"
        description="Counted from this installation's own ledger. The cost figure names its planning-reference or operator rate profile; there is no hidden billing state behind it."
      >
        <div class="tiles">
          <.tile label="API requests" value={@usage.api_requests} />
          <.tile label="Ingests" value={@usage.ingests} />
          <.tile label="Input tokens" value={@usage.tokens.input} />
          <.tile label="Output tokens" value={@usage.tokens.output} />
          <.tile label="Embedding tokens" value={@usage.tokens.embedding} />
          <.tile
            label="Estimated model cost"
            value={"#{@usage.estimated_model_cost} #{@usage.currency}"}
          />
          <.tile label="Cost profile" value={@usage.model_cost_profile.id} />
        </div>
      </.panel>

      <.panel
        title="Recent lifecycle activity"
        description="Every state change leaves an event. These carry no statement text — follow a row to read the claim itself."
      >
        <.empty :if={@overview.recent_events == []} message="No statement has changed state yet." />

        <table :if={@overview.recent_events != []} class="grid">
          <thead>
            <tr>
              <th>When</th>
              <th>Statement</th>
              <th>Scope</th>
              <th>Change</th>
              <th>Reason</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={event <- @overview.recent_events}>
              <td class="nowrap">{timestamp(event.occurred_at)}</td>
              <td>
                <.id_chip
                  value={event.knowledge_item_id}
                  navigate={~p"/console/knowledge/#{event.knowledge_item_id}"}
                />
              </td>
              <td>{scope_path(@overview.scope_paths, event.scope_id)}</td>
              <td>
                <span :if={event.from_state} class="muted">{event.from_state} →</span>
                <.badge family="state" value={event.to_state} />
              </td>
              <td class="muted">{event.reason}</td>
            </tr>
          </tbody>
        </table>
      </.panel>

      <.panel
        :if={@overview.dirty_projection_count > 0}
        title="Derived caches"
        description="Context projections are rebuildable caches, not a system of record. A dirty one simply has not been recomputed yet; nothing is lost."
      >
        <p>{@overview.dirty_projection_count} cached projection(s) are marked for refresh.</p>
      </.panel>
    </.shell>
    """
  end

  # Stable ties prevent charts from reshuffling between reloads.
  defp sorted_counts(counts) do
    counts
    |> Enum.sort_by(fn {label, count} -> {-count, label} end)
    |> Enum.map(fn {label, count} -> {label, count} end)
  end

  # Non-curator queue counts include only items awaiting that subject.
  defp queue_note(actor) do
    if Access.can?(actor, :curate) do
      "Open items in the curator queue"
    else
      "Items waiting on your answer"
    end
  end
end
