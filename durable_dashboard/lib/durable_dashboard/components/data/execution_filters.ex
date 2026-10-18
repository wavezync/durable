defmodule DurableDashboard.Components.Data.ExecutionFilters do
  @moduledoc """
  The Runs query bar: every filter in force is a tag inside one search field,
  and the Workflow, Status and Time menus beside it add tags — see
  `DESIGN.md` "Query bar".

  - **Typing** — `RunSearch` syntax (`step:charge`, `error:"503"`,
    `input.order_id:42`, an id). Enter turns the text into tags; `workflow:`,
    `status:` and `since:` become the same filters the menus set. Backspace in
    an empty field removes the last tag. While typing, the `QuerySuggest` hook
    offers filter keys and, for a key with known values (workflow, status,
    schedule, since), the values — from `data-suggest`, without a round trip.
  - **Workflow** — a searchable combobox of the *known* workflow names
    (`Durable.Query.list_workflows`). Locked on the per-workflow page, where
    its tag can't be removed.
  - **Status** — multi-select. Its tag only shows for a set the saved-view
    tabs don't already name (`status_tag?`).
  - **Time** — relative presets (15m … 30d) or a custom UTC range.

  The menus keep a fixed width whatever is selected, so filtering never
  moves them. The bar owns only transient UI state (which menu is open, the
  combobox text, the field's revision); the *values* live in the parent's
  URL-driven query — every change sends `{:execution_filters, patch}` to the
  parent LiveView, which merges it, resets to page 1, and patches the URL.

  ## Required assigns

  - `:status_options`, `:workflows` (combobox source), `:schedules` (names)
  - `:q`, `:workflow`, `:statuses`, `:range`, `:from`, `:to` — current values
  - `:locked_workflow?` — true on `/workflows/:name/runs`
  - `:status_tag?` — whether `:statuses` needs a tag of its own
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Format
  alias DurableDashboard.Components.Core
  alias DurableDashboard.RunSearch
  alias Phoenix.LiveView.JS

  @presets [
    {"15m", "Last 15 min"},
    {"1h", "Last hour"},
    {"24h", "Last 24 hours"},
    {"7d", "Last 7 days"},
    {"30d", "Last 30 days"}
  ]

  @impl true
  def mount(socket) do
    # `rev` re-keys the text field after a commit: a fresh, empty, focused
    # input (LiveView won't overwrite the value of a focused one).
    {:ok, assign(socket, open_facet: nil, wf_query: "", rev: 0)}
  end

  # What the query field suggests, in this order; values come from the menus'
  # sources. `hint` is shown beside a key, `help` once the key is typed.
  @keys [
    {"workflow", "workflow:", "runs of one workflow", nil},
    {"status", "status:", "a run state · combine with commas", nil},
    {"step", "step:", "where the run is, or where it stopped", "type a step name, then ↵"},
    {"error", "error:", "text in the error · quote a phrase",
     ~s(type text or "a phrase", then ↵)},
    {"input.", "input.", "an input value · input.order_id:42",
     "type input.<path>:<value>, then ↵"},
    {"schedule", "schedule:", "runs a schedule started", nil},
    {"since", "since:", "started in the last 15m … 30d", nil},
    {"id", "id:", "a run id, or its first characters", "type an id or its start, then ↵"}
  ]

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:status_tag?, fn -> false end)
      |> assign_new(:schedules, fn -> [] end)

    {:ok, assign(socket, suggest: socket.assigns |> suggestions() |> Jason.encode!())}
  end

  defp suggestions(assigns) do
    keys = Enum.reject(@keys, &(assigns.locked_workflow? and elem(&1, 0) == "workflow"))

    %{
      keys: for({key, insert, hint, _} <- keys, do: %{key: key, insert: insert, hint: hint}),
      help: for({key, _, _, help} <- keys, help, into: %{}, do: {key, help}),
      values: %{
        "workflow" =>
          if(assigns.locked_workflow?,
            do: [],
            else:
              Enum.map(
                assigns.workflows,
                &%{value: &1.workflow_name, meta: Format.count(&1.total_runs, "run")}
              )
          ),
        "status" => Enum.map(assigns.status_options, &%{value: &1, dot: &1}),
        "schedule" => Enum.map(assigns.schedules, &%{value: &1}),
        "since" => Enum.map(@presets, fn {key, text} -> %{value: key, meta: text} end)
      }
    }
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

  def handle_event("commit", %{"draft" => draft}, socket) do
    case String.trim(draft) do
      "" ->
        {:noreply, socket}

      text ->
        notify(commit_patch(socket.assigns, text))
        {:noreply, bump(socket)}
    end
  end

  def handle_event("draft_key", %{"key" => "Backspace", "value" => ""}, socket) do
    case socket.assigns |> tags() |> Enum.filter(& &1.removable?) |> List.last() do
      nil -> {:noreply, socket}
      tag -> remove(socket, tag.id)
    end
  end

  def handle_event("draft_key", _params, socket), do: {:noreply, socket}

  def handle_event("remove_tag", %{"tag" => id}, socket), do: remove(socket, id)

  def handle_event("clear_all", _, socket) do
    notify(%{workflow: nil, statuses: [], range: nil, from: nil, to: nil, q: nil})
    {:noreply, socket |> assign(open_facet: nil, wf_query: "") |> bump()}
  end

  defp remove(socket, id) do
    notify(remove_patch(socket.assigns, id))
    {:noreply, bump(socket)}
  end

  defp bump(socket), do: update(socket, :rev, &(&1 + 1))

  defp remove_patch(_assigns, "workflow"), do: %{workflow: nil}
  defp remove_patch(_assigns, "status"), do: %{statuses: []}
  defp remove_patch(_assigns, "time"), do: %{range: nil, from: nil, to: nil}

  defp remove_patch(assigns, "q:" <> index) do
    rest = assigns.q |> RunSearch.tokens() |> List.delete_at(String.to_integer(index))
    %{q: rest |> Enum.map_join(" ", & &1.raw) |> blank_to_nil()}
  end

  # Typed facets set the same filters the menus do; the rest joins the search.
  # A facet value the menus don't offer (status:nope, since:3w) is dropped.
  defp commit_patch(assigns, text) do
    {facets, rest} = RunSearch.split_facets(text)
    q = [assigns.q, rest] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
    statuses = Enum.filter(facets[:statuses] || [], &(&1 in assigns.status_options))
    range = facets[:range]

    %{q: blank_to_nil(q)}
    |> merge_if(is_binary(facets[:workflow]) and not assigns.locked_workflow?, %{
      workflow: facets[:workflow]
    })
    |> merge_if(statuses != [], %{statuses: statuses})
    |> merge_if(List.keymember?(@presets, range, 0), %{range: range, from: nil, to: nil})
  end

  defp merge_if(patch, true, more), do: Map.merge(patch, more)
  defp merge_if(patch, false, _more), do: patch

  defp notify(patch), do: send(self(), {:execution_filters, patch})

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    assigns = assign(assigns, tags: tags(assigns))

    ~H"""
    <div class="flex flex-wrap items-start gap-1.5">
      <form
        id={"#{@id}-query"}
        phx-submit="commit"
        phx-target={@myself}
        phx-hook="QuerySuggest"
        data-suggest={@suggest}
        class="relative min-w-0 flex-[1_1_420px]"
        role="search"
      >
        <div class={[
          "flex min-h-8 flex-wrap items-center gap-1 rounded-md border border-input bg-card py-[3px] pl-2.5 pr-1",
          "focus-within:border-ring/60 focus-within:ring-2 focus-within:ring-ring/25"
        ]}>
          <Core.icon name="search" class="mr-0.5 size-3.5 shrink-0 text-muted-foreground" />
          <.tag :for={tag <- @tags} tag={tag} myself={@myself} />
          <label class="sr-only" for={"run-query-#{@rev}"}>Filter runs</label>
          <input
            id={"run-query-#{@rev}"}
            type="text"
            name="draft"
            autocomplete="off"
            spellcheck="false"
            phx-keydown="draft_key"
            phx-key="Backspace"
            phx-target={@myself}
            phx-mounted={@rev > 0 && JS.focus()}
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="false"
            aria-controls={"#{@id}-suggestions"}
            placeholder={
              if @tags == [],
                do: ~s(Filter: an id, step:ship_order, error:"503", input.order_id:ORD-1042, status:failed),
                else: "Add a filter…"
            }
            class="peer h-6 min-w-[16ch] flex-1 bg-transparent px-0.5 font-mono text-xs text-foreground outline-none placeholder:text-muted-foreground"
          />
          <kbd class="shrink-0 rounded-[4px] border border-border px-1 font-mono text-[10px] text-muted-foreground peer-placeholder-shown:hidden">
            ↵ add
          </kbd>
          <button
            :if={Enum.any?(@tags, & &1.removable?)}
            type="button"
            phx-click="clear_all"
            phx-target={@myself}
            aria-label="Clear all filters"
            data-tip="Clear all filters"
            class="inline-flex size-6 shrink-0 items-center justify-center rounded-[5px] text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            <Core.icon name="x-mark" class="size-3.5" />
          </button>
        </div>
        <%!-- Filled by the QuerySuggest hook; LiveView leaves it alone. --%>
        <div id={"#{@id}-suggestions"} phx-update="ignore" data-suggest-panel></div>
      </form>

      <div class="ml-auto flex shrink-0 items-center gap-1.5">
        <.workflow_facet
          :if={!@locked_workflow?}
          myself={@myself}
          open?={@open_facet == :workflow}
          workflow={@workflow}
          workflows={filter_workflows(@workflows, @wf_query)}
          wf_query={@wf_query}
        />

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
      </div>
    </div>
    """
  end

  attr :tag, :map, required: true
  attr :myself, :any, required: true

  defp tag(assigns) do
    ~H"""
    <span
      class="inline-flex h-6 min-w-0 max-w-full items-center overflow-hidden rounded-[5px] border border-border bg-secondary text-xs"
      data-tip-title={"#{@tag.key} #{@tag.value}"}
      data-tip={tag_help(@tag)}
    >
      <span class="flex shrink-0 items-center self-stretch border-r border-border bg-background/40 px-1.5 text-muted-foreground">{@tag.key}</span>
      <span class="truncate px-1.5 font-mono text-foreground">{@tag.value}</span>
      <button
        :if={@tag.removable?}
        type="button"
        phx-click="remove_tag"
        phx-value-tag={@tag.id}
        phx-target={@myself}
        aria-label={"Remove #{@tag.key} #{@tag.value}"}
        data-tip="Remove this filter"
        class="-ml-1 inline-flex h-full w-5 shrink-0 items-center justify-center text-muted-foreground hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
      >
        <Core.icon name="x-mark" class="size-3" />
      </button>
    </span>
    """
  end

  # Facet tags first, in menu order, then one per search term.
  defp tags(assigns) do
    facets =
      [
        assigns.workflow not in [nil, ""] &&
          %{
            id: "workflow",
            key: "workflow",
            value: assigns.workflow,
            removable?: not assigns.locked_workflow?
          },
        assigns.status_tag? && (assigns.statuses || []) != [] &&
          %{
            id: "status",
            key: "status",
            value: Enum.join(assigns.statuses, ", "),
            removable?: true
          },
        time_tag(assigns)
      ]
      |> Enum.filter(& &1)

    terms =
      assigns.q
      |> RunSearch.tokens()
      |> Enum.with_index()
      |> Enum.map(fn {token, i} ->
        {key, value} = RunSearch.label(token)
        %{id: "q:#{i}", key: key, value: value, removable?: true}
      end)

    facets ++ terms
  end

  # What a tag keeps — its tooltip.
  defp tag_help(%{removable?: false}), do: "This page lists one workflow's runs"
  defp tag_help(%{key: "workflow"}), do: "Only runs of this workflow"
  defp tag_help(%{key: "status"}), do: "Only runs in these states"
  defp tag_help(%{key: "since"}), do: "Only runs started in this recent window"

  defp tag_help(%{key: key}) when key in ~w(after before between),
    do: "Only runs started in this window"

  defp tag_help(%{key: "step"}), do: "Runs at this step, or that stopped there"
  defp tag_help(%{key: "error"}), do: "Text anywhere in the run's error"
  defp tag_help(%{key: "id"}), do: "Runs whose id starts with this"
  defp tag_help(%{key: "schedule"}), do: "Runs this schedule started"
  defp tag_help(%{key: "input." <> path}), do: "Runs whose input #{path} is exactly this"
  defp tag_help(_tag), do: nil

  defp time_tag(%{range: range}) when range not in [nil, ""],
    do: %{id: "time", key: "since", value: range, removable?: true}

  defp time_tag(%{from: from, to: to}) do
    case {blank_to_nil(from), blank_to_nil(to)} do
      {nil, nil} ->
        nil

      {from, nil} ->
        %{id: "time", key: "after", value: utc(from), removable?: true}

      {nil, to} ->
        %{id: "time", key: "before", value: utc(to), removable?: true}

      {from, to} ->
        %{id: "time", key: "between", value: "#{utc(from)} – #{utc(to)}", removable?: true}
    end
  end

  defp utc(local), do: String.replace(local, "T", " ") <> " UTC"

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
        tip="Runs of one workflow · or type workflow:"
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
            <span class="text-numeric text-[11px] text-muted-foreground">{w.total_runs}</span>
            <Core.status_pill :if={w.last_status} status={w.last_status} />
          </button>
        </div>
      </.popover>
    </div>
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
        tip="Runs in one or more states · or type status:"
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
        tip="Runs started in a recent window or a UTC range · or type since:"
        active?={@range not in [nil, ""] or @from not in [nil, ""] or @to not in [nil, ""]}
      />
      <.popover :if={@open?} myself={@myself} class="w-80">
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
              class="min-w-0 flex-1 h-7 px-1.5 rounded-md bg-background/60 border border-border text-[12px] text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
          </label>
          <label class="flex items-center gap-2 text-[11px] text-muted-foreground">
            <span class="w-8">to</span>
            <input
              type="datetime-local"
              name="to"
              value={@to}
              class="min-w-0 flex-1 h-7 px-1.5 rounded-md bg-background/60 border border-border text-[12px] text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            />
          </label>
        </form>
      </.popover>
    </div>
    """
  end

  # ----- Shared facet primitives ---------------------------------------------

  attr :myself, :any, required: true
  attr :facet, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tip, :string, required: true
  attr :active?, :boolean, default: false

  # The value shows as a tag in the bar, never here: the trigger keeps its
  # width whatever is selected.
  defp facet_trigger(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_facet"
      phx-target={@myself}
      phx-value-facet={@facet}
      aria-haspopup="true"
      data-tip={@tip}
      class={[
        "inline-flex h-8 items-center gap-1.5 rounded-md border border-input px-2.5 text-[12px] transition-colors",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        if(@active?,
          do: "bg-accent text-foreground",
          else: "bg-card text-muted-foreground hover:bg-accent hover:text-accent-foreground"
        )
      ]}
    >
      <Core.icon name={@icon} class="size-3.5 shrink-0" />
      <span class="font-medium">{@label}</span>
      <Core.icon name="chevron-down" class="size-3 text-muted-foreground" />
    </button>
    """
  end

  attr :myself, :any, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  # Right-aligned: the menus sit at the end of the bar.
  defp popover(assigns) do
    ~H"""
    <div
      phx-click-away="close_facets"
      phx-target={@myself}
      phx-window-keydown="close_facets"
      phx-key="Escape"
      class={[
        "absolute right-0 top-[calc(100%+6px)] z-30 overflow-hidden",
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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
end
