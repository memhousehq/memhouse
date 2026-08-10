# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleLive.Tools do
  @moduledoc """
  Browser workbench for the complete MCP tool inventory at `/console/tools`.

  Every form invokes the same non-persisted Ash action published through
  `MemHouse.Governance`, so argument casting, Account derivation, scope policy,
  inline validation attachment, and response shape stay aligned with MCP. The
  browser session supplies the actor; no form may select an Account or another
  calling peer.

  The page groups tools by intent and carries one shared session and scope, but
  the submitted arguments are still exactly the action's declared arguments: a
  card may override the shared context, and nothing else about the call is
  derived from the grouping. Summaries are a reading aid over the same payload,
  never a substitute for it, so the exact returned value stays on the page.

  Results are rendered only into the signed-in LiveView. They must never be
  copied into logs, telemetry, audit metadata, or job arguments.

  One control on this page is not a tool: diagnostic mode reproduces retrieval
  behavior for an account administrator through
  `MemHouse.Memory.diagnostic_search/2`, which re-authorizes the caller and
  owns the internal options. Its results are deliberately not
  production-equivalent and are rendered apart from the tool runs so the two
  cannot be mistaken for each other.
  """

  use MemHouseWeb, :live_view

  import MemHouseWeb.ConsoleComponents

  alias MemHouse.Governance.McpTools
  alias MemHouse.Memory
  alias MemHouseWeb.Console.Access
  alias MemHouseWeb.Console.Diagnostic
  alias MemHouseWeb.Console.Loader

  # Kept as a list rather than a map so declaration order is the render order
  # within a group, and so the human title, submit label, and consequence text
  # live next to the action they describe.
  @tools [
    %{
      key: "ask",
      action: :ask,
      group: :retrieve,
      title: "Ask memory",
      submit: "Ask memory",
      effect: "Governed read",
      write?: false,
      description:
        "Answer a question from governed statements, with citations and an explicit abstention when the evidence is insufficient.",
      consequence: "Reads only statements you may already see. Nothing is written."
    },
    %{
      key: "search",
      action: :search,
      group: :retrieve,
      title: "Search memory",
      submit: "Search memory",
      effect: "Governed read",
      write?: false,
      description:
        "Rank governed memory and report which retrieval strategies contributed, missed, or timed out.",
      consequence: "Reads only statements you may already see. Nothing is written."
    },
    %{
      key: "get_context",
      action: :get_context,
      group: :retrieve,
      title: "Load context",
      submit: "Load context",
      effect: "Governed read",
      write?: false,
      description:
        "Assemble reasoning-free context from projections, falling back to fast retrieval on a cache miss.",
      consequence: "Reads cached projections. No model runs and nothing is written."
    },
    %{
      key: "query_knowledge",
      action: :query_knowledge,
      group: :retrieve,
      title: "Browse knowledge",
      submit: "Browse knowledge",
      effect: "Governed read",
      write?: false,
      description:
        "List governed statements by lifecycle state. This is structured enumeration, not ranked retrieval.",
      consequence: "Reads only statements you may already see. Nothing is written."
    },
    %{
      key: "ingest",
      action: :ingest,
      group: :operate,
      title: "Save observation",
      submit: "Save observation",
      effect: "Writes an observation",
      write?: true,
      description:
        "Submit one raw observation. It is persisted and queued; only the pipeline may produce knowledge from it.",
      consequence:
        "This stores a raw observation in the chosen scope and queues extraction. It cannot be unsent."
    },
    %{
      key: "resolve_validation",
      action: :resolve_validation,
      group: :operate,
      title: "Resolve validation",
      submit: "Resolve validation",
      effect: "May change validation state",
      write?: true,
      description:
        "Answer one pending question addressed to you. Transcript evidence still decides whether the channel counts as verified.",
      consequence:
        "This records your verdict against a pending question and may change a statement's validation state."
    },
    %{
      key: "set_ask_preference",
      action: :set_ask_preference,
      group: :operate,
      title: "Update question limits",
      submit: "Update question limits",
      effect: "Tightens your preferences",
      write?: true,
      description:
        "Reduce your inline-question limits or pause questions. This tool can tighten settings, never loosen them.",
      consequence:
        "This lowers your own inline-question limits or extends your pause. It cannot raise them again here."
    },
    %{
      key: "check_readiness",
      action: :check_readiness,
      group: :evaluate,
      title: "Check readiness",
      submit: "Check readiness",
      effect: "Governed read",
      write?: false,
      description:
        "Evaluate inherited skill requirements against authorized, usable knowledge without running a model.",
      consequence: "Evaluates requirements only. No model runs and nothing is written."
    }
  ]

  @groups [
    %{
      key: :retrieve,
      title: "Retrieve",
      description: "Read what memory already holds. These calls write nothing."
    },
    %{
      key: :operate,
      title: "Operate",
      description:
        "These calls change durable state under your own identity. Read the consequence before you submit."
    },
    %{
      key: :evaluate,
      title: "Evaluate",
      description: "Check whether memory is good enough to run a skill."
    }
  ]

  # Ordered so a run's context summary reads like the form, and so a parameter
  # that is not a declared argument of any tool never reaches the summary.
  @context_labels [
    {"session_id", "Session"},
    {"scope_path", "Scope"},
    {"role", "Role"},
    {"content", "Content"},
    {"query", "Query"},
    {"question", "Question"},
    {"state", "State"},
    {"skill", "Skill"},
    {"profile", "Retrieval profile"},
    {"limit", "Limit"},
    {"_id", "Validation id"},
    {"verdict", "Verdict"},
    {"shown_text", "Shown text"},
    {"correction_text", "Correction text"},
    {"max_per_session", "Max per session"},
    {"max_per_day", "Max per day"},
    {"pause_for_hours", "Pause for hours"}
  ]

  # Enough to compare a run with the one before it without turning the page
  # into a transcript. Older runs are dropped, never persisted.
  @history_limit 5

  # The candidate limit the memory facade applies when a form names none. Kept
  # here only to describe a run the page did not set a limit on; the facade
  # remains the authority.
  @default_limit 12

  @doc """
  Loads authorized scope choices and seeds the shared run context.
  """
  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_actor
    scopes = Loader.skills(actor).scopes

    {:ok,
     socket
     |> assign(:scopes, scopes)
     |> assign(:session_id, "console-#{Ecto.UUID.generate()}")
     |> assign(:scope_path, default_scope_path(scopes))
     |> assign(:runs, [])
     |> assign(:run_count, 0)
     |> assign(:can_diagnose?, Access.can?(actor, :administer))
     |> assign(:diagnostic_open?, false)
     |> assign(:diagnostic, nil)}
  end

  @doc """
  Handles the page's six events.

  `"context"` stores the shared session and scope so every card starts from one
  context, and `"new-session"` replaces the session id. `"run"` invokes one
  allowlisted tool through the same Ash action used by MCP: empty optional
  fields are omitted so action defaults remain authoritative, and a failure
  returns one opaque browser message without logging or reflecting action
  internals into the page. Earlier runs survive a failure so the context that
  produced them is not lost, until `"clear-runs"` discards them.

  `"toggle-diagnostic"` opens or closes retrieval diagnostic mode and
  `"run-diagnostic"` performs one diagnostic run. Both refuse a non-administrator
  rather than trusting the rendered page, because an event can be sent by hand;
  the operation layer refuses the run again regardless.
  """
  @impl true
  def handle_event("context", params, socket) do
    {:noreply,
     socket
     |> assign(:session_id, Map.get(params, "session_id", socket.assigns.session_id))
     |> assign(:scope_path, Map.get(params, "scope_path", socket.assigns.scope_path))}
  end

  def handle_event("new-session", _params, socket) do
    {:noreply, assign(socket, :session_id, "console-#{Ecto.UUID.generate()}")}
  end

  def handle_event("run", %{"tool" => key} = params, socket) do
    with {:ok, tool} <- fetch_tool(key),
         input <-
           Ash.ActionInput.for_action(
             McpTools,
             tool.action,
             action_arguments(tool.action, params)
           ),
         {:ok, result} <- run_action(input, socket.assigns.current_actor) do
      count = socket.assigns.run_count + 1
      result = browser_result(tool, params, result, socket.assigns.current_actor)

      run = %{
        number: count,
        tool: tool,
        context: context_rows(params),
        summary: summary_rows(tool, result),
        window_note: window_note(tool, params, result),
        json: Jason.encode!(result, pretty: true)
      }

      {:noreply,
       socket
       |> assign(:run_count, count)
       |> assign(:runs, Enum.take([run | socket.assigns.runs], @history_limit))
       |> clear_flash()}
    else
      _error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Tool call failed. Check the fields and your access, then try again."
         )}
    end
  end

  def handle_event("clear-runs", _params, socket) do
    {:noreply, assign(socket, :runs, [])}
  end

  def handle_event("toggle-diagnostic", _params, %{assigns: %{can_diagnose?: true}} = socket) do
    {:noreply, assign(socket, :diagnostic_open?, not socket.assigns.diagnostic_open?)}
  end

  def handle_event("run-diagnostic", params, %{assigns: %{can_diagnose?: true}} = socket) do
    query = Map.get(params, "query", "")
    scope_path = Map.get(params, "scope_path", socket.assigns.scope_path)
    profile = Map.get(params, "profile", "balanced")

    attrs = %{
      "query" => query,
      "scope_path" => scope_path,
      "profile" => profile,
      "limit" => Map.get(params, "limit"),
      "strategies" => Map.get(params, "strategies", []),
      "deadline" => if(params["deadline"] == "on", do: "enabled", else: "disabled"),
      "rerank" => params["rerank"],
      "trace" => params["trace"] == "on"
    }

    case run_diagnostic(attrs, socket.assigns.current_actor) do
      {:ok, result} ->
        block = Map.fetch!(result, "diagnostic")
        only_dependent? = params["query_dependent_only"] == "on"

        # Stamp the fused rank before filtering, so a narrowed list still shows
        # where each candidate actually placed rather than renumbering from one.
        candidates =
          result
          |> Map.get("candidates", [])
          |> Enum.with_index(1)
          |> Enum.map(fn {candidate, rank} -> Map.put(candidate, "fused_rank", rank) end)

        diagnostic = %{
          query: query,
          scope_path: scope_path,
          profile: profile,
          block: block,
          only_dependent?: only_dependent?,
          candidates:
            if(only_dependent?,
              do: Diagnostic.query_dependent_only(candidates, block),
              else: candidates
            ),
          total: length(candidates),
          trace: Map.get(result, "diagnostic_trace"),
          request_json: Diagnostic.request_json(scope_path, query, profile, block),
          json: Jason.encode!(result, pretty: true)
        }

        {:noreply, socket |> assign(:diagnostic, diagnostic) |> clear_flash()}

      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Diagnostic run failed. Check the scope, the query, and your access, then try again."
         )}
    end
  end

  # A hand-sent event from anyone else is refused here and would be refused
  # again by the operation layer; neither check depends on the other.
  def handle_event(event, _params, socket) when event in ~w(toggle-diagnostic run-diagnostic) do
    {:noreply, put_flash(socket, :error, "Retrieval diagnostics are for account administrators.")}
  end

  @doc """
  Renders the shared context, the grouped tool cards, and recent run results.
  """
  @impl true
  def render(assigns) do
    assigns = assign(assigns, :groups, @groups)

    ~H"""
    <.shell actor={@current_actor} active={:tools} title="Tool workbench" flash={@flash}>
      <:subtitle>
        Run everything an agent can reach at <code>/mcp</code>, under your signed-in identity.
        These are the real operations against your own memory, not sample data.
      </:subtitle>

      <%!--
        One datalist serves every scope control on the page, so it has to sit
        outside all of the forms. Options are the paths the viewer may already
        read; typing an unauthorized path fails downstream like any other bad
        argument.
      --%>
      <datalist id="scope-options">
        <option :for={scope <- @scopes} value={scope.path}></option>
      </datalist>

      <.panel
        title="Run context"
        description="Set the session and scope once. Any card can override them for a single run."
      >
        <form id="run-context" class="context-bar" phx-change="context" phx-submit="context">
          <.field label="Session id" help="Reuse one id to keep calls part of the same interaction.">
            <input name="session_id" value={@session_id} autocomplete="off" spellcheck="false" />
          </.field>
          <.field label="Scope" help={scope_help(@scopes, @scope_path)}>
            <input
              name="scope_path"
              value={@scope_path}
              list="scope-options"
              autocomplete="off"
              spellcheck="false"
            />
          </.field>
        </form>
        <div class="button-row">
          <button type="button" class="ghost" phx-click="new-session">Start a new session id</button>
          <span class="hint">{length(@scopes)} scopes you can reach</span>
        </div>
      </.panel>

      <.panel
        :if={@runs != []}
        title={"#{hd(@runs).tool.title} · run #{hd(@runs).number}"}
        description="The payload is the exact value returned by the underlying action. Content stays in this browser session."
      >
        <.run_body run={hd(@runs)} open />
        <div class="button-row">
          <button type="button" class="ghost" phx-click="clear-runs">Clear results</button>
        </div>
      </.panel>

      <.panel :if={length(@runs) > 1} title="Earlier runs" description="Kept only in this page.">
        <details :for={run <- tl(@runs)} class="earlier-run">
          <summary>
            <span class="run-title">{run.tool.title}</span>
            <span class="muted">run {run.number}</span>
          </summary>
          <.run_body run={run} />
        </details>
      </.panel>

      <.diagnostic_panel
        :if={@can_diagnose?}
        open={@diagnostic_open?}
        diagnostic={@diagnostic}
        scope_path={@scope_path}
      />

      <section :for={group <- @groups} class="tool-group">
        <header class="group-head">
          <h2>{group.title}</h2>
          <p>{group.description}</p>
        </header>

        <div class="tool-grid">
          <.tool_panel :for={tool <- tools_in(group.key)} tool={tool}>
            <.tool_fields tool={tool} session_id={@session_id} scope_path={@scope_path} />
          </.tool_panel>
        </div>
      </section>
    </.shell>
    """
  end

  attr :open, :boolean, required: true
  attr :diagnostic, :map, default: nil
  attr :scope_path, :string, required: true

  defp diagnostic_panel(assigns) do
    assigns =
      assigns
      |> assign(:strategy_options, Diagnostic.strategy_options())
      |> assign(:limit_cap, Diagnostic.limit_cap())

    ~H"""
    <section class="panel diagnostic-panel" id="retrieval-diagnostic" aria-labelledby="retrieval-diagnostic-title">
      <header class="tool-head">
        <div>
          <h2 id="retrieval-diagnostic-title">Retrieval diagnostic</h2>
          <p>
            Reproduce what retrieval did, with the internal controls the ordinary
            forms deliberately do not offer. Account administrators only.
          </p>
        </div>
        <span class="badge state-pending"><span aria-hidden="true">⚑</span> Not production-equivalent</span>
      </header>

      <div class="button-row">
        <button type="button" class="ghost" phx-click="toggle-diagnostic" aria-expanded={to_string(@open)} aria-controls="retrieval-diagnostic-form">
          {if @open, do: "Close diagnostic mode", else: "Open diagnostic mode"}
        </button>
        <span class="hint">Ordinary search and ask keep their normal defaults.</span>
      </div>

      <div :if={@open} id="retrieval-diagnostic-form">
        <p class="consequence">
          A diagnostic run may look past the ordinary result window, run one
          strategy alone, drop the latency deadline, and turn reranking off. Its
          order is evidence about retrieval, not a better answer, and it shows
          only statements you may already read.
        </p>

        <form phx-submit="run-diagnostic" class="tool-form">
          <.field label="Query" class="full">
            <input name="query" required autocomplete="off" placeholder="What should memory find?" />
          </.field>
          <.field label="Scope">
            <input
              name="scope_path"
              value={@scope_path}
              list="scope-options"
              required
              autocomplete="off"
              spellcheck="false"
            />
          </.field>
          <.field label="Retrieval profile">
            <select name="profile">
              <option :for={profile <- ~w(fast balanced thorough)} value={profile} selected={profile == "balanced"}>
                {profile}
              </option>
            </select>
          </.field>
          <.field label="Limit" help={"Up to #{@limit_cap}. The ordinary window is 12."}>
            <input name="limit" type="number" min="1" max={@limit_cap} step="1" value="50" />
          </.field>
          <.field label="Reranking" help="The profile decides unless you force it.">
            <select name="rerank">
              <option value="">profile default</option>
              <option value="true">forced on</option>
              <option value="false">forced off</option>
            </select>
          </.field>

          <fieldset class="full strategy-set">
            <legend>Strategies</legend>
            <p class="field-help">
              Leave every box clear to run the profile's own strategies. A run
              whose strategies all ignore the query ranks the scope instead.
            </p>
            <label :for={{name, dependent?} <- @strategy_options} class="strategy-choice">
              <input type="checkbox" name="strategies[]" value={name} />
              <span>
                {name}<span :if={not dependent?} class="optional">query-independent</span>
              </span>
            </label>
          </fieldset>

          <label class="full ack">
            <input type="checkbox" name="deadline" checked />
            <span>Keep the latency deadline. Clear it to let every strategy finish, which no request path may do.</span>
          </label>

          <label class="full ack">
            <input type="checkbox" name="query_dependent_only" />
            <span>Show only candidates a query-dependent strategy voted for.</span>
          </label>

          <label class="full ack">
            <input type="checkbox" name="trace" />
            <span>Explain the ranking. Scores are local to each strategy and are not comparable between them; compare ranks and fusion contributions.</span>
          </label>

          <div class="full button-row">
            <button class="primary" phx-disable-with="Running…">Run diagnostic</button>
            <span class="technical">Reads <code>search</code> internals</span>
          </div>
        </form>

        <.diagnostic_result :if={@diagnostic} diagnostic={@diagnostic} />
      </div>
    </section>
    """
  end

  attr :diagnostic, :map, required: true

  defp diagnostic_result(assigns) do
    ~H"""
    <div class="diagnostic-result">
      <p class="technical">Diagnostic result · not production-equivalent</p>

      <dl class="run-summary">
        <div class="run-row">
          <dt>Candidates</dt>
          <dd>{@diagnostic.total}</dd>
        </div>
        <div class="run-row">
          <dt>Beyond the ordinary window</dt>
          <dd>{@diagnostic.block["beyond_default_limit"]} past rank {@diagnostic.block["default_limit"]}</dd>
        </div>
        <div class="run-row">
          <dt>Strategies reading the query</dt>
          <dd>{strategy_list(@diagnostic.block["query_dependent_strategies"])}</dd>
        </div>
        <div class="run-row">
          <dt>Deadline</dt>
          <dd>{@diagnostic.block["deadline"]}</dd>
        </div>
        <div class="run-row">
          <dt>Reranking</dt>
          <dd>{rerank_label(@diagnostic.block["rerank"])}</dd>
        </div>
      </dl>

      <p :if={@diagnostic.block["beyond_default_limit"] > 0} class="consequence">
        {@diagnostic.block["beyond_default_limit"]} candidates rank below the ordinary
        top-{@diagnostic.block["default_limit"]} window, so a normal run would not have shown them.
        That does not make them the right answer.
      </p>

      <p :if={@diagnostic.only_dependent? and @diagnostic.candidates == []} class="consequence">
        No query-dependent strategy voted for any candidate. Everything this run
        returned ranked the scope rather than the question.
      </p>

      <ol :if={@diagnostic.candidates != []} class="diagnostic-candidates">
        <li :for={candidate <- @diagnostic.candidates} value={candidate["fused_rank"]}>
          <div class="candidate-head">
            <span class="muted">{candidate["scope_path"]}</span>
            <span class="technical">{strategy_list(candidate["strategies"])}</span>
          </div>
          <p class="candidate-statement">
            <%= for {kind, part} <- Diagnostic.segments(candidate["statement"] || "", @diagnostic.query) do %><mark :if={kind == :match}>{part}</mark><span :if={kind == :plain}>{part}</span><% end %>
          </p>
        </li>
      </ol>

      <.rank_trace :if={@diagnostic.trace} trace={@diagnostic.trace} />

      <details class="run-raw">
        <summary>Reproducible request</summary>
        <pre id="diagnostic-request" class="code">{@diagnostic.request_json}</pre>
      </details>

      <details class="run-raw">
        <summary>Raw payload</summary>
        <pre id="diagnostic-payload" class="code tool-result">{@diagnostic.json}</pre>
      </details>
    </div>
    """
  end

  attr :trace, :map, required: true

  defp rank_trace(assigns) do
    ~H"""
    <details class="retrieval-trace">
      <summary>Rank explanation</summary>
      <p class="hint">
        Ranks are comparable across strategies. Scores are local to each strategy
        and are not. <code>outside_rerank_head</code> means the candidate stayed in
        the fused tail; <code>rerank_unavailable</code> means the reranker did not
        complete.
      </p>
      <div class="table-scroll">
        <table class="grid compact">
          <thead>
            <tr><th>Candidate</th><th>Fused</th><th>Final</th><th>Rerank</th><th>Strategy details</th></tr>
          </thead>
          <tbody>
            <tr :for={candidate <- @trace["candidates"]}>
              <td><code>{candidate["id"]}</code></td>
              <td>{candidate["fused_rank"]}</td>
              <td>{candidate["final_rank"]}</td>
              <td>{candidate["rerank_status"]}</td>
              <td>
                <details>
                  <summary>{length(candidate["strategies"])} strategies</summary>
                  <table class="grid compact">
                    <thead><tr><th>Strategy</th><th>Local rank</th><th>Local score</th><th>Fusion contribution</th></tr></thead>
                    <tbody>
                      <tr :for={strategy <- candidate["strategies"]}>
                        <td>{strategy["strategy"]}</td>
                        <td>{strategy["local_rank"]}</td>
                        <td>{number(strategy["local_score"])}</td>
                        <td>{number(strategy["fusion_contribution"])}</td>
                      </tr>
                    </tbody>
                  </table>
                </details>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  attr :tool, :map, required: true
  slot :inner_block, required: true

  defp tool_panel(assigns) do
    ~H"""
    <section
      class={["panel", "tool-panel", @tool.write? && "is-write"]}
      id={"tool-#{@tool.key}"}
      aria-labelledby={"tool-#{@tool.key}-title"}
    >
      <header class="tool-head">
        <div>
          <h3 id={"tool-#{@tool.key}-title"}>{@tool.title}</h3>
          <p>{@tool.description}</p>
        </div>
        <span class={["badge", @tool.write? && "state-pending"]}>
          <span aria-hidden="true">{if @tool.write?, do: "▲", else: "▾"}</span> {@tool.effect}
        </span>
      </header>

      <form phx-submit="run" class="tool-form">
        <input type="hidden" name="tool" value={@tool.key} />
        {render_slot(@inner_block)}

        <%!--
          The acknowledgement is a browser-side affordance only. The operation
          layer re-authorizes every write, so a hand-crafted event that omits
          it is refused there rather than here.
        --%>
        <label :if={@tool.write?} class="full ack">
          <input type="checkbox" name="_ack" required />
          <span>{@tool.consequence}</span>
        </label>
        <p :if={!@tool.write?} class="full consequence">{@tool.consequence}</p>

        <div class="full button-row">
          <button class="primary" phx-disable-with="Running…">{@tool.submit}</button>
          <span class="technical">Action <code>{@tool.key}</code></span>
        </div>
      </form>
    </section>
    """
  end

  attr :tool, :map, required: true
  attr :session_id, :string, required: true
  attr :scope_path, :string, required: true

  defp tool_fields(%{tool: %{key: "ask"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field label="Question" class="full">
      <textarea name="question" rows="3" required placeholder="What do we know?"></textarea>
    </.field>
    <.profile selected="thorough" />
    """
  end

  defp tool_fields(%{tool: %{key: "search"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field label="Query" class="full">
      <input name="query" required autocomplete="off" placeholder="What should memory find?" />
    </.field>
    <.profile selected="balanced" />
    <.limit />
    """
  end

  defp tool_fields(%{tool: %{key: "get_context"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field label="Query" optional class="full" help="Narrows the context to what this turn is about.">
      <input name="query" autocomplete="off" placeholder="What this turn is about" />
    </.field>
    <.limit />
    """
  end

  defp tool_fields(%{tool: %{key: "query_knowledge"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field
      label="Lifecycle state"
      optional
      help="Left empty, this lists active statements plus your own provisional ones."
    >
      <select name="state">
        <option value="">active plus your provisional statements</option>
        <option
          :for={
            state <-
              ~w(active provisional proposed held needs_revalidation expired superseded rejected contested redacted retracted)
          }
          value={state}
        >
          {state}
        </option>
      </select>
    </.field>
    <.limit />
    """
  end

  defp tool_fields(%{tool: %{key: "ingest"}} = assigns) do
    ~H"""
    <.context_override session_id={@session_id} scope_path={@scope_path} />
    <.field label="Role" help="Who the observation came from. Defaults to user.">
      <select name="role">
        <option :for={role <- ~w(user assistant system tool)} value={role}>{role}</option>
      </select>
    </.field>
    <.field label="Content" class="full">
      <textarea name="content" rows="5" required placeholder="The observation to remember"></textarea>
    </.field>
    """
  end

  defp tool_fields(%{tool: %{key: "check_readiness"}} = assigns) do
    ~H"""
    <.context_override
      session_id={@session_id}
      scope_path={@scope_path}
      optional_session
    />
    <.field label="Skill key" class="full" help="The skill card key, for example write-copy.">
      <input name="skill" required autocomplete="off" placeholder="write-copy" />
    </.field>
    """
  end

  defp tool_fields(%{tool: %{key: "resolve_validation"}} = assigns) do
    ~H"""
    <.field
      label="Validation id"
      class="full"
      help="The id returned as pending_validation on an earlier read."
    >
      <input name="_id" required autocomplete="off" placeholder="UUID from pending_validation" />
    </.field>
    <.field label="Verdict">
      <select name="verdict" required>
        <option :for={verdict <- ~w(confirm reject unsure skip)} value={verdict}>{verdict}</option>
      </select>
    </.field>
    <.field
      label="Shown text"
      optional
      class="full"
      help="What you were shown. Only its hash is stored, to check the wording was not altered."
    >
      <textarea name="shown_text" rows="3" placeholder="Frozen statement shown to you"></textarea>
    </.field>
    <.field
      label="Correction text"
      optional
      class="full"
      help="Evidence only. A correction becomes knowledge only when you save it as an observation."
    >
      <textarea name="correction_text" rows="3" placeholder="Evidence only; ingest a correction separately">
      </textarea>
    </.field>
    """
  end

  defp tool_fields(%{tool: %{key: "set_ask_preference"}} = assigns) do
    ~H"""
    <.field label="Max per session" optional help="Zero means never ask during a session.">
      <input name="max_per_session" type="number" min="0" step="1" />
    </.field>
    <.field label="Max per day" optional help="Zero means never ask at all.">
      <input name="max_per_day" type="number" min="0" step="1" />
    </.field>
    <.field label="Pause for hours" optional class="full" help="Stored as an absolute resume time.">
      <input name="pause_for_hours" type="number" min="0" step="1" />
    </.field>
    """
  end

  attr :session_id, :string, required: true
  attr :scope_path, :string, required: true
  attr :optional_session, :boolean, default: false

  defp context_override(assigns) do
    ~H"""
    <%!--
      Collapsed by default: the shared bar above already answers "which session
      and scope is this?", and repeating two controls on every card is what made
      the page feel like a form dump. The fields stay in the form so a single
      card can still deviate without changing the page-wide context.
    --%>
    <details class="full context-override">
      <summary>
        <span class="muted">Context</span>
        <code>{@session_id}</code>
        <code>{@scope_path}</code>
      </summary>
      <div class="override-fields">
        <.field label="Session id" optional={@optional_session}>
          <input
            name="session_id"
            value={@session_id}
            required={!@optional_session}
            autocomplete="off"
            spellcheck="false"
          />
        </.field>
        <.field label="Scope">
          <input
            name="scope_path"
            value={@scope_path}
            list="scope-options"
            required
            autocomplete="off"
            spellcheck="false"
          />
        </.field>
      </div>
    </details>
    """
  end

  attr :selected, :string, required: true

  defp profile(assigns) do
    ~H"""
    <.field label="Retrieval profile" help={"Defaults to #{@selected}: more work, slower answer."}>
      <select name="profile">
        <option :for={profile <- ~w(fast balanced thorough)} value={profile} selected={profile == @selected}>
          {profile}{if profile == @selected, do: " (default)"}
        </option>
      </select>
    </.field>
    """
  end

  defp limit(assigns) do
    ~H"""
    <.field label="Limit" optional help="Rows to return. Defaults to 12.">
      <input name="limit" type="number" min="1" step="1" placeholder="12" />
    </.field>
    """
  end

  attr :label, :string, required: true
  attr :help, :string, default: nil
  attr :optional, :boolean, default: false
  attr :class, :string, default: nil
  slot :inner_block, required: true

  # The label wraps its control, so the control needs no id to be named, and the
  # help text stays inside the label so assistive technology reads the reason a
  # choice matters rather than only the field name.
  defp field(assigns) do
    ~H"""
    <div class={["field", @class]}>
      <label>
        <span class="field-label">
          {@label}<span :if={@optional} class="optional">optional</span>
        </span>
        {render_slot(@inner_block)}
        <span :if={@help} class="field-help">{@help}</span>
      </label>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :open, :boolean, default: false

  defp run_body(assigns) do
    ~H"""
    <p class="technical">Result · {@run.tool.key}</p>

    <p :if={@run.window_note} class="consequence">{@run.window_note}</p>

    <dl :if={@run.summary != []} class="run-summary">
      <div :for={{label, value} <- @run.summary} class="run-row">
        <dt>{label}</dt>
        <dd>{value}</dd>
      </div>
    </dl>

    <details :if={@run.context != []} class="run-context">
      <summary>What was submitted</summary>
      <dl class="run-summary">
        <div :for={{label, value} <- @run.context} class="run-row">
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      </dl>
    </details>

    <details open={@open} class="run-raw">
      <summary>Raw payload</summary>
      <pre id={"tool-result-#{@run.number}"} class="code tool-result">{@run.json}</pre>
    </details>
    """
  end

  defp tools_in(group), do: Enum.filter(@tools, &(&1.group == group))

  defp strategy_list([]), do: "none"
  defp strategy_list(names) when is_list(names), do: Enum.join(names, ", ")
  defp strategy_list(_names), do: "none"

  defp rerank_label(true), do: "forced on"
  defp rerank_label(false), do: "forced off"
  defp rerank_label(_value), do: "profile default"

  # A ranked read that filled its window stopped at the limit rather than at the
  # end of the matches. Saying so is what keeps the top-12 default honest, and it
  # is said for every viewer, not only the administrators who can diagnose it.
  defp window_note(%{key: key}, params, result) when key in ["search", "ask"] do
    limit = parse_limit(Map.get(params, "limit"))

    case Map.get(result, "candidates") do
      candidates when is_list(candidates) -> Diagnostic.window_note(length(candidates), limit)
      _other -> nil
    end
  end

  defp window_note(_tool, _params, _result), do: nil

  # Mirrors the facade's own fallback so the note describes the limit that ran.
  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {limit, _rest} when limit > 0 -> limit
      _other -> @default_limit
    end
  end

  defp parse_limit(_value), do: @default_limit

  defp fetch_tool(key) do
    case Enum.find(@tools, &(&1.key == key)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  defp default_scope_path([scope | _rest]), do: scope.path
  defp default_scope_path(_scopes), do: ""

  # Says what the chosen scope is without listing the tree again, and names an
  # unauthorized path plainly so a typo does not look like an empty account.
  defp scope_help(scopes, path) do
    cond do
      path in ["", nil] ->
        "Choose one of your authorized scopes."

      Enum.any?(scopes, &(&1.path == path)) ->
        depth = path |> String.split("/", trim: true) |> length()
        "Depth #{depth}. Knowledge inherits down from here; the nearest scope wins."

      true ->
        "Not a scope you can read. Calls using it will be refused."
    end
  end

  defp context_rows(params) do
    for {parameter, label} <- @context_labels,
        value = Map.get(params, parameter),
        value not in [nil, ""],
        do: {label, truncate(to_string(value), 160)}
  end

  # A reading aid over the payload below it, not a second source of truth: every
  # row is copied from a key the action actually returned, and a key the action
  # omitted produces no row rather than a guessed default.
  defp summary_rows(%{key: "ingest"}, result) do
    rows([{"Status", value(result, "status")}, {"Message id", value(result, "message_id")}])
  end

  defp summary_rows(%{key: "get_context"}, result) do
    rows([
      {"Knowledge items", count(result, "knowledge")},
      {"Scope cards", count(result, "scope_cards")},
      {"Projection cache hit", value(result, "projection_cache_hit")},
      {"Fast fallback", value(result, "fast_fallback")},
      {"Inline question", pending(result)}
    ])
  end

  defp summary_rows(%{key: "search"}, result) do
    rows([
      {"Candidates", count(result, "candidates")},
      {"Retrieval profile", value(result, "profile")},
      {"Strategies contributed", count(result, "contributed_strategies")},
      {"Strategies empty", count(result, "empty_strategies")},
      {"Latency", latency(result)},
      {"Index health", retrieval_health(result)},
      {"Inline question", pending(result)}
    ])
  end

  defp summary_rows(%{key: "ask"}, result) do
    rows([
      {"Answer", truncate(to_string(value(result, "answer") || ""), 600)},
      {"Abstained", value(result, "abstained")},
      {"Answer confidence", value(result, "answer_confidence")},
      {"Answer degraded", value(result, "answer_degraded")},
      {"Citations", count(result, "citations")},
      {"Candidates", count(result, "candidates")},
      {"Supporting statements", count(result, "supporting_statements")},
      {"Index health", retrieval_health(result)},
      {"Inline question", pending(result)}
    ])
  end

  defp summary_rows(%{key: "query_knowledge"}, result) do
    rows([{"Statements", count(result, "data")}, {"Inline question", pending(result)}])
  end

  defp summary_rows(%{key: "check_readiness"}, result) do
    rows([
      {"Ready", value(result, "ready")},
      {"Skill", value(result, "skill")},
      {"Scope", value(result, "scope_path")},
      {"Requirements", count(result, "requirements")},
      {"Blockers", count(result, "blockers")},
      {"Warnings", count(result, "warnings")}
    ])
  end

  defp summary_rows(%{key: "resolve_validation"}, result) do
    rows([
      {"Verdict", value(result, "verdict")},
      {"Verified channel", value(result, "verified")},
      {"Effect", value(result, "effect")}
    ])
  end

  defp summary_rows(%{key: "set_ask_preference"}, result) do
    rows([
      {"Max per session", value(result, "max_per_session")},
      {"Max per day", value(result, "max_per_day")},
      {"Paused until", value(result, "paused_until")}
    ])
  end

  defp rows(pairs) do
    for {label, value} <- pairs, not is_nil(value), do: {label, display(value)}
  end

  # Read actions return string keys through the memory facade; the two
  # governance actions build their own maps with atom keys.
  defp value(result, key) when is_map(result) do
    case Map.fetch(result, key) do
      {:ok, value} -> value
      :error -> Map.get(result, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end

  defp value(_result, _key), do: nil

  defp count(result, key) do
    case value(result, key) do
      list when is_list(list) -> length(list)
      _other -> nil
    end
  end

  # Fusion contributions land around 1/60, so four places is the point where the
  # column still separates two adjacent ranks without printing float noise.
  defp number(value) when is_number(value), do: Float.round(value * 1.0, 4)

  defp pending(result) do
    if value(result, "pending_validation"), do: "one question attached"
  end

  # A degraded index answers with the same shape as a healthy one, so the state
  # belongs in the summary rather than only in the payload below it.
  defp retrieval_health(result) do
    case value(result, "retrieval_health") do
      %{state: state, next_action: nil} -> to_string(state)
      %{state: state, next_action: action} -> "#{state} — #{action}"
      _other -> nil
    end
  end

  defp latency(result) do
    case value(result, "latency_ms") do
      milliseconds when is_number(milliseconds) -> "#{milliseconds} ms"
      _other -> nil
    end
  end

  defp display(true), do: "yes"
  defp display(false), do: "no"
  defp display(value) when is_binary(value), do: value
  defp display(value), do: to_string(value)

  defp action_arguments(action, params) do
    McpTools
    |> Ash.Resource.Info.action(action)
    |> Map.fetch!(:arguments)
    |> Enum.reduce(%{}, fn argument, arguments ->
      parameter = if argument.name == :id, do: "_id", else: to_string(argument.name)

      case Map.get(params, parameter) do
        value when value in [nil, ""] -> arguments
        value -> Map.put(arguments, argument.name, value)
      end
    end)
  end

  # Browser-only addition, not part of the MCP or HTTP contract. The atom key is
  # what keeps it distinguishable from the action's own string-keyed payload.
  defp browser_result(%{key: key}, params, result, actor) when key in ["search", "ask"] do
    Map.put(
      result,
      :retrieval_health,
      Loader.retrieval_health(
        actor,
        Map.get(params, "scope_path"),
        Map.get(params, "query") || Map.get(params, "question")
      )
    )
  end

  defp browser_result(_tool, _params, result, _actor), do: result

  # Ash normally returns action failures as error tuples. These classes may be
  # raised by a downstream resource instead; keep the browser response equally
  # opaque in both cases so identifiers cannot be probed through error detail.
  # The operation layer authorizes the run and raises for anyone it refuses, as
  # well as for an unregistered strategy name. Both stay opaque in the browser
  # for the same reason a failed tool call does.
  defp run_diagnostic(attrs, actor) do
    {:ok, Memory.diagnostic_search(attrs, actor)}
  rescue
    _error in [
      Ash.Error.Forbidden,
      Ash.Error.Invalid,
      Ash.Error.Unknown,
      ArgumentError,
      KeyError
    ] ->
      :error
  end

  defp run_action(input, actor) do
    Ash.run_action(input, actor: actor)
  rescue
    _error in [
      Ash.Error.Forbidden,
      Ash.Error.Invalid,
      Ash.Error.Query.NotFound,
      Ash.Error.Unknown
    ] ->
      {:error, :tool_failed}
  end
end
