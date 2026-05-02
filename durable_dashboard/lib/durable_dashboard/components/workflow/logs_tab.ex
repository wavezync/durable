defmodule DurableDashboard.Components.Workflow.LogsTab do
  @moduledoc """
  Logs tab — flattened view of every log entry across every step execution
  for the workflow. Stateful (filter selections) so it lives as a
  LiveComponent. Each step's `:logs` field is a list of maps with
  `"level"`, `"message"`, `"timestamp"`, and `"source"` keys.

  Filters available:
  - Step name (one of the executions, or "all")
  - Level (debug / info / warning / error / "all")
  - Free-text search

  Phase 3 keeps this simple — no streaming, full re-render on filter change.
  Virtualization for very large log volumes can come at phase 5 polish.
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core

  @levels ["all", "debug", "info", "warning", "error"]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       step_filter: "all",
       level_filter: "all",
       search: ""
     )}
  end

  @impl true
  def update(%{steps: steps} = assigns, socket) do
    {:ok, socket |> assign(assigns) |> assign(steps: steps)}
  end

  @impl true
  def handle_event("filter:step", %{"step" => step}, socket) do
    {:noreply, assign(socket, step_filter: step)}
  end

  def handle_event("filter:level", %{"level" => level}, socket) do
    {:noreply, assign(socket, level_filter: level)}
  end

  def handle_event("filter:search", %{"value" => search}, socket) do
    {:noreply, assign(socket, search: search)}
  end

  def handle_event("filter:clear", _, socket) do
    {:noreply, assign(socket, step_filter: "all", level_filter: "all", search: "")}
  end

  @impl true
  def render(assigns) do
    visible =
      filter_logs(assigns.steps, assigns.step_filter, assigns.level_filter, assigns.search)

    counts = level_counts(assigns.steps)

    assigns =
      assigns
      |> assign(visible: visible, counts: counts, levels: @levels)
      |> assign(step_options: ["all" | step_names(assigns.steps)])

    ~H"""
    <div class="flex flex-col gap-3">
      <.toolbar
        myself={@myself}
        step_filter={@step_filter}
        level_filter={@level_filter}
        search={@search}
        step_options={@step_options}
        counts={@counts}
        levels={@levels}
      />

      <Core.card padding="none">
        <%= if @visible == [] do %>
          <Core.empty_state
            icon="information-circle"
            title="No log entries match"
            description="Adjust the filters or wait for new logs."
          />
        <% else %>
          <ol class="divide-y divide-border thin-scroll max-h-[640px] overflow-auto">
            <li :for={entry <- @visible} class="grid grid-cols-[auto_auto_auto_1fr] gap-3 px-4 py-2 hover:bg-accent/30">
              <span class="text-[11px] font-mono text-muted-foreground tabular-nums whitespace-nowrap">
                {format_ts(entry["timestamp"])}
              </span>
              <span class={["text-[10px] uppercase tracking-wider font-medium", level_class(entry["level"])]}>
                {entry["level"] || "—"}
              </span>
              <Core.code class="text-[11px] whitespace-nowrap">{entry["__step__"]}</Core.code>
              <span class="text-xs font-mono whitespace-pre-wrap break-words text-foreground/90">
                {entry["message"]}
              </span>
            </li>
          </ol>
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
  attr :step_options, :list, required: true
  attr :levels, :list, required: true
  attr :counts, :map, required: true

  defp toolbar(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <form phx-change="filter:level" phx-target={@myself}>
        <select
          name="level"
          class={[
            "h-8 px-2 pr-7 rounded-md text-[13px]",
            "bg-input/40 border border-border text-foreground"
          ]}
        >
          <option :for={level <- @levels} value={level} selected={level == @level_filter}>
            {humanize(level)} <span :if={level != "all"}>({Map.get(@counts, level, 0)})</span>
          </option>
        </select>
      </form>

      <form phx-change="filter:step" phx-target={@myself}>
        <select
          name="step"
          class={[
            "h-8 px-2 pr-7 rounded-md text-[13px]",
            "bg-input/40 border border-border text-foreground"
          ]}
        >
          <option :for={step <- @step_options} value={step} selected={step == @step_filter}>
            {humanize(step)}
          </option>
        </select>
      </form>

      <form phx-change="filter:search" phx-target={@myself} class="flex-1 max-w-xs">
        <input
          type="search"
          name="value"
          value={@search}
          placeholder="Search messages…"
          phx-debounce="200"
          autocomplete="off"
          class={[
            "w-full h-8 px-3 rounded-md text-[13px]",
            "bg-input/40 border border-border",
            "text-foreground placeholder:text-muted-foreground",
            "focus:outline-none focus:ring-2 focus:ring-ring"
          ]}
        />
      </form>

      <Core.button
        :if={any_filter_active?(@step_filter, @level_filter, @search)}
        kind="ghost"
        phx-click="filter:clear"
        phx-target={@myself}
      >
        Clear
      </Core.button>
    </div>
    """
  end

  defp any_filter_active?(step, level, search) do
    step != "all" or level != "all" or (search != "" and search != nil)
  end

  defp humanize("all"), do: "All"
  defp humanize(s) when is_binary(s), do: s
  defp humanize(s), do: to_string(s)

  # ============================================================================
  # Filtering
  # ============================================================================

  defp filter_logs(steps, step_filter, level_filter, search) do
    steps
    |> Enum.flat_map(&flatten_step_logs/1)
    |> Enum.filter(&match_step?(&1, step_filter))
    |> Enum.filter(&match_level?(&1, level_filter))
    |> Enum.filter(&match_search?(&1, search))
    |> Enum.sort_by(& &1["timestamp"], :asc)
  end

  defp flatten_step_logs(%{logs: logs, step_name: name}) when is_list(logs) do
    Enum.map(logs, &Map.put(&1, "__step__", to_string(name)))
  end

  defp flatten_step_logs(_), do: []

  defp match_step?(_, "all"), do: true
  defp match_step?(entry, step), do: entry["__step__"] == step

  defp match_level?(_, "all"), do: true
  defp match_level?(entry, level), do: to_string(entry["level"]) == level

  defp match_search?(_, ""), do: true
  defp match_search?(_, nil), do: true

  defp match_search?(entry, search) do
    msg = to_string(entry["message"] || "")
    String.contains?(String.downcase(msg), String.downcase(search))
  end

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

  # ============================================================================
  # Formatting
  # ============================================================================

  defp level_class("error"), do: "text-destructive"
  defp level_class("warning"), do: "text-warning"
  defp level_class("info"), do: "text-info"
  defp level_class("debug"), do: "text-muted-foreground"
  defp level_class(_), do: "text-muted-foreground"

  defp format_ts(nil), do: "—"

  defp format_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M:%S.%f") |> String.slice(0, 12)
      _ -> ts
    end
  end

  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_ts(_), do: "—"
end
