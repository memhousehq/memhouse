# SPDX-License-Identifier: MemHouse-Sustainable-Use-1.0

defmodule MemHouseWeb.ConsoleComponents do
  @moduledoc """
  Stateless presentation components for the browser console.

  They render already-authorized data and may hide unavailable navigation, but
  never authorize operations. Styling belongs in `console.css`; inline scripts
  violate the console CSP. Data-driven bar widths are the only inline style,
  because a stylesheet cannot hold a value that comes from a row. Never copy
  rendered content into logs, telemetry, audit data, or job args.
  """

  use MemHouseWeb, :html

  alias MemHouse.Actor
  alias MemHouseWeb.Console.Access

  # One sentence per enum value, phrased for a reader deciding what to do next.
  # A value missing here renders its label with no tooltip, which is why the
  # lifecycle list must be kept in step with `Access.all_states/0`.
  @meanings %{
    {"state", "proposed"} => "Extracted and waiting for its first gate decision.",
    {"state", "active"} => "Accepted. The system currently believes it.",
    {"state", "provisional"} => "Held for its subject alone until they confirm or contest it.",
    {"state", "held"} => "Waiting at a wider scope for a second human decision.",
    {"state", "needs_revalidation"} =>
      "Still believed, but past the date it should be rechecked.",
    {"state", "superseded"} => "Replaced by a later statement, and kept as evidence.",
    {"state", "expired"} => "Past the date it was said to stop being true.",
    {"state", "rejected"} => "Refused at a gate, and kept as evidence.",
    {"state", "contested"} => "Disputed by its subject and queued for a curator.",
    {"state", "redacted"} => "Withdrawn by its subject.",
    {"state", "stale"} => "Long unconfirmed and no longer relied on.",
    {"state", "retracted"} => "Withdrawn by the source it came from.",
    {"sensitivity", "public"} => "May travel anywhere the scope tree allows.",
    {"sensitivity", "internal"} => "Ordinary Account knowledge; no personal care required.",
    {"sensitivity", "personal"} => "About a person. Widening it needs that person's consent.",
    {"sensitivity", "restricted"} => "Closely held. Widening it needs the strongest evidence."
  }

  @doc """
  Renders the identity bar, role-filtered navigation, flash messages, and page
  slots. Destinations enforce authorization independently.
  """
  attr :actor, Actor, required: true
  attr :active, :atom, required: true
  attr :title, :string, required: true
  attr :flash, :map, default: %{}
  slot :subtitle
  slot :actions
  slot :inner_block, required: true

  def shell(assigns) do
    assigns = assign(assigns, :nav_items, nav_items(assigns.actor))

    ~H"""
    <div class="app">
      <header class="topbar">
        <a class="brand" href={~p"/console"}>
          <span class="brand-mark">◈</span>
          <span class="brand-name">MemHouse</span>
        </a>

        <div class="identity">
          <span class="role-pill">{Access.role_label(@actor)}</span>
          <span class="account-key">{@actor.account_key}</span>
          <%!--
            Sign-out is a form POST rather than a link because it destroys
            server session state. The hidden _method turns the POST into the
            DELETE route and the CSRF token is mandatory. A GET link would let
            a third-party page sign the reader out, and would set the precedent
            that browser state changes may travel by GET.
          --%>
          <form method="post" action={~p"/sign-out"}>
            <input type="hidden" name="_method" value="delete" />
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <button class="ghost">Sign out</button>
          </form>
        </div>
      </header>

      <div class="body">
        <nav class="sidebar">
          <.nav_link :for={item <- @nav_items} item={item} active={@active} />
        </nav>

        <main class="content">
          <div class="page-head">
            <div>
              <h1>{@title}</h1>
              <p :if={@subtitle != []} class="lede">{render_slot(@subtitle)}</p>
            </div>
            <div :if={@actions != []} class="page-actions">{render_slot(@actions)}</div>
          </div>

          <p :if={Phoenix.Flash.get(@flash, :info)} class="flash info" role="status">
            {Phoenix.Flash.get(@flash, :info)}
          </p>
          <p :if={Phoenix.Flash.get(@flash, :error)} class="flash error" role="alert">
            {Phoenix.Flash.get(@flash, :error)}
          </p>

          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  @doc """
  Renders one navigation entry as a full-load anchor.
  """
  attr :item, :map, required: true
  attr :active, :atom, required: true

  def nav_link(assigns) do
    ~H"""
    <a
      href={@item.path}
      class={["nav-item", @item.key == @active && "is-active"]}
      aria-current={@item.key == @active && "page"}
    >
      <span class="nav-glyph" aria-hidden="true">{@item.glyph}</span>
      <span>{@item.label}</span>
    </a>
    """
  end

  @doc """
  Renders a labelled statistic with an optional note and destination.

  `tone` is `"neutral"`, `"accent"`, `"warn"`, or `"danger"`.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, default: nil
  attr :tone, :string, default: "neutral"
  attr :navigate, :string, default: nil

  def tile(assigns) do
    ~H"""
    <div class={["tile", "tone-#{@tone}"]}>
      <p class="tile-value">{@value}</p>
      <p class="tile-label">{@label}</p>
      <p :if={@note} class="tile-note">{@note}</p>
      <a :if={@navigate} class="tile-link" href={@navigate}>Explore</a>
    </div>
    """
  end

  @doc """
  Renders `{label, count}` rows relative to the largest count, including zeros.
  """
  attr :rows, :list, required: true
  attr :class_prefix, :string, default: "bar"

  def bar_chart(assigns) do
    max = assigns.rows |> Enum.map(fn {_label, count} -> count end) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, :max, max)

    ~H"""
    <div class="bars">
      <div :for={{label, count} <- @rows} class="bar-row">
        <span class="bar-label">{label}</span>
        <span class="bar-track">
          <span class={["bar-fill", "#{@class_prefix}-#{label}"]} style={bar_width(count, @max)}>
          </span>
        </span>
        <span class="bar-count">{count}</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders an enumerated value using its `family` CSS group.

  The glyph carries the same distinction the colour does, so a reader who cannot
  separate the palette still reads state and sensitivity correctly. It is
  decorative to a screen reader because the label beside it already says the
  same thing.
  """
  attr :family, :string, required: true
  attr :value, :any, required: true

  def badge(assigns) do
    ~H"""
    <span class={["badge", "#{@family}-#{@value}"]} title={enum_meaning(@family, @value)}>
      <span :if={enum_glyph(@family, @value)} class="badge-glyph" aria-hidden="true">
        {enum_glyph(@family, @value)}
      </span>
      {enum_label(@family, @value)}
    </span>
    """
  end

  @doc """
  Renders the lifecycle and sensitivity vocabulary as a collapsed reference.

  Both families use developer enum values that a reader has no way to decode
  from the badge alone, and both change what a statement means rather than only
  how it looks.
  """
  attr :states, :list, required: true

  def legend(assigns) do
    ~H"""
    <details class="legend">
      <summary>What these labels mean</summary>
      <dl class="legend-list">
        <div :for={state <- @states} class="legend-row">
          <dt><.badge family="state" value={state} /></dt>
          <dd>{enum_meaning("state", state)}</dd>
        </div>
        <div :for={level <- ~w(public internal personal restricted)} class="legend-row">
          <dt><.badge family="sensitivity" value={level} /></dt>
          <dd>{enum_meaning("sensitivity", level)}</dd>
        </div>
      </dl>
    </details>
    """
  end

  @doc """
  Renders a timestamp as elapsed time, with the exact UTC value in the tooltip.

  Elapsed time answers "is this current?", which is the question a reader
  actually has; the machine-readable `datetime` and the tooltip keep the precise
  value one hover away.
  """
  attr :at, :any, required: true
  attr :now, :any, default: nil

  def time(assigns) do
    assigns = assign(assigns, :now, assigns.now || DateTime.utc_now())

    ~H"""
    <span :if={is_nil(@at)} class="muted">—</span>
    <time :if={@at} datetime={timestamp(@at)} title={timestamp(@at)}>
      {relative_time(@at, @now)}
    </time>
    """
  end

  @doc """
  Renders a scope path abbreviated to its last two segments.

  Generated scope trees are deep enough that a full path crowds out the
  statement beside it, so the tail — which is what distinguishes one sibling
  from another — is shown and the whole path stays available.
  """
  attr :path, :string, default: nil
  attr :id, :string, default: nil

  def scope_crumb(assigns) do
    ~H"""
    <span :if={is_nil(@path)} class="muted">(unreadable scope)</span>
    <span :if={@path} class="crumb" title={@path}>
      <%!--
        The elision belongs to the path string rather than a sibling element, so
        a wrap can never strand it on a line of its own.
      --%>
      <span class="crumb-path">{crumb_label(@path)}</span>
      <.copyable :if={@id} id={@id} value={@path} label="Copy scope path" />
    </span>
    """
  end

  @doc """
  Renders a button that copies `value` to the clipboard.

  The clipboard API is unreachable from markup, so this is the console's only
  hook. It renders nothing without a value rather than offering a control that
  would copy an empty string.
  """
  attr :id, :string, required: true
  attr :value, :any, default: nil
  attr :label, :string, default: "Copy"

  def copyable(assigns) do
    ~H"""
    <button
      :if={@value}
      id={@id}
      type="button"
      class="copy"
      phx-hook="Copy"
      data-copy={@value}
      title={@label}
      aria-label={@label}
    >
      <span aria-hidden="true">⧉</span>
    </button>
    """
  end

  @doc """
  Renders a shortened identifier with the full value in its tooltip.

  Pass `id` to offer a copy control; identifiers are shortened for scanning and
  are useless to a reader who cannot retrieve the whole one.
  """
  attr :value, :any, default: nil
  attr :navigate, :string, default: nil
  attr :id, :string, default: nil

  def id_chip(assigns) do
    ~H"""
    <a :if={@navigate} class="chip" href={@navigate} title={@value}>{short_id(@value)}</a>
    <span :if={is_nil(@navigate)} class="chip" title={@value}>{short_id(@value)}</span>
    <.copyable :if={@id} id={@id} value={@value} label="Copy full identifier" />
    """
  end

  @doc """
  Renders text truncated to `length`, expandable to its full value.

  `details` is native, keyboard-reachable, and needs no script, which the
  console's `script-src 'self'` policy makes the deciding factor.
  """
  attr :text, :string, default: nil
  attr :length, :integer, default: 180

  def expandable(assigns) do
    ~H"""
    <span :if={not truncated?(@text, @length)}>{@text}</span>
    <details :if={truncated?(@text, @length)} class="expandable">
      <summary>{truncate(@text, @length)}</summary>
      <p class="expandable-full">{@text}</p>
    </details>
    """
  end

  @doc """
  Renders mode tabs as live-patch links.
  """
  attr :active, :string, required: true

  slot :tab, required: true do
    attr :key, :string, required: true
    attr :label, :string, required: true
    attr :patch, :string, required: true
    attr :hint, :string
  end

  def tabs(assigns) do
    ~H"""
    <nav class="tabs" role="tablist">
      <.link
        :for={tab <- @tab}
        patch={tab.patch}
        role="tab"
        class={["tab", tab.key == @active && "is-active"]}
        aria-selected={to_string(tab.key == @active)}
      >
        <span class="tab-label">{tab.label}</span>
        <span :if={tab[:hint]} class="tab-hint">{tab[:hint]}</span>
      </.link>
    </nav>
    """
  end

  @doc """
  Renders one applied filter with a link that removes only that filter.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :patch, :string, required: true

  def filter_chip(assigns) do
    ~H"""
    <span class="filter-chip">
      <span class="filter-chip-label">{@label}</span>
      <span class="filter-chip-value">{@value}</span>
      <.link patch={@patch} class="filter-chip-remove" aria-label={"Remove #{@label} filter"}>
        ×
      </.link>
    </span>
    """
  end

  @doc """
  Renders page navigation and the page-size control for a paged result.

  `page_href` builds the URL for a page number; the page supplies it because only
  it knows which filters must travel along. Changing the page size raises a
  `page_size` event for the same reason.
  """
  attr :page, :integer, required: true
  attr :page_count, :integer, required: true
  attr :page_size, :integer, required: true
  attr :total, :integer, required: true
  attr :page_href, :any, required: true
  attr :sizes, :list, required: true

  def pager(assigns) do
    ~H"""
    <nav class="pager" aria-label="Result pages">
      <form class="pager-size" phx-change="page_size">
        <label>
          Per page
          <select name="per_page">
            <option :for={size <- @sizes} value={size} selected={size == @page_size}>
              {size}
            </option>
          </select>
        </label>
      </form>

      <div :if={@page_count > 1} class="pager-steps">
        <.link :if={@page > 1} patch={@page_href.(1)} class="pager-step">First</.link>
        <.link :if={@page > 1} patch={@page_href.(@page - 1)} class="pager-step">← Previous</.link>
        <span class="pager-position">Page {@page} of {@page_count}</span>
        <.link :if={@page < @page_count} patch={@page_href.(@page + 1)} class="pager-step">
          Next →
        </.link>
        <.link :if={@page < @page_count} patch={@page_href.(@page_count)} class="pager-step">
          Last
        </.link>
      </div>

      <p class="pager-total">{page_window(@page, @page_size, @total)}</p>
    </nav>
    """
  end

  @doc """
  Renders confidence as a labelled bar.

  Confidence is a ratio, and a bar is read faster than four decimal places; the
  number stays because a curator comparing two statements needs it exactly.
  """
  attr :value, :any, required: true

  def confidence_meter(assigns) do
    ratio = min(max((assigns.value || 0) * 1.0, 0.0), 1.0)
    assigns = assign(assigns, :ratio, ratio)

    ~H"""
    <span class="meter" title={"Confidence #{Float.round(@ratio, 4)}"}>
      <span class="meter-track">
        <span class="meter-fill" style={"width:#{Float.round(@ratio * 100, 1)}%"}></span>
      </span>
      <span class="meter-value">{Float.round(@ratio, 2)}</span>
    </span>
    """
  end

  @doc """
  Renders a caller-supplied empty-state message.
  """
  attr :message, :string, required: true

  def empty(assigns) do
    ~H"""
    <p class="empty">{@message}</p>
    """
  end

  @doc """
  Renders a titled panel with an optional description.
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class="panel">
      <header class="panel-head">
        <h2>{@title}</h2>
        <p :if={@description}>{@description}</p>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Formats a timestamp in UTC with second precision, or `—` when absent.
  """
  def timestamp(nil), do: "—"

  def timestamp(%DateTime{} = at) do
    at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  def timestamp(other), do: to_string(other)

  @doc """
  Formats a timestamp as elapsed time relative to `now`.

  Resolution is deliberately coarse — the reader is judging currency, not
  measuring. Future times read forwards, because due dates, expiries, and
  revalidation deadlines are all rendered through here. `now` is a parameter so
  a caller can render a fixed clock.
  """
  def relative_time(at, now \\ nil)

  def relative_time(nil, _now), do: "—"

  def relative_time(%DateTime{} = at, now) do
    case DateTime.diff(now || DateTime.utc_now(), at, :second) do
      seconds when seconds < -59 -> "in " <> magnitude(-seconds)
      seconds when seconds < 60 -> "just now"
      seconds -> magnitude(seconds) <> " ago"
    end
  end

  def relative_time(other, _now), do: to_string(other)

  @doc """
  Human-readable label for an enumerated `family` value.

  Falls back to the raw value so a state added to the resource and not mapped
  here still renders honestly rather than disappearing.
  """
  def enum_label(_family, nil), do: "—"

  def enum_label(_family, value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @doc """
  Whether `truncate/2` would shorten this text, so a caller can offer an
  expansion control only where there is something to expand.
  """
  def truncated?(nil, _length), do: false
  def truncated?(text, length) when is_binary(text), do: String.length(text) > length

  @doc """
  Truncates display text to `length` characters and appends an ellipsis.
  """
  def truncate(nil, _length), do: ""

  def truncate(text, length) when is_binary(text) do
    if String.length(text) > length do
      String.slice(text, 0, length) <> "…"
    else
      text
    end
  end

  @doc """
  Returns a scope path or an explicit marker for an unreadable scope.
  """
  def scope_path(paths, scope_id), do: Map.get(paths, scope_id) || "(unreadable scope)"

  # Keep navigation task-ordered and role-filtered.
  defp nav_items(%Actor{} = actor) do
    base = [
      %{key: :dashboard, label: "Overview", glyph: "◉", path: "/console"},
      %{key: :knowledge, label: "Knowledge", glyph: "◇", path: "/console/knowledge"},
      %{key: :scopes, label: "Scopes", glyph: "▤", path: "/console/scopes"},
      %{key: :graph, label: "Graph", glyph: "⁂", path: "/console/graph"},
      %{key: :sources, label: "Sources", glyph: "❑", path: "/console/sources"},
      %{key: :skills, label: "Skills", glyph: "◈", path: "/console/skills"},
      %{key: :tools, label: "Tool workbench", glyph: "⌘", path: "/console/tools"},
      %{key: :me, label: "About me", glyph: "☺", path: "/console/me"}
    ]

    # Governance uses a separate live session and requires a full load.
    curator =
      if Access.can?(actor, :curate),
        do: [%{key: :queue, label: "Governance queue", glyph: "⚖", path: "/governance"}],
        else: []

    admin =
      if Access.can?(actor, :administer),
        do: [%{key: :operations, label: "Operations", glyph: "⚙", path: "/console/operations"}],
        else: []

    base ++ curator ++ admin
  end

  # Three shapes for the three things the palette encodes: settled, pending, and
  # withdrawn. Sensitivity climbs the same way, from open to closed. Only these
  # families get a glyph: kind and target level are colourless categories, and a
  # mark beside them would be decoration competing with the ones that matter.
  defp enum_glyph(family, value) when family in ["state", "decision"] do
    cond do
      value in ~w(active satisfied ready approve granted allow) -> "●"
      value in ~w(rejected contested redacted retracted reject deny denied) -> "■"
      true -> "◐"
    end
  end

  defp enum_glyph("sensitivity", "public"), do: "○"
  defp enum_glyph("sensitivity", "internal"), do: "◔"
  defp enum_glyph("sensitivity", "personal"), do: "◑"
  defp enum_glyph("sensitivity", "restricted"), do: "●"
  defp enum_glyph(_family, _value), do: nil

  defp enum_meaning(family, value), do: Map.get(@meanings, {family, value})

  # Coarsest unit that still leaves a non-zero count. Months are 30 days and
  # years 365: this is a currency judgement, not a calendar.
  defp magnitude(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} min"
  defp magnitude(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)} h"
  defp magnitude(seconds) when seconds < 2_592_000, do: "#{div(seconds, 86_400)} d"
  defp magnitude(seconds) when seconds < 31_536_000, do: "#{div(seconds, 2_592_000)} mo"
  defp magnitude(seconds), do: "#{div(seconds, 31_536_000)} y"

  # Keep the tail: siblings differ at the end of a path, never at the root.
  defp crumb_label("/"), do: "/"

  defp crumb_label(path) do
    case String.split(path, "/", trim: true) do
      [] -> "/"
      segments when length(segments) <= 2 -> path
      segments -> "…/" <> Enum.join(Enum.take(segments, -2), "/")
    end
  end

  defp page_window(_page, _size, 0), do: "No statements"

  defp page_window(page, size, total) do
    first = (page - 1) * size + 1
    last = min(page * size, total)
    "Showing #{first}–#{last} of #{total}"
  end

  # Data-driven widths cannot be predefined in the stylesheet.
  defp bar_width(_count, 0), do: "width:0%"

  defp bar_width(count, max) do
    "width:#{Float.round(count / max * 100, 1)}%"
  end

  defp short_id(nil), do: "—"

  defp short_id(value) do
    value |> to_string() |> String.slice(0, 8)
  end
end
