defmodule DurableDashboard.Components.Command.CommandPalette do
  @moduledoc """
  ⌘K command palette. Rendered once by `Layouts.app` — always present,
  hidden when closed. The JS hook (`assets/src/hooks/command_palette.ts`)
  bridges keypresses to LC events.

  ## What it searches

  The palette searches the **nouns of the console**, grouped:

  - **Go to** — the static page routes (Overview, Workflows, Executions,
    Inputs, Schedules, Settings).
  - **Workflows** — live workflow definitions (`Durable.Query.list_workflows`),
    each jumping to that workflow's executions list.
  - **Recent runs** — the latest executions, each jumping to its detail page.

  Live data is **snapshotted on open** (one query pass) and filtered
  in-memory on every keystroke — so typing never hits the database.

  ## Events

  - `palette:open` — open, snapshot live data, focus the input
  - `palette:close` — close (Esc, click overlay)
  - `palette:search` `%{"value" => q}` — phx-change on the input
  - `palette:move` `%{"dir" => "up" | "down"}` — keyboard nav (wraps)
  - `palette:select` `%{"index" => i}` — hover highlights a row
  - `palette:activate` — Enter / click → live-navigate to the selected result

  ## Required assigns

  - `:base_path` — host mount path, for building hrefs
  - `:durable` — Durable instance name, for live workflow/run search
    (when `nil`, the palette degrades to page routes only)
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Path, as: DPath
  alias Phoenix.LiveView.JS

  @recent_limit 6

  # Static page routes. `path` is resolved against `base_path` at build time.
  @pages [
    %{label: "Overview", icon: "home", path: :overview},
    %{label: "Workflows", icon: "queue", path: :workflows},
    %{label: "Executions", icon: "play", path: :executions},
    %{label: "Pending inputs", icon: "inbox", path: :inputs},
    %{label: "Schedules", icon: "calendar", path: :schedules},
    %{label: "Settings", icon: "settings", path: :settings}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       query: "",
       selected_index: 0,
       results: [],
       groups: [],
       workflows: [],
       recent: []
     )}
  end

  @impl true
  def update(assigns, socket) do
    # Rebuild from whatever data is on hand: page routes need no DB, so they
    # render even before the palette opens (and in static `render_component`
    # tests). Live workflow/run data is loaded lazily on `palette:open`.
    {:ok,
     socket
     |> assign(assigns)
     |> assign_results(socket.assigns.query)}
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("palette:open", _, socket) do
    {:noreply,
     socket
     |> assign(open?: true, query: "", selected_index: 0)
     |> load_snapshot()
     |> assign_results("")}
  end

  def handle_event("palette:close", _, socket) do
    {:noreply,
     assign(socket, open?: false, query: "", selected_index: 0, results: [], groups: [])}
  end

  def handle_event("palette:search", %{"value" => q}, socket) do
    {:noreply, socket |> assign(selected_index: 0) |> assign_results(q)}
  end

  def handle_event("palette:move", %{"dir" => dir}, socket) do
    {:noreply, assign(socket, selected_index: move_index(socket, dir))}
  end

  def handle_event("palette:select", %{"index" => idx}, socket) do
    {:noreply, assign(socket, selected_index: String.to_integer(idx))}
  end

  def handle_event("palette:activate", _, socket) do
    case Enum.at(socket.assigns.results, socket.assigns.selected_index) do
      nil ->
        {:noreply, socket}

      item ->
        {:noreply,
         socket
         |> assign(open?: false, query: "")
         |> push_navigate(to: item.href)}
    end
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="CommandPalette"
      data-open={to_string(@open?)}
      class={["fixed inset-0 z-50", if(@open?, do: "block", else: "hidden")]}
    >
      <%!-- Backdrop click target — invisible-by-design click region, not a
            visual button. Stays raw for a11y without inheriting button sizing. --%>
      <button
        type="button"
        aria-label="Close palette"
        class="absolute inset-0 bg-background/70 backdrop-blur-sm"
        phx-click="palette:close"
        phx-target={@myself}
      >
      </button>

      <div
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        class={[
          "relative mx-auto mt-[15vh] w-full max-w-xl",
          "rounded-lg border border-border bg-popover text-popover-foreground",
          "shadow-2xl overflow-hidden"
        ]}
      >
        <div class="flex items-center gap-2.5 px-3 h-12 border-b border-border">
          <Core.icon name="search" class="size-4 text-muted-foreground shrink-0" />
          <form phx-change="palette:search" phx-target={@myself} class="flex-1">
            <input
              type="text"
              name="value"
              value={@query}
              placeholder="Jump to a page, workflow, or run…"
              autocomplete="off"
              spellcheck="false"
              data-palette-input
              class={[
                "w-full h-8 bg-transparent border-none outline-none text-sm",
                "text-foreground placeholder:text-muted-foreground"
              ]}
            />
          </form>
          <Core.kbd>Esc</Core.kbd>
        </div>

        <div
          role="listbox"
          aria-label="Results"
          class="max-h-[55vh] overflow-auto thin-scroll py-1.5"
          id={@id <> "-results"}
        >
          <div :if={@results == []} class="px-4 py-12 text-center text-[13px] text-muted-foreground">
            No matches for <span class="font-mono text-foreground">"{@query}"</span>
            <div class="mt-1 text-[11px] text-muted-foreground/70">
              Try a page name, a workflow, or a run id.
            </div>
          </div>

          <div :for={group <- @groups} role="presentation" class="px-1 pb-1">
            <div class="px-2 pt-2 pb-1">
              <Core.label>{group.label}</Core.label>
            </div>
            <.row
              :for={{item, idx} <- group.items}
              item={item}
              idx={idx}
              selected?={idx == @selected_index}
              myself={@myself}
            />
          </div>
        </div>

        <div class="flex items-center justify-between px-3 h-9 border-t border-border text-[11px] text-muted-foreground">
          <div class="flex items-center gap-3">
            <span class="flex items-center gap-1">
              <Core.kbd>↑</Core.kbd><Core.kbd>↓</Core.kbd> navigate
            </span>
            <span class="flex items-center gap-1">
              <Core.kbd>↵</Core.kbd> open
            </span>
          </div>
          <div class="flex items-center gap-1">
            <Core.kbd>⌘</Core.kbd><Core.kbd>K</Core.kbd>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :idx, :integer, required: true
  attr :selected?, :boolean, required: true
  attr :myself, :any, required: true

  defp row(assigns) do
    ~H"""
    <div
      role="option"
      aria-selected={@selected?}
      phx-click="palette:activate"
      phx-target={@myself}
      phx-value-index={@idx}
      phx-mouseenter={JS.push("palette:select", target: @myself, value: %{index: @idx})}
      class={[
        "group relative mx-1 flex items-center gap-2.5 h-9 px-2.5 rounded-md cursor-pointer text-[13px]",
        if @selected? do
          "bg-accent text-accent-foreground"
        else
          "text-foreground hover:bg-accent/40"
        end
      ]}
    >
      <%!-- The live rail — same indigo "you are here" bar as the active nav
            item. The selected row is the jump you're about to make. --%>
      <span
        :if={@selected?}
        class="absolute left-0 top-1/2 h-4 w-0.5 -translate-y-1/2 rounded-full bg-primary"
      >
      </span>
      <Core.icon name={@item.icon} class="size-4 shrink-0 text-muted-foreground" />
      <span class="flex-1 truncate font-medium">{@item.label}</span>
      <.row_meta item={@item} />
      <Core.kbd :if={@selected?} class="shrink-0">↵</Core.kbd>
    </div>
    """
  end

  attr :item, :map, required: true

  defp row_meta(%{item: %{type: :workflow}} = assigns) do
    ~H"""
    <span class="flex items-center gap-2 shrink-0">
      <span class="text-numeric text-[11px] text-muted-foreground/70">{@item.runs} runs</span>
      <Core.status_pill :if={@item.status} status={@item.status} />
    </span>
    """
  end

  defp row_meta(%{item: %{type: :run}} = assigns) do
    ~H"""
    <span class="flex items-center gap-2 shrink-0">
      <Core.code>{@item.short_id}</Core.code>
      <Core.status_pill status={@item.status} />
    </span>
    """
  end

  defp row_meta(assigns), do: ~H""

  # ============================================================================
  # Result building — snapshot on open, filter in-memory on keystroke
  # ============================================================================

  defp load_snapshot(socket) do
    durable = socket.assigns[:durable]
    assign(socket, workflows: safe_workflows(durable), recent: safe_recent(durable))
  end

  defp safe_workflows(nil), do: []

  defp safe_workflows(durable) do
    Durable.Query.list_workflows(durable: durable)
  rescue
    _ -> []
  end

  defp safe_recent(nil), do: []

  defp safe_recent(durable) do
    {rows, _total} =
      Durable.Query.list_executions_with_total(
        durable: durable,
        top_level_only: true,
        limit: @recent_limit,
        offset: 0
      )

    rows
  rescue
    _ -> []
  end

  defp assign_results(socket, query) do
    results = build_results(query, socket.assigns)

    socket
    |> assign(query: query, results: results, groups: group_results(results))
    |> clamp_selection()
  end

  defp build_results(query, assigns) do
    base = assigns.base_path
    q = String.trim(query)
    pages = page_results(base, q)

    if q == "" do
      pages ++ run_results(base, assigns.recent)
    else
      pages ++
        workflow_results(base, assigns.workflows, q) ++
        run_results(base, filter_runs(assigns.recent, q))
    end
  end

  defp page_results(base, q) do
    @pages
    |> Enum.filter(&matches?(&1.label, q))
    |> Enum.map(fn p ->
      %{group: "Go to", type: :page, label: p.label, icon: p.icon, href: page_href(base, p.path)}
    end)
  end

  defp workflow_results(base, workflows, q) do
    workflows
    |> Enum.filter(&matches?(&1.workflow_name, q))
    |> Enum.map(fn w ->
      %{
        group: "Workflows",
        type: :workflow,
        label: w.workflow_name,
        icon: "queue",
        href: DPath.workflow_executions(base, w.workflow_name),
        runs: w.total_runs,
        status: w.last_status
      }
    end)
  end

  defp run_results(base, runs) do
    Enum.map(runs, fn r ->
      %{
        group: "Recent runs",
        type: :run,
        label: r.workflow_name,
        icon: "play",
        href: DPath.execution(base, r.id),
        short_id: short_id(r.id),
        status: r.status
      }
    end)
  end

  defp filter_runs(runs, q) do
    Enum.filter(runs, fn r ->
      matches?(r.workflow_name, q) or String.starts_with?(downcase(short_id(r.id)), downcase(q))
    end)
  end

  defp group_results(results) do
    results
    |> Enum.with_index()
    |> Enum.chunk_by(fn {r, _i} -> r.group end)
    |> Enum.map(fn [{first, _i} | _] = chunk -> %{label: first.group, items: chunk} end)
  end

  defp page_href(base, :overview), do: DPath.overview(base)
  defp page_href(base, :workflows), do: DPath.workflows(base)
  defp page_href(base, :executions), do: DPath.executions(base)
  defp page_href(base, :inputs), do: DPath.inputs(base)
  defp page_href(base, :schedules), do: DPath.schedules(base)
  defp page_href(base, :settings), do: DPath.settings(base)

  defp matches?(value, q), do: String.contains?(downcase(value), downcase(q))

  defp downcase(nil), do: ""
  defp downcase(value), do: String.downcase(value)

  defp short_id(nil), do: "—"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp move_index(socket, dir) do
    count = length(socket.assigns.results)
    delta = if dir == "up", do: -1, else: 1

    if count == 0, do: 0, else: rem(socket.assigns.selected_index + delta + count, count)
  end

  defp clamp_selection(socket) do
    count = length(socket.assigns[:results] || [])

    cond do
      count == 0 -> assign(socket, selected_index: 0)
      socket.assigns.selected_index >= count -> assign(socket, selected_index: count - 1)
      socket.assigns.selected_index < 0 -> assign(socket, selected_index: 0)
      true -> socket
    end
  end
end
