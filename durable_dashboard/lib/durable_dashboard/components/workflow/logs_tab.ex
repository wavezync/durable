defmodule DurableDashboard.Components.Workflow.LogsTab do
  @moduledoc """
  Logs tab — a Grafana-style log viewer over every step execution's captured
  logs for the workflow. Stateful (filters, sort, page) so it lives as a
  LiveComponent. Each step's `:logs` is a list of maps with `"level"`,
  `"message"`, `"timestamp"`, `"source"`, and `"metadata"` keys.

  Features:
  - level + step filters, full-text search (message/step/level/source/metadata)
  - sort by timestamp (oldest ⇄ newest)
  - pagination (dense rows, 100/page)
  - per-level left-bar coloring; expandable JSON / metadata per line
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Workflow.LogLine

  @levels ["all", "debug", "info", "warning", "error"]
  @per_page 100

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       step_filter: "all",
       level_filter: "all",
       search: "",
       sort_dir: :asc,
       page: 1
     )}
  end

  @impl true
  def update(%{steps: steps} = assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign(steps: steps)}
  end

  @impl true
  def handle_event("filter:step", %{"step" => step}, socket) do
    {:noreply, assign(socket, step_filter: step, page: 1)}
  end

  def handle_event("filter:level", %{"level" => level}, socket) do
    {:noreply, assign(socket, level_filter: level, page: 1)}
  end

  def handle_event("filter:search", %{"value" => search}, socket) do
    {:noreply, assign(socket, search: search, page: 1)}
  end

  def handle_event("filter:clear", _, socket) do
    {:noreply, assign(socket, step_filter: "all", level_filter: "all", search: "", page: 1)}
  end

  def handle_event("sort:toggle", _, socket) do
    flipped = if socket.assigns.sort_dir == :asc, do: :desc, else: :asc
    {:noreply, assign(socket, sort_dir: flipped, page: 1)}
  end

  def handle_event("page:set", %{"page" => page}, socket) do
    {:noreply, assign(socket, page: to_int(page, socket.assigns.page))}
  end

  @impl true
  def render(assigns) do
    filtered =
      assigns.steps
      |> flatten_logs()
      |> Enum.filter(&match_step?(&1, assigns.step_filter))
      |> Enum.filter(&match_level?(&1, assigns.level_filter))
      |> Enum.filter(&match_search?(&1, assigns.search))
      |> sort_logs(assigns.sort_dir)

    total = length(filtered)
    total_pages = max(1, ceil(total / @per_page))
    page = assigns.page |> max(1) |> min(total_pages)
    offset = (page - 1) * @per_page
    visible = Enum.slice(filtered, offset, @per_page)

    assigns =
      assigns
      |> assign(
        visible: visible,
        total: total,
        page: page,
        total_pages: total_pages,
        range_start: if(total == 0, do: 0, else: offset + 1),
        range_end: min(offset + @per_page, total),
        counts: level_counts(assigns.steps),
        levels: @levels,
        step_options: ["all" | step_names(assigns.steps)]
      )

    ~H"""
    <div class="flex flex-col gap-3">
      <.toolbar
        myself={@myself}
        step_filter={@step_filter}
        level_filter={@level_filter}
        search={@search}
        sort_dir={@sort_dir}
        step_options={@step_options}
        counts={@counts}
        levels={@levels}
      />

      <Core.card padding="none">
        <%= if @total == 0 do %>
          <Core.empty_state
            icon="information-circle"
            title="No log entries match"
            description="Adjust the filters or wait for new logs."
          />
        <% else %>
          <div class="thin-scroll max-h-[600px] overflow-auto">
            <LogLine.row :for={entry <- @visible} entry={entry} />
          </div>

          <.pager
            myself={@myself}
            page={@page}
            total_pages={@total_pages}
            range_start={@range_start}
            range_end={@range_end}
            total={@total}
          />
        <% end %>
      </Core.card>
    </div>
    """
  end

  # ============================================================================
  # Toolbar
  # ============================================================================

  attr :myself, :any, required: true
  attr :step_filter, :string, required: true
  attr :level_filter, :string, required: true
  attr :search, :string, required: true
  attr :sort_dir, :atom, required: true
  attr :step_options, :list, required: true
  attr :levels, :list, required: true
  attr :counts, :map, required: true

  defp toolbar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <form phx-change="filter:level" phx-target={@myself}>
        <select name="level" class={select_class()}>
          <option :for={level <- @levels} value={level} selected={level == @level_filter}>
            {humanize(level)}{if level != "all", do: " (#{Map.get(@counts, level, 0)})", else: ""}
          </option>
        </select>
      </form>

      <form phx-change="filter:step" phx-target={@myself}>
        <select name="step" class={select_class()}>
          <option :for={step <- @step_options} value={step} selected={step == @step_filter}>
            {humanize(step)}
          </option>
        </select>
      </form>

      <form phx-change="filter:search" phx-target={@myself} class="min-w-0 flex-1">
        <div class="relative">
          <Core.icon
            name="search"
            class="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground"
          />
          <input
            type="search"
            name="value"
            value={@search}
            placeholder="Search message, step, level, metadata…"
            phx-debounce="200"
            autocomplete="off"
            class={[
              "h-8 w-full rounded-md pr-3 pl-8 text-[13px]",
              "border border-border bg-input/40",
              "text-foreground placeholder:text-muted-foreground",
              "focus:outline-none focus:ring-2 focus:ring-ring"
            ]}
          />
        </div>
      </form>

      <button
        type="button"
        phx-click="sort:toggle"
        phx-target={@myself}
        class={[
          "inline-flex h-8 shrink-0 items-center gap-1.5 rounded-md border border-border bg-input/40 px-2.5",
          "font-mono text-[11px] text-muted-foreground transition-colors hover:text-foreground"
        ]}
        title="Toggle timestamp sort"
      >
        Time
        <span class="text-foreground">{if @sort_dir == :asc, do: "↑", else: "↓"}</span>
      </button>

      <Core.button
        :if={any_filter_active?(@step_filter, @level_filter, @search)}
        kind="ghost"
        size="sm"
        phx-click="filter:clear"
        phx-target={@myself}
      >
        Clear
      </Core.button>
    </div>
    """
  end

  defp select_class do
    [
      "h-8 rounded-md px-2 pr-7 text-[13px]",
      "border border-border bg-input/40 text-foreground"
    ]
  end

  # ============================================================================
  # Pager
  # ============================================================================

  attr :myself, :any, required: true
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :range_start, :integer, required: true
  attr :range_end, :integer, required: true
  attr :total, :integer, required: true

  defp pager(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 border-t border-border px-3 py-2">
      <span class="font-mono text-[11px] text-muted-foreground tabular-nums">
        {@range_start}–{@range_end} of {@total}
      </span>

      <div :if={@total_pages > 1} class="flex items-center gap-1">
        <button
          type="button"
          phx-click="page:set"
          phx-value-page={@page - 1}
          phx-target={@myself}
          disabled={@page <= 1}
          class={pager_btn(@page <= 1)}
          aria-label="Previous page"
        >
          <Core.icon name="chevron-left" class="size-4" />
        </button>
        <span class="px-2 font-mono text-[11px] text-muted-foreground tabular-nums">
          {@page} / {@total_pages}
        </span>
        <button
          type="button"
          phx-click="page:set"
          phx-value-page={@page + 1}
          phx-target={@myself}
          disabled={@page >= @total_pages}
          class={pager_btn(@page >= @total_pages)}
          aria-label="Next page"
        >
          <Core.icon name="chevron-right" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  defp pager_btn(disabled?) do
    [
      "inline-flex size-7 items-center justify-center rounded-md border border-border",
      "text-muted-foreground transition-colors",
      if(disabled?,
        do: "cursor-not-allowed opacity-40",
        else: "hover:bg-accent/50 hover:text-foreground"
      )
    ]
  end

  defp any_filter_active?(step, level, search) do
    step != "all" or level != "all" or (search != "" and search != nil)
  end

  defp humanize("all"), do: "All"
  defp humanize(s) when is_binary(s), do: s
  defp humanize(s), do: to_string(s)

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(v, _default) when is_integer(v), do: v
  defp to_int(_, default), do: default

  # ============================================================================
  # Filtering / sorting
  # ============================================================================

  defp flatten_logs(steps) do
    Enum.flat_map(steps, &flatten_step_logs/1)
  end

  defp flatten_step_logs(%{logs: logs, step_name: name}) when is_list(logs) do
    Enum.map(logs, &Map.put(&1, "__step__", to_string(name)))
  end

  defp flatten_step_logs(_), do: []

  defp sort_logs(entries, dir) do
    Enum.sort_by(entries, &Map.get(&1, "timestamp", ""), dir)
  end

  defp match_step?(_, "all"), do: true
  defp match_step?(entry, step), do: entry["__step__"] == step

  defp match_level?(_, "all"), do: true
  defp match_level?(entry, level), do: to_string(entry["level"]) == level

  defp match_search?(_, ""), do: true
  defp match_search?(_, nil), do: true

  # Search spans message + step + level + source + metadata, not just the
  # message text — so an operator can find a line by step name, a request_id
  # in metadata, or `source: io` without it silently returning nothing.
  defp match_search?(entry, search) do
    haystack =
      [
        entry["message"],
        entry["__step__"],
        entry["level"],
        entry["source"],
        metadata_haystack(entry["metadata"])
      ]
      |> Enum.map_join(" ", &to_string/1)
      |> String.downcase()

    String.contains?(haystack, String.downcase(search))
  end

  defp metadata_haystack(m) when is_map(m) and map_size(m) > 0, do: inspect(m)
  defp metadata_haystack(_), do: ""

  defp step_names(steps) do
    steps
    |> Enum.map(& &1.step_name)
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
  end

  defp level_counts(steps) do
    steps
    |> Enum.flat_map(fn s -> if is_list(s.logs), do: s.logs, else: [] end)
    |> Enum.frequencies_by(&to_string(&1["level"]))
  end
end
