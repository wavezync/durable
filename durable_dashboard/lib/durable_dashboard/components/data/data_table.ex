defmodule DurableDashboard.Components.Data.DataTable do
  @moduledoc """
  Reusable data-table LiveComponent. Owns its own filter / sort / page state,
  drives data via a parent-supplied `:fetcher` function, and emits query-change
  notifications to the parent LV so the parent can update the URL via
  `live_patch`. Real-time updates from the parent are triggered with
  `Phoenix.LiveView.send_update(__MODULE__, id: "...", refresh: true)`.

  ## Why a LiveComponent

  Three list views (Workflows, Schedules, Inputs) need the same filter/sort/
  pagination machinery. Extracting it as a function component would force
  every parent to hold the state itself, defeating the point. As a stateful
  component it owns the state once and the parents stay declarative.

  ## Mount-time assigns from the parent

  | assign | required | description |
  |---|---|---|
  | `:id` | yes | Unique component id (also used for stream key) |
  | `:fetcher` | yes | `(query :: map -> {rows :: list, total :: integer})` |
  | `:columns` | yes | List of column specs (see below) |
  | `:filters` | no | List of filter definitions (see below); default `[]` |
  | `:query` | yes | Current query — usually parsed from URL by the parent |
  | `:row_id` | no | `(row -> id_string)` for stream identity (default: `& &1.id`) |
  | `:row_navigate` | no | `(row -> url_string)` — clicking a row live-navigates here |
  | `:per_page` | no | default 20 |
  | `:empty_title` | no | empty-state title (default `"No results"`) |
  | `:empty_description` | no | empty-state subtitle (optional) |
  | `:empty_icon` | no | empty-state icon (optional) |
  | `:search_placeholder` | no | search input placeholder (default `"Search…"`) |

  ### Column spec

      %{
        key: :status,                # atom — accessible via Map.get(row, key) | row[to_string(key)]
        label: "Status",
        sortable?: false,
        class: nil,                  # optional td class
        render: &my_render/1         # (row -> rendered HEEx) — required
      }

  ### Filter spec

      %{
        key: :status,                # atom or string — keyed into query map
        type: :select | :search,
        label: "Status",
        options: ["", "running", "failed"],     # for :select, [""] is "all"
        placeholder: nil
      }

  ## Query map shape

      %{
        page: integer,                  # 1-based
        search: string | nil,           # text search
        sort_by: atom | nil,
        sort_dir: :asc | :desc,
        # plus any filter keys, e.g. status: "running"
      }

  ## Communication

  - **LC → parent:** when query changes, the LC sends a regular Erlang message
    `{:data_table, component_id, :query_changed, new_query}` to the parent LV
    pid (captured at mount). The parent decides whether to `live_patch` or
    update assigns directly.
  - **Parent → LC:** new `:query` via `send_update(__MODULE__, id: id, query: q)`
    re-fetches automatically. `:refresh -> true` re-fetches the current query.
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Data.Pagination
  alias Phoenix.LiveView.JS

  @default_query %{
    page: 1,
    search: nil,
    sort_by: nil,
    sort_dir: :desc
  }

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       parent_pid: nil,
       columns: [],
       filters: [],
       query: @default_query,
       per_page: 20,
       row_id: & &1.id,
       row_navigate: nil,
       empty_title: "No results",
       empty_description: nil,
       empty_icon: nil,
       search_placeholder: "Search…",
       total: 0,
       loaded?: false,
       fetch_error: nil
     )
     |> stream_configure(:rows, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> ensure_parent_pid(assigns)
      |> apply_assigns(assigns)
      |> maybe_refresh(assigns)

    {:ok, socket}
  end

  defp ensure_parent_pid(socket, assigns) do
    case socket.assigns.parent_pid do
      nil -> assign(socket, parent_pid: assigns[:parent_pid] || self_parent())
      _ -> socket
    end
  end

  # In a LiveComponent, self() inside update/2 returns the parent LV pid.
  defp self_parent, do: self()

  defp apply_assigns(socket, assigns) do
    socket
    |> assign_new(:fetcher, fn -> assigns[:fetcher] end)
    |> assign(
      id: assigns.id,
      columns: assigns[:columns] || socket.assigns.columns,
      filters: assigns[:filters] || socket.assigns.filters,
      per_page: assigns[:per_page] || socket.assigns.per_page,
      row_id: assigns[:row_id] || socket.assigns.row_id,
      row_navigate: assigns[:row_navigate],
      empty_title: assigns[:empty_title] || socket.assigns.empty_title,
      empty_description: assigns[:empty_description],
      empty_icon: assigns[:empty_icon],
      search_placeholder: assigns[:search_placeholder] || socket.assigns.search_placeholder
    )
    |> apply_query(assigns)
  end

  defp apply_query(socket, %{query: q}) when is_map(q) do
    merged = Map.merge(@default_query, sanitize_query(q))
    assign(socket, query: merged)
  end

  defp apply_query(socket, _), do: socket

  # Coerce sort_dir to atom; everything else passes through.
  defp sanitize_query(q) do
    Enum.reduce(q, %{}, fn
      {:sort_dir, v}, acc -> Map.put(acc, :sort_dir, normalize_dir(v))
      {"sort_dir", v}, acc -> Map.put(acc, :sort_dir, normalize_dir(v))
      {:page, v}, acc -> Map.put(acc, :page, normalize_int(v, 1))
      {"page", v}, acc -> Map.put(acc, :page, normalize_int(v, 1))
      {k, v}, acc when is_atom(k) -> Map.put(acc, k, v)
      {k, v}, acc when is_binary(k) -> Map.put(acc, String.to_atom(k), v)
    end)
  end

  defp normalize_dir(v) when v in [:asc, :desc], do: v
  defp normalize_dir("asc"), do: :asc
  defp normalize_dir("desc"), do: :desc
  defp normalize_dir(_), do: :desc

  defp normalize_int(v, _default) when is_integer(v), do: v

  defp normalize_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp normalize_int(_, default), do: default

  defp maybe_refresh(socket, assigns) do
    cond do
      assigns[:refresh] == true -> fetch_and_stream(socket)
      not socket.assigns.loaded? and socket.assigns.fetcher != nil -> fetch_and_stream(socket)
      Map.has_key?(assigns, :query) -> fetch_and_stream(socket)
      true -> socket
    end
  end

  defp fetch_and_stream(socket) do
    fetcher = socket.assigns.fetcher

    if is_function(fetcher, 1) do
      query = Map.put(socket.assigns.query, :per_page, socket.assigns.per_page)

      case safe_fetch(fetcher, query) do
        {:ok, {rows, total}} ->
          socket
          |> stream(:rows, rows, reset: true)
          |> assign(total: total, loaded?: true, fetch_error: nil)

        {:error, reason} ->
          socket
          |> stream(:rows, [], reset: true)
          |> assign(total: 0, loaded?: true, fetch_error: reason)
      end
    else
      socket
    end
  end

  defp safe_fetch(fetcher, query) do
    case fetcher.(query) do
      {rows, total} when is_list(rows) and is_integer(total) -> {:ok, {rows, total}}
      other -> {:error, "fetcher returned #{inspect(other)}; expected {rows, total}"}
    end
  rescue
    e ->
      require Logger
      Logger.error("DataTable fetcher raised: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  # ============================================================================
  # Events
  # ============================================================================

  @impl true
  def handle_event("data_table:filter", %{"key" => key, "value" => value}, socket) do
    key_atom = String.to_existing_atom(key)
    value = if value == "", do: nil, else: value

    new_query =
      socket.assigns.query
      |> Map.put(key_atom, value)
      |> Map.put(:page, 1)

    {:noreply, push_query(socket, new_query)}
  rescue
    ArgumentError ->
      {:noreply, socket}
  end

  def handle_event("data_table:search", %{"value" => value}, socket) do
    value = if value == "", do: nil, else: value
    new_query = socket.assigns.query |> Map.put(:search, value) |> Map.put(:page, 1)
    {:noreply, push_query(socket, new_query)}
  end

  def handle_event("data_table:page", %{"page" => page}, socket) do
    page = normalize_int(page, 1)
    new_query = Map.put(socket.assigns.query, :page, max(page, 1))
    {:noreply, push_query(socket, new_query)}
  end

  def handle_event("data_table:sort", %{"key" => key}, socket) do
    key_atom = String.to_existing_atom(key)

    {sort_by, sort_dir} =
      case socket.assigns.query do
        %{sort_by: ^key_atom, sort_dir: :asc} -> {key_atom, :desc}
        %{sort_by: ^key_atom, sort_dir: :desc} -> {nil, :desc}
        _ -> {key_atom, :asc}
      end

    new_query =
      socket.assigns.query
      |> Map.put(:sort_by, sort_by)
      |> Map.put(:sort_dir, sort_dir)
      |> Map.put(:page, 1)

    {:noreply, push_query(socket, new_query)}
  rescue
    ArgumentError ->
      {:noreply, socket}
  end

  defp push_query(socket, new_query) do
    socket = assign(socket, query: new_query)
    socket = fetch_and_stream(socket)

    if pid = socket.assigns.parent_pid do
      send(pid, {:data_table, socket.assigns.id, :query_changed, new_query})
    end

    socket
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="rounded-md border border-border bg-card text-card-foreground">
      <.toolbar
        :if={@filters != [] or has_search?(@filters)}
        target={@myself}
        filters={@filters}
        query={@query}
        search_placeholder={@search_placeholder}
      />

      <%= cond do %>
        <% @fetch_error != nil -> %>
          <Core.error_state
            title="Failed to load"
            description="The data fetcher returned an error. The view will retry on the next refresh."
            reason={@fetch_error}
          />
        <% not @loaded? -> %>
          <.loading_skeleton columns={length(@columns)} />
        <% @total == 0 -> %>
          <Core.empty_state
            title={@empty_title}
            description={@empty_description}
            icon={@empty_icon}
          />
        <% true -> %>
        <div class="overflow-x-auto thin-scroll">
          <table class="w-full text-[13px]">
            <thead>
              <tr class="border-b border-border text-[11px] uppercase tracking-wider text-muted-foreground">
                <th
                  :for={col <- @columns}
                  class={[
                    "text-left font-medium px-4 h-10 whitespace-nowrap",
                    col[:class],
                    col[:sortable?] && "cursor-pointer select-none hover:text-foreground"
                  ]}
                  phx-click={col[:sortable?] && JS.push("data_table:sort", target: @myself)}
                  phx-value-key={col[:sortable?] && to_string(col.key)}
                >
                  <span class="inline-flex items-center gap-1">
                    {col.label}
                    <Core.icon
                      :if={col[:sortable?] && @query.sort_by == col.key}
                      name="chevron-down"
                      class={sort_indicator_class(@query.sort_dir)}
                    />
                  </span>
                </th>
              </tr>
            </thead>
            <tbody id={@id <> "-rows"} phx-update="stream">
              <tr
                :for={{dom_id, row} <- @streams.rows}
                id={dom_id}
                class={[
                  "border-b border-border/60 last:border-b-0 transition-colors",
                  @row_navigate && "hover:bg-accent/40 cursor-pointer"
                ]}
                phx-click={row_click(@row_navigate, row)}
              >
                <td :for={col <- @columns} class={["px-4 h-10", col[:class]]}>
                  {render_cell(col, row)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <Pagination.pagination
          page={@query.page}
          per_page={@per_page}
          total={@total}
          target={@myself}
        />
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Loading skeleton
  # ============================================================================

  attr :columns, :integer, required: true

  defp loading_skeleton(assigns) do
    ~H"""
    <div class="px-4 py-3 space-y-2">
      <%= for _ <- 1..6 do %>
        <Core.skeleton class="h-8 w-full" />
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Toolbar
  # ============================================================================

  attr :target, :any, required: true
  attr :filters, :list, required: true
  attr :query, :map, required: true
  attr :search_placeholder, :string, required: true

  defp toolbar(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-4 h-12 border-b border-border">
      <.search_input
        :if={has_search?(@filters)}
        target={@target}
        value={@query[:search]}
        placeholder={@search_placeholder}
      />

      <%= for filter <- @filters, filter.type == :select do %>
        <.select_filter target={@target} filter={filter} value={@query[filter.key]} />
      <% end %>
    </div>
    """
  end

  defp has_search?(filters) when is_list(filters) do
    Enum.any?(filters, &(&1.type == :search))
  end

  attr :target, :any, required: true
  attr :value, :any, required: true
  attr :placeholder, :string, required: true

  defp search_input(assigns) do
    ~H"""
    <form
      phx-change="data_table:search"
      phx-target={@target}
      class="flex items-center gap-2 flex-1 max-w-xs"
    >
      <div class="relative flex-1">
        <Core.icon
          name="search"
          class="absolute left-2.5 top-1/2 -translate-y-1/2 size-3.5 text-muted-foreground"
        />
        <input
          type="search"
          name="value"
          value={@value || ""}
          placeholder={@placeholder}
          phx-debounce="200"
          autocomplete="off"
          class={[
            "w-full h-8 pl-8 pr-2 rounded-md text-[13px]",
            "bg-input/40 border border-border",
            "text-foreground placeholder:text-muted-foreground",
            "focus:outline-none focus:ring-2 focus:ring-ring focus:bg-input/60"
          ]}
        />
      </div>
    </form>
    """
  end

  attr :target, :any, required: true
  attr :filter, :map, required: true
  attr :value, :any, required: true

  defp select_filter(assigns) do
    ~H"""
    <form phx-change="data_table:filter" phx-target={@target} class="flex items-center gap-1.5">
      <input type="hidden" name="key" value={@filter.key} />
      <select
        name="value"
        class={[
          "h-8 px-2 pr-7 rounded-md text-[13px]",
          "bg-input/40 border border-border",
          "text-foreground",
          "focus:outline-none focus:ring-2 focus:ring-ring focus:bg-input/60"
        ]}
      >
        <option :for={opt <- @filter.options} value={opt} selected={(@value || "") == opt}>
          {select_option_label(opt, @filter)}
        </option>
      </select>
    </form>
    """
  end

  defp select_option_label("", filter), do: "All " <> String.downcase(filter.label) <> ""
  defp select_option_label(value, _filter), do: humanize(value)

  defp humanize(s) when is_binary(s), do: s |> String.replace("_", " ") |> String.capitalize()
  defp humanize(s), do: to_string(s)

  # ============================================================================
  # Cell rendering
  # ============================================================================

  defp render_cell(%{render: render_fn}, row) when is_function(render_fn, 1) do
    render_fn.(row)
  end

  defp render_cell(%{key: key}, row) do
    Map.get(row, key) || Map.get(row, to_string(key)) || ""
  end

  defp sort_indicator_class(:asc), do: "size-3 rotate-180"
  defp sort_indicator_class(_), do: "size-3"

  defp row_click(nil, _row), do: nil

  defp row_click(navigate_fn, row) do
    JS.navigate(navigate_fn.(row))
  end
end
