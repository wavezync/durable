defmodule DurableDashboard.Components.Data.ExecutionFilters do
  @moduledoc """
  Faceted filter bar for the Executions list — a row of facet chips, each
  opening a popover, in the spirit of an ops console's query builder.

  Facets:

  - **Workflow** — a searchable combobox of the *known* workflow names
    (`Durable.Query.list_workflows`), since names are a small finite set
    (exact-match free-text search was a trap). Locked to the name on the
    per-workflow page.
  - **Status** — multi-select (failed + timeout at once).
  - **Time** — relative presets (15m … 30d) or a custom UTC range, mapped to
    the query's `:from` / `:to` on `inserted_at`.
  - **ID** — execution-id prefix filter; offers a jump when a full UUID is
    entered.

  The bar owns only transient UI state (which facet is open, the combobox
  search text). The *values* live in the parent's URL-driven query — every
  change sends `{:execution_filters, patch}` to the parent LiveView, which
  merges it, resets to page 1, and patches the URL. Open/close is tracked
  server-side (not client JS) so a LiveView patch can't reset an open panel.

  ## Required assigns

  - `:base_path`, `:status_options`, `:workflows` (combobox source)
  - `:workflow`, `:statuses`, `:range`, `:from`, `:to`, `:exec_id` — current
    values (from the parent query)
  - `:locked_workflow?` — true on `/workflows/:name`
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Path, as: DPath
  alias Phoenix.LiveView.JS

  @presets [
    {"15m", "Last 15 min"},
    {"1h", "Last hour"},
    {"24h", "Last 24 hours"},
    {"7d", "Last 7 days"},
    {"30d", "Last 30 days"}
  ]

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @impl true
  def mount(socket) do
    {:ok, assign(socket, open_facet: nil, wf_query: "")}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("toggle_facet", %{"facet" => facet}, socket) do
    facet = String.to_existing_atom(facet)
    open = if socket.assigns.open_facet == facet, do: nil, else: facet
    {:noreply, assign(socket, open_facet: open, wf_query: "")}
  end

  def handle_event("close_facets", _, socket) do
    {:noreply, assign(socket, open_facet: nil)}
  end

  def handle_event("filter_workflows", %{"value" => q}, socket) do
    {:noreply, assign(socket, wf_query: q)}
  end

  def handle_event("select_workflow", %{"name" => name}, socket) do
    notify(%{workflow: name})
    {:noreply, assign(socket, open_facet: nil, wf_query: "")}
  end

  def handle_event("toggle_status", %{"status" => status}, socket) do
    current = socket.assigns.statuses || []
    next = if status in current, do: List.delete(current, status), else: [status | current]
    notify(%{statuses: next})
    {:noreply, socket}
  end

  def handle_event("set_range", %{"range" => range}, socket) do
    notify(%{range: range, from: nil, to: nil})
    {:noreply, assign(socket, open_facet: nil)}
  end

  def handle_event("set_custom", %{"from" => from, "to" => to}, socket) do
    notify(%{range: nil, from: blank_to_nil(from), to: blank_to_nil(to)})
    {:noreply, socket}
  end

  def handle_event("set_id", %{"value" => value}, socket) do
    notify(%{exec_id: sanitize_id(value)})
    {:noreply, socket}
  end

  def handle_event("clear", %{"facet" => facet}, socket) do
    notify(clear_patch(facet))
    {:noreply, socket}
  end

  def handle_event("clear_all", _, socket) do
    notify(%{workflow: nil, statuses: [], range: nil, from: nil, to: nil, exec_id: nil})
    {:noreply, assign(socket, open_facet: nil, wf_query: "")}
  end

  defp clear_patch("workflow"), do: %{workflow: nil}
  defp clear_patch("status"), do: %{statuses: []}
  defp clear_patch("time"), do: %{range: nil, from: nil, to: nil}
  defp clear_patch("id"), do: %{exec_id: nil}

  defp notify(patch), do: send(self(), {:execution_filters, patch})

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :any_active?, any_active?(assigns))

    ~H"""
    <div class="flex flex-wrap items-center gap-2 rounded-lg border border-border bg-card/40 px-3 py-2">
      <.workflow_facet
        :if={!@locked_workflow?}
        myself={@myself}
        open?={@open_facet == :workflow}
        workflow={@workflow}
        workflows={filter_workflows(@workflows, @wf_query)}
        wf_query={@wf_query}
      />
      <.locked_workflow :if={@locked_workflow?} name={@workflow} />

      <.status_facet
        myself={@myself}
        open?={@open_facet == :status}
        statuses={@statuses || []}
        options={@status_options}
      />

      <.time_facet
        myself={@myself}
        open?={@open_facet == :time}
        range={@range}
        from={@from}
        to={@to}
      />

      <.id_facet
        myself={@myself}
        open?={@open_facet == :id}
        exec_id={@exec_id}
        base_path={@base_path}
      />

      <button
        :if={@any_active?}
        type="button"
        phx-click="clear_all"
        phx-target={@myself}
        class="ml-auto inline-flex items-center gap-1 rounded-md px-2 h-7 text-[11px] font-medium text-muted-foreground hover:text-foreground hover:bg-accent transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        <Core.icon name="x-mark" class="size-3" /> Clear all
      </button>
    </div>
    """
  end

  # ----- Workflow facet -------------------------------------------------------

  attr :myself, :any, required: true
  attr :open?, :boolean, required: true
  attr :workflow, :string, default: nil
  attr :workflows, :list, required: true
  attr :wf_query, :string, required: true

  defp workflow_facet(assigns) do
    ~H"""
    <div class="relative">
      <.facet_trigger
        myself={@myself}
        facet="workflow"
        icon="queue"
        label="Workflow"
        value={@workflow}
        active?={@workflow not in [nil, ""]}
      />
      <.popover :if={@open?} myself={@myself} class="w-72">
        <form phx-change="filter_workflows" phx-target={@myself} class="p-2 border-b border-border">
          <input
            type="text"
            name="value"
            value={@wf_query}
            placeholder="Find a workflow…"
            autocomplete="off"
            phx-mounted={JS.focus()}
            class="w-full h-8 px-2 rounded-md bg-background/60 border border-border text-[13px] text-foreground placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          />
        </form>
        <div class="max-h-64 overflow-auto thin-scroll py-1">
          <p :if={@workflows == []} class="px-3 py-6 text-center text-[12px] text-muted-foreground">
            No workflows match.
          </p>
          <button
            :for={w <- @workflows}
            type="button"
            phx-click="select_workflow"
            phx-target={@myself}
            phx-value-name={w.workflow_name}
            class={[
              "flex w-full items-center gap-2 px-3 h-9 text-left text-[13px] transition-colors",
              if(w.workflow_name == @workflow,
                do: "bg-accent text-accent-foreground",
                else: "text-foreground hover:bg-accent/40"
              )
            ]}
          >
            <span class="flex-1 truncate font-medium">{w.workflow_name}</span>
            <span class="text-numeric text-[11px] text-muted-foreground/70">{w.total_runs}</span>
            <Core.status_pill :if={w.last_status} status={w.last_status} />
          </button>
        </div>
      </.popover>
    </div>
    """
  end

  attr :name, :string, default: nil

  defp locked_workflow(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 h-7 rounded-md border border-border bg-accent px-2.5 text-[12px]">
      <Core.icon name="queue" class="size-3.5 text-muted-foreground" />
      <span class="font-medium text-foreground">{@name}</span>
    </span>
    """
  end

  # ----- Status facet ---------------------------------------------------------

  attr :myself, :any, required: true
  attr :open?, :boolean, required: true
  attr :statuses, :list, required: true
  attr :options, :list, required: true

  defp status_facet(assigns) do
    ~H"""
    <div class="relative">
      <.facet_trigger
        myself={@myself}
        facet="status"
        icon="information-circle"
        label="Status"
        value={status_summary(@statuses)}
        active?={@statuses != []}
      />
      <.popover :if={@open?} myself={@myself} class="w-52">
        <div class="py-1">
          <button
            :for={opt <- @options}
            type="button"
            phx-click="toggle_status"
            phx-target={@myself}
            phx-value-status={opt}
            class="flex w-full items-center gap-2.5 px-3 h-9 text-left text-[13px] text-foreground hover:bg-accent/40 transition-colors"
          >
            <span class={[
              "flex size-4 shrink-0 items-center justify-center rounded-sm border",
              if(opt in @statuses,
                do: "border-primary bg-primary text-primary-foreground",
                else: "border-border"
              )
            ]}>
              <Core.icon :if={opt in @statuses} name="check" class="size-3" />
            </span>
            <Core.status_pill status={opt} />
          </button>
        </div>
      </.popover>
    </div>
    """
  end

  # ----- Time facet -----------------------------------------------------------

  attr :myself, :any, required: true
  attr :open?, :boolean, required: true
  attr :range, :string, default: nil
  attr :from, :string, default: nil
  attr :to, :string, default: nil

  defp time_facet(assigns) do
    assigns = assign(assigns, presets: @presets)

    ~H"""
    <div class="relative">
      <.facet_trigger
        myself={@myself}
        facet="time"
        icon="clock"
        label="Time"
        value={time_summary(@range, @from, @to)}
        active?={@range not in [nil, ""] or @from not in [nil, ""] or @to not in [nil, ""]}
      />
      <.popover :if={@open?} myself={@myself} class="w-64">
        <div class="py-1">
          <button
            :for={{key, text} <- @presets}
            type="button"
            phx-click="set_range"
            phx-target={@myself}
            phx-value-range={key}
            class={[
              "flex w-full items-center justify-between px-3 h-8 text-left text-[13px] transition-colors",
              if(key == @range,
                do: "bg-accent text-accent-foreground",
                else: "text-foreground hover:bg-accent/40"
              )
            ]}
          >
            {text}
            <Core.icon :if={key == @range} name="check" class="size-3.5 text-muted-foreground" />
          </button>
        </div>
        <form
          phx-change="set_custom"
          phx-target={@myself}
          class="space-y-2 border-t border-border p-3"
        >
          <Core.label>custom range · UTC</Core.label>
          <label class="flex items-center gap-2 text-[11px] text-muted-foreground">
            <span class="w-8">from</span>
            <input
              type="datetime-local"
              name="from"
              value={@from}
              class="flex-1 h-7 px-1.5 rounded-md bg-background/60 border border-border text-[12px] text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
          </label>
          <label class="flex items-center gap-2 text-[11px] text-muted-foreground">
            <span class="w-8">to</span>
            <input
              type="datetime-local"
              name="to"
              value={@to}
              class="flex-1 h-7 px-1.5 rounded-md bg-background/60 border border-border text-[12px] text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
          </label>
        </form>
      </.popover>
    </div>
    """
  end

  # ----- ID facet -------------------------------------------------------------

  attr :myself, :any, required: true
  attr :open?, :boolean, required: true
  attr :exec_id, :string, default: nil
  attr :base_path, :string, required: true

  defp id_facet(assigns) do
    ~H"""
    <div class="relative">
      <.facet_trigger
        myself={@myself}
        facet="id"
        icon="search"
        label="ID"
        value={@exec_id}
        active?={@exec_id not in [nil, ""]}
      />
      <.popover :if={@open?} myself={@myself} class="w-72">
        <form phx-change="set_id" phx-target={@myself} class="p-2">
          <input
            type="text"
            name="value"
            value={@exec_id}
            placeholder="Execution id or prefix…"
            autocomplete="off"
            spellcheck="false"
            phx-debounce="250"
            phx-mounted={JS.focus()}
            class="w-full h-8 px-2 rounded-md bg-background/60 border border-border font-mono text-[12px] text-foreground placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          />
        </form>
        <.link
          :if={full_uuid?(@exec_id)}
          navigate={DPath.execution(@base_path, @exec_id)}
          class="flex items-center justify-between gap-2 border-t border-border px-3 h-9 text-[13px] text-primary hover:bg-accent/40 transition-colors"
        >
          Open this execution <Core.icon name="chevron-right" class="size-3.5" />
        </.link>
      </.popover>
    </div>
    """
  end

  # ----- Shared facet primitives ---------------------------------------------

  attr :myself, :any, required: true
  attr :facet, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :active?, :boolean, default: false

  defp facet_trigger(assigns) do
    ~H"""
    <div class="inline-flex items-center">
      <button
        type="button"
        phx-click="toggle_facet"
        phx-target={@myself}
        phx-value-facet={@facet}
        class={[
          "inline-flex items-center gap-1.5 h-7 rounded-md border px-2.5 text-[12px] transition-colors",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
          if(@active?,
            do: "border-border bg-accent text-foreground",
            else: "border-border bg-card/40 text-muted-foreground hover:bg-accent hover:text-accent-foreground"
          )
        ]}
      >
        <Core.icon name={@icon} class="size-3.5 shrink-0" />
        <span class="font-medium">{@label}</span>
        <span :if={@active? && @value} class="max-w-[160px] truncate text-foreground/90">
          {@value}
        </span>
        <Core.icon name="chevron-down" class="size-3 text-muted-foreground/70" />
      </button>
      <button
        :if={@active?}
        type="button"
        phx-click="clear"
        phx-target={@myself}
        phx-value-facet={@facet}
        aria-label={"Clear " <> @label <> " filter"}
        class="-ml-1 inline-flex size-7 items-center justify-center rounded-md text-muted-foreground hover:text-foreground transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        <Core.icon name="x-mark" class="size-3" />
      </button>
    </div>
    """
  end

  attr :myself, :any, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp popover(assigns) do
    ~H"""
    <div
      phx-click-away="close_facets"
      phx-target={@myself}
      phx-window-keydown="close_facets"
      phx-key="Escape"
      class={[
        "absolute left-0 top-[calc(100%+6px)] z-30 overflow-hidden",
        "rounded-lg border border-border bg-popover text-popover-foreground shadow-lg",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp filter_workflows(workflows, ""), do: workflows

  defp filter_workflows(workflows, query) do
    q = String.downcase(query)
    Enum.filter(workflows, &String.contains?(String.downcase(&1.workflow_name), q))
  end

  defp status_summary([]), do: nil
  defp status_summary([one]), do: one
  defp status_summary([first | rest]), do: "#{first} +#{length(rest)}"

  defp time_summary(range, _from, _to) when range not in [nil, ""] do
    Enum.find_value(@presets, range, fn {key, text} -> if key == range, do: text end)
  end

  defp time_summary(_range, from, to) when from not in [nil, ""] or to not in [nil, ""],
    do: "Custom"

  defp time_summary(_range, _from, _to), do: nil

  defp any_active?(assigns) do
    assigns.workflow not in [nil, ""] or (assigns.statuses || []) != [] or
      assigns.range not in [nil, ""] or assigns.from not in [nil, ""] or
      assigns.to not in [nil, ""] or assigns.exec_id not in [nil, ""]
  end

  defp full_uuid?(id) when is_binary(id), do: Regex.match?(@uuid_re, String.downcase(id))
  defp full_uuid?(_), do: false

  # Keep only id-shaped characters (hex + hyphen); drop LIKE wildcards so user
  # input can't widen the prefix match. Lowercased to match canonical UUIDs.
  defp sanitize_id(value) when is_binary(value) do
    value |> String.downcase() |> String.replace(~r/[^0-9a-f-]/, "") |> blank_to_nil()
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
end
