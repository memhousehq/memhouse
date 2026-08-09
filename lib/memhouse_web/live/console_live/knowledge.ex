# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleLive.Knowledge do
  @moduledoc """
  `/console/knowledge` browsing and retrieval for authorized statements.

  Two modes answer two questions. Browse enumerates exhaustively from stored
  rows; find ranks candidates and reports contributed, empty, and
  deadline-dropped strategies. Retrieval requires an explicit scope and runs
  only in find mode, so browsing never issues a search.

  URL query parameters hold every filter, the mode, sorting, and pagination, so
  a view is linkable and the browser's own history works.

  Loader visibility, Ash policies, and row-level security authorize results;
  page filters may only narrow them.
  """

  use MemHouseWeb, :live_view

  import MemHouseWeb.ConsoleComponents

  alias MemHouse.Knowledge.Statement
  alias MemHouse.Memory
  alias MemHouseWeb.Console.Access
  alias MemHouseWeb.Console.Loader

  # Allowlist query keys before building loader filters. `back` is deliberately
  # absent: the detail page builds its return link from these keys alone, so a
  # hand-edited value cannot travel any further than this list allows.
  @filter_keys ~w(mode scope state kind sensitivity target_level subject page per_page sort q)

  # Keys that narrow the population, in the order they are summarized.
  @narrowing_keys ~w(scope state kind sensitivity target_level subject)

  @kinds ~w(fact preference event relation skill)
  @levels ~w(public internal personal restricted)

  @doc """
  Mounts empty; `handle_params/3` loads initial and patched URLs identically.
  """
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, search: nil, now: DateTime.utc_now(), kinds: @kinds, levels: @levels)}
  end

  @doc """
  Loads URL-filtered browsing results and, in find mode, a scoped retrieval
  preview.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.take(params, @filter_keys)
    result = Loader.knowledge_list(socket.assigns.current_actor, filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:mode, mode(filters))
     |> assign(:result, result)
     |> assign(:now, DateTime.utc_now())
     |> assign(:search, retrieval_preview(socket.assigns.current_actor, filters))}
  end

  @doc """
  Writes non-blank filters to the URL and resets pagination.
  """
  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, patch_to(socket, Map.delete(params, "page"))}
  end

  def handle_event("page_size", %{"per_page" => per_page}, socket) do
    {:noreply,
     patch_to(
       socket,
       socket.assigns.filters |> Map.put("per_page", per_page) |> Map.delete("page")
     )}
  end

  def handle_event("clear", _params, socket) do
    # The mode is how the reader is working, not what they filtered to, so
    # clearing filters must not throw them back into the other mode.
    {:noreply, patch_to(socket, Map.take(socket.assigns.filters, ["mode"]))}
  end

  @doc """
  Renders the mode tabs, the filter panel, the retrieval preview, and the paged
  list.
  """
  @impl true
  def render(assigns) do
    ~H"""
    <.shell actor={@current_actor} active={:knowledge} title="Knowledge" flash={@flash}>
      <:subtitle>
        Every governed statement your roles reach. Browsing enumerates; retrieval ranks.
        They answer different questions, so they are separate modes.
      </:subtitle>

      <.tabs active={@mode}>
        <:tab
          key="browse"
          label="Browse"
          hint="Every statement, filtered"
          patch={~p"/console/knowledge?#{browse_params(@filters)}"}
        />
        <:tab
          key="find"
          label="Find"
          hint="Ranked retrieval preview"
          patch={~p"/console/knowledge?#{find_params(@filters)}"}
        />
      </.tabs>

      <.panel
        :if={@mode == "find"}
        title="Find relevant statements"
        description="Runs the same engine that answers an agent's search call, against one scope and everything above it. It ranks; it does not enumerate."
      >
        <form phx-change="filter" phx-submit="filter" class="filters">
          <input type="hidden" name="mode" value="find" />
          <label class="grow">
            Query
            <input
              name="q"
              value={@filters["q"]}
              placeholder="Ask retrieval what it would find"
              autocomplete="off"
            />
          </label>
          <.scope_field filters={@filters} result={@result} required />
          <span class="filter-busy" aria-hidden="true">Updating…</span>
        </form>
      </.panel>

      <.panel
        :if={@search}
        title="Retrieval preview"
        description="What the retrieval engine would return for this query, and how it got there."
      >
        <div class="tiles compact">
          <.tile label="Profile" value={@search["profile"]} note={@search["profile_version"]} />
          <.tile label="Latency" value={"#{@search["latency_ms"]} ms"} />
          <.tile label="Candidates" value={length(@search["candidates"])} />
          <.tile
            label="Strategies used"
            value={length(@search["contributed_strategies"])}
            note={strategy_note(@search)}
            tone={strategy_tone(@search)}
          />
        </div>

        <.empty
          :if={@search["candidates"] == []}
          message="Retrieval ranked nothing for that query in this scope. That is a ranking result, not proof the memory is empty — the exhaustive list below is the one that settles that."
        />

        <div :if={@search["candidates"] != []} class="table-scroll" tabindex="0" role="region" aria-label="Ranked candidates">
          <table class="grid cards">
            <thead>
              <tr>
                <th>#</th>
                <th>Candidate</th>
                <th>Source</th>
                <th>Score</th>
                <th>Found by</th>
              </tr>
            </thead>
            <tbody>
              <%!--
                Retrieval reports fused rank by position: the strategy-local
                scores it fuses are incomparable, so it publishes the order
                rather than a rank column.
              --%>
              <tr :for={{candidate, index} <- Enum.with_index(@search["candidates"], 1)}>
                <td class="nowrap" data-label="Rank">{index}</td>
                <td data-label="Candidate">
                  <.expandable text={candidate_statement(candidate)} length={160} />
                </td>
                <td class="nowrap" data-label="Source">
                  <.badge family="kind" value={candidate["candidate_type"] || "knowledge"} />
                  <.id_chip
                    :if={candidate["candidate_type"] in [nil, "knowledge"]}
                    value={candidate["id"]}
                    navigate={~p"/console/knowledge/#{candidate["id"]}?#{back_param(@filters)}"}
                  />
                </td>
                <td class="nowrap" data-label="Score">
                  {Float.round((candidate["rrf_score"] || 0) * 1.0, 4)}
                </td>
                <td class="muted" data-label="Found by">
                  {Enum.join(candidate["strategies"] || [], ", ")}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.panel>

      <.empty
        :if={@mode == "find" and is_nil(@search) and blank?(@filters["q"])}
        message="Enter a query and pick a scope. Retrieval searches one scope and everything above it, so it cannot run against the whole Account at once."
      />

      <.empty
        :if={@mode == "find" and is_nil(@search) and not blank?(@filters["q"])}
        message="Retrieval needs a scope. Pick one above — searching /team/project also searches /team and /. The exhaustive list below is unaffected."
      />

      <.panel
        :if={@mode == "browse"}
        title="Filter"
        description="Filters apply as you change them. A scope filter includes everything contained in that scope, because context flows down the tree."
      >
        <form phx-change="filter" phx-submit="filter" class="filters">
          <input type="hidden" name="mode" value="browse" />
          <.scope_field filters={@filters} result={@result} />

          <label>
            Lifecycle state
            <select name="state">
              <option value="">Any visible state</option>
              <option
                :for={state <- Access.visible_states(@current_actor)}
                value={state}
                selected={@filters["state"] == state}
              >
                {enum_label("state", state)}
              </option>
            </select>
          </label>

          <label>
            Kind
            <select name="kind">
              <option value="">Any kind</option>
              <option :for={kind <- @kinds} value={kind} selected={@filters["kind"] == kind}>
                {enum_label("kind", kind)}
              </option>
            </select>
          </label>

          <label>
            Sensitivity
            <select name="sensitivity">
              <option value="">Any sensitivity</option>
              <option
                :for={level <- @levels}
                value={level}
                selected={@filters["sensitivity"] == level}
              >
                {enum_label("sensitivity", level)}
              </option>
            </select>
          </label>

          <label>
            How wide it may travel
            <select name="target_level">
              <option value="">Any width</option>
              <option
                :for={level <- @levels}
                value={level}
                selected={@filters["target_level"] == level}
              >
                {enum_label("level", level)}
              </option>
            </select>
          </label>

          <label>
            Subject
            <select name="subject">
              <option value="">Anyone</option>
              <option value="me" selected={@filters["subject"] == "me"}>About me</option>
            </select>
          </label>

          <span class="filter-busy" aria-hidden="true">Updating…</span>
        </form>

        <.legend states={Access.visible_states(@current_actor)} />
      </.panel>

      <.panel
        title={list_title(@mode)}
        description={list_description(@mode, @result.sort)}
      >
        <div :if={active_filters(@filters) != []} class="filter-summary">
          <span class="filter-summary-label">Active filters</span>
          <.filter_chip
            :for={{key, label, value} <- active_filters(@filters)}
            label={label}
            value={value}
            patch={~p"/console/knowledge?#{Map.delete(@filters, key)}"}
          />
          <button type="button" class="ghost" phx-click="clear">Clear all</button>
        </div>

        <.empty :if={@result.items == [] and @result.filtered?} message={filtered_empty_message()} />
        <.empty :if={@result.items == [] and not @result.filtered?} message={unfiltered_empty_message()} />

        <div :if={@result.items != []} class="table-scroll" role="region" aria-label="Statements">
          <table class="grid cards statements">
            <thead>
              <tr>
                <th scope="col">Statement</th>
                <th scope="col">Status</th>
                <th scope="col" class="nowrap">
                  <.sort_link
                    filters={@filters}
                    sort={@result.sort}
                    key="confidence"
                    label="Confidence"
                  />
                </th>
                <th scope="col" class="nowrap">
                  <.sort_link filters={@filters} sort={@result.sort} key="recorded" label="Recorded" />
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={item <- @result.items}>
                <td data-label="Statement" class="statement-cell">
                  <.link
                    navigate={~p"/console/knowledge/#{item.id}?#{back_param(@filters)}"}
                    class="statement-link"
                  >
                    {truncate(statement_with_validity(item), 200)}
                  </.link>
                  <%!--
                    The link cannot also be the expander: a `details` element
                    inside an anchor is invalid, and a reader scanning a page
                    wants the rest of a sentence without losing their place.
                  --%>
                  <details :if={truncated?(statement_with_validity(item), 200)} class="expandable">
                    <summary>Show full text</summary>
                    <p class="expandable-full">{statement_with_validity(item)}</p>
                  </details>
                  <p class="statement-meta">
                    <.badge family="kind" value={item.kind} />
                    <.scope_crumb path={item.scope_path} id={"scope-#{item.id}"} />
                  </p>
                </td>
                <td data-label="Status">
                  <span class="badge-stack">
                    <.badge family="state" value={item.state} />
                    <.badge family="sensitivity" value={item.sensitivity} />
                  </span>
                </td>
                <td data-label="Confidence"><.confidence_meter value={item.confidence} /></td>
                <td data-label="Recorded" class="nowrap muted">
                  <.time at={item.inserted_at} now={@now} />
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <.pager
          :if={@result.total > 0}
          page={@result.page}
          page_count={@result.page_count}
          page_size={@result.page_size}
          total={@result.total}
          sizes={Loader.page_sizes()}
          page_href={fn page -> ~p"/console/knowledge?#{page_params(@filters, page)}" end}
        />
      </.panel>
    </.shell>
    """
  end

  # A datalist gives native typeahead over hundreds of generated paths without a
  # script, which the console's `script-src 'self'` policy makes the deciding
  # factor. An unknown path narrows to nothing in the loader rather than
  # widening, so free text is safe.
  attr :filters, :map, required: true
  attr :result, :map, required: true
  attr :required, :boolean, default: false

  defp scope_field(assigns) do
    ~H"""
    <label class="grow">
      Scope
      <input
        name="scope"
        value={@filters["scope"]}
        list="console-scope-paths"
        placeholder={(@required && "Required — start typing a path") || "All scopes you can read"}
        autocomplete="off"
      />
      <datalist id="console-scope-paths">
        <option :for={scope <- @result.scopes} value={scope.path} label={scope_leaf(scope.path)} />
      </datalist>
      <span :if={@result.descendant_count} class="field-note">
        Includes {@result.descendant_count} contained scope(s).
      </span>
    </label>
    """
  end

  attr :filters, :map, required: true
  attr :sort, :string, required: true
  attr :key, :string, required: true
  attr :label, :string, required: true

  defp sort_link(assigns) do
    ~H"""
    <.link
      patch={~p"/console/knowledge?#{sort_params(@filters, @key)}"}
      class={["sort-link", @sort == @key && "is-active"]}
      aria-sort={(@sort == @key && "descending") || "none"}
    >
      {@label}<span :if={@sort == @key} aria-hidden="true">▾</span>
    </.link>
    """
  end

  # Retrieval requires an explicit query and scope, and only runs in find mode;
  # no scope is not the root.
  #
  # The preview needs no further lifecycle narrowing. `Retrieval.Store` returns
  # `active` plus the caller's own `provisional` and nothing else, which is
  # strictly narrower than what any console role may see. Widening the store
  # would make that untrue, so a candidate carrying any other state is a
  # signal to filter here rather than to relax this comment.
  defp retrieval_preview(actor, %{"mode" => "find", "q" => query, "scope" => scope})
       when is_binary(query) and query != "" and is_binary(scope) and scope != "" do
    Memory.search(%{"query" => query, "scope_path" => scope}, actor)
  end

  defp retrieval_preview(_actor, _filters), do: nil

  defp mode(%{"mode" => "find"}), do: "find"
  defp mode(_filters), do: "browse"

  # Switching modes keeps the scope, because it is the one control both modes
  # share and re-picking it out of a long list is the friction this page is
  # meant to remove.
  defp browse_params(filters), do: filters |> Map.take(["scope"]) |> Map.put("mode", "browse")

  defp find_params(filters) do
    filters |> Map.take(["scope", "q"]) |> Map.put("mode", "find")
  end

  defp patch_to(socket, params) do
    params =
      params
      |> Map.take(@filter_keys)
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    push_patch(socket, to: ~p"/console/knowledge?#{params}")
  end

  # The detail page rebuilds a return link from this, so it carries filters and
  # nothing else.
  defp back_param(filters) do
    case Map.take(filters, @filter_keys) do
      empty when map_size(empty) == 0 -> %{}
      kept -> %{"back" => URI.encode_query(kept)}
    end
  end

  defp active_filters(filters) do
    @narrowing_keys
    |> Enum.filter(&(not blank?(filters[&1])))
    |> Enum.map(&{&1, filter_label(&1), filter_value(&1, filters[&1])})
  end

  defp filter_label("scope"), do: "Scope"
  defp filter_label("state"), do: "State"
  defp filter_label("kind"), do: "Kind"
  defp filter_label("sensitivity"), do: "Sensitivity"
  defp filter_label("target_level"), do: "Travels to"
  defp filter_label("subject"), do: "Subject"

  defp filter_value("scope", value), do: value
  defp filter_value("subject", "me"), do: "About me"
  defp filter_value(key, value), do: enum_label(key, value)

  defp list_title("find"), do: "Exhaustive list"
  defp list_title(_browse), do: "Statements"

  defp list_description("find", _sort) do
    "Everything that matches the filters, whether or not retrieval ranked it. " <>
      "What is missing here is filtered out or not visible to you, never merely ranked low."
  end

  defp list_description(_browse, "recorded") do
    "Newest first. Confidence breaks ties. Confidence is how sure the system is; " <>
      "it is independent of how widely the statement may travel."
  end

  defp list_description(_browse, _confidence) do
    "Most confident first. Recency breaks ties. Confidence is how sure the system is; " <>
      "it is independent of how widely the statement may travel."
  end

  defp filtered_empty_message do
    "Nothing matches these filters. Remove one above to widen the result."
  end

  defp unfiltered_empty_message do
    "You can read no statements at all yet. A reader with no role on a scope sees none " <>
      "of its statements, which is the intended result rather than an error."
  end

  defp scope_leaf("/"), do: "root"

  defp scope_leaf(path) do
    path |> String.split("/", trim: true) |> List.last() || "root"
  end

  defp blank?(value), do: value in [nil, ""]

  defp candidate_statement(candidate) do
    Statement.with_validity(
      candidate["statement"],
      candidate["relevant_from"],
      candidate["relevant_until"]
    )
  end

  defp statement_with_validity(item) do
    Statement.with_validity(item.statement, item.relevant_from, item.relevant_until)
  end

  # Separate deadline loss from empty indexes, and both from a healthy run. A search where the
  # text-reading strategies all found nothing still returns a full page — of whatever is most
  # recent — so the count above cannot be read alone.
  defp strategy_note(search) do
    case Enum.reject(
           [
             strategy_group("dropped", search["dropped_strategies"]),
             strategy_group("found nothing", search["empty_strategies"])
           ],
           &is_nil/1
         ) do
      [] -> "all contributed"
      notes -> Enum.join(notes, "; ")
    end
  end

  defp strategy_group(_label, []), do: nil
  defp strategy_group(label, names), do: "#{label}: " <> Enum.map_join(names, ", ", &to_string/1)

  defp strategy_tone(search) do
    if search["dropped_strategies"] == [] and search["empty_strategies"] == [],
      do: "neutral",
      else: "warn"
  end

  defp page_params(filters, page), do: Map.put(filters, "page", Integer.to_string(page))

  # Changing the sort reorders the whole result, so the current page number is
  # meaningless against the new order.
  defp sort_params(filters, key) do
    filters |> Map.put("sort", key) |> Map.delete("page")
  end
end
